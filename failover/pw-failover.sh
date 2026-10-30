#!/bin/sh
# pw-failover.sh — tunnel-node and WAN failover watchdog for an OpenWrt router running passwall2
# with xray. Lives at /root/scripts/pw-failover.sh and runs as the procd service pw-failover. Its
# settings are the uci section pw-failover.main (LuCI: Network ▸ Failover ▸ Settings) when that
# exists, else pw-failover.conf beside the script (or $PWF_CONF); `conf-to-uci` moves one to the other.
#
# Every PROBE_INTERVAL it asks the running xray (its node SOCKS port) for Cloudflare's trace page.
# After FAIL_THRESHOLD failures in a row it opens an incident and walks WAN_ORDER from the primary:
#
#   1. Is this WAN up? The order is the primary, then backups already up, then backups that are
#      down, which are raised with ifup as a last resort. Up = any WAN_TARGETS answers a ping bound
#      to its device; use a site on passwall2's direct list.
#   2. Route all egress through it: the primary is the plain main table; a backup gets a metric-0
#      default route with proto 201, which beats wan's metric 1, is ignored by netifd and is gone
#      after a reboot. No marks, no ip rules: nothing to collide with passwall2's tproxy marks,
#      which is what made mwan3 unusable here.
#   3. Pick a node: PRIMARY_NODE, then TIER1 (group + ports), then TIER2, in uci order, then the
#      TIER3_NODES named one by one, first whose
#      real URL test (passwall2's own test.sh, the LuCI "URL Test" button) passes. Make it the
#      egress node (the shunt's default_node when the global node is a shunt, else the global node
#      itself), restart passwall2, verify through the SOCKS port.
#   4. If no node works over a WAN that pings, try the next WAN with the same chain.
#
# A Telegram report goes out after recovery (queued until the tunnel works). While on a fallback
# node or backup WAN it keeps checking the primary and switches back after a hold.
#
# A manual override (`manual`, LuCI's Manual override button) pins the egress WAN, the node, or
# both. Traffic moves there at once, switch-back leaves the pinned part alone, and an incident looks
# for a fix only inside the pin. If nothing works inside it, the pin is dropped and failover runs as
# usual, unless it was set to hold.
#
# Usage: pw-failover.sh run | status | json | node-id | retest | reload | test-nodes [--tsv] |
#        test-nodes-bg | revert | revert-bg | pause [minutes] | resume | test-telegram |
#        manual <wan|-> <node|-> [minutes] [hold] | manual-bg … | manual-clear | manual-clear-bg |
#        conf [--json] | defaults | conf-to-uci
set -u

CONF=${PWF_CONF:-/root/scripts/pw-failover.conf}
UCI_CONF=pw-failover               # /etc/config/pw-failover, section main; wins over $CONF
PERSIST=/etc/pw-failover           # survives reboots: fallback-node state, reports, IP cache
REPORTS=$PERSIST/reports
STATE=$PERSIST/state
MANUAL=$PERSIST/manual             # the manual override; persistent, so a pin outlives a reboot
PAUSE=$PERSIST/pause               # when the pause ends (epoch), 0 = until resumed; outlives a reboot
TG_ENV=$PERSIST/telegram.env
RUN=/var/run/pw-failover           # tmpfs: WAN state, timeline, locks; a reboot resets it
LOG=$RUN/log
TEST_SH=/usr/share/passwall2/test.sh
ROUTE_PROTO=201
# The running xray only; url_test spawns its own xray with a url_test_*.json config.
XRAY_PAT='bin/xray run -c [/]tmp/etc/passwall2/acl/'

# Defaults; the settings override them, re-read every loop. See pw-failover.conf for what each means.
conf_defaults() {
  MODE=observe
  PRIMARY_NODE=
  TIER1_GROUP=; TIER1_PORT=; TIER2_GROUP=; TIER2_PORT=; TIER3_NODES=
  DENY_NODES=; DENY_ADDRS=
  WAN_ORDER=wan; WAN_TARGETS="8.8.8.8 1.1.1.1"; WAN_UP_WAIT=20
  PROBE_BAD_LOC=; EXPECT_EXIT_IPS=; EXTRA_LOCKS=; REPORT_NAME=; DIRECT_CHECK_URL=
  PROBE_INTERVAL=20; FAIL_INTERVAL=5; FAIL_THRESHOLD=3; GRACE=300; XRAY_MIN_AGE=90
  NODE_SB_INTERVAL=300; NODE_SB_PASSES=6; WAN_SB_CHECK=60; WAN_STAT_INTERVAL=0
  WAN_SB_HOLD_DOWN=300; WAN_SB_HOLD_NODES=1800; SB_MAX_WAIT=21600
  MAX_RESTARTS=6; MAX_INCIDENTS_HOUR=3; INCIDENT_COOLDOWN=1800; BACKOFF="300 600 1200 1800"
  RESTART_ON_WAN_CHANGE=1
}
conf_defaults

# Every setting, in pw-failover.conf as VAR= and in uci as option var (lower case). The lists are
# uci lists, one value per entry; the numbers are whole seconds or counts.
CONF_KEYS="MODE PRIMARY_NODE TIER1_GROUP TIER1_PORT TIER2_GROUP TIER2_PORT TIER3_NODES DENY_NODES DENY_ADDRS
  WAN_ORDER WAN_TARGETS WAN_UP_WAIT DIRECT_CHECK_URL EXPECT_EXIT_IPS PROBE_BAD_LOC EXTRA_LOCKS
  REPORT_NAME PROBE_INTERVAL FAIL_INTERVAL FAIL_THRESHOLD GRACE XRAY_MIN_AGE NODE_SB_INTERVAL
  NODE_SB_PASSES WAN_SB_CHECK WAN_STAT_INTERVAL WAN_SB_HOLD_DOWN WAN_SB_HOLD_NODES SB_MAX_WAIT
  MAX_RESTARTS MAX_INCIDENTS_HOUR INCIDENT_COOLDOWN BACKOFF RESTART_ON_WAN_CHANGE"
CONF_LISTS="TIER3_NODES DENY_NODES DENY_ADDRS WAN_ORDER WAN_TARGETS EXPECT_EXIT_IPS EXTRA_LOCKS BACKOFF"
CONF_NUMS="WAN_UP_WAIT PROBE_INTERVAL FAIL_INTERVAL FAIL_THRESHOLD GRACE XRAY_MIN_AGE NODE_SB_INTERVAL
  NODE_SB_PASSES WAN_SB_CHECK WAN_STAT_INTERVAL WAN_SB_HOLD_DOWN WAN_SB_HOLD_NODES SB_MAX_WAIT
  MAX_RESTARTS MAX_INCIDENTS_HOUR INCIDENT_COOLDOWN"
CONF_SRC=defaults; CONF_BAD=

# Turns `uci show pw-failover.main` into KEY='value' lines that are safe to eval: it unquotes uci's
# '...' words (lists join with a space), keeps only known keys, drops a value of the wrong shape
# (CONF_BAD names those, and the default stays), and quotes every value again.
UCI_AWK='
function valid(k, v) {
  if (k in num) return v ~ /^[0-9]+$/
  if (k ~ /_PORT$/) return v ~ /^([0-9]+( *, *[0-9]+)*)?$/
  if (k == "BACKOFF") return v ~ /^[0-9]+( [0-9]+)*$/
  if (k == "MODE") return v == "act" || v == "observe"
  if (k == "RESTART_ON_WAN_CHANGE") return v == "0" || v == "1"
  return 1
}
BEGIN {
  n = split(keys, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") known[tolower(a[i])] = a[i]
  n = split(nums, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") num[a[i]] = 1
}
{
  p = index($0, "="); name = substr($0, 1, p - 1)
  if (!sub(/^[^.]*\.[^.]*\./, "", name) || !(name in known)) next
  raw = substr($0, p + 1); val = ""; tok = ""; have = 0; q = 0; nt = 0
  for (i = 1; i <= length(raw); i++) {
    c = substr(raw, i, 1)
    if (q) { if (c == "\047") q = 0; else tok = tok c }
    else if (c == "\047") { q = 1; have = 1 }
    else if (c == "\\") { i++; tok = tok substr(raw, i, 1); have = 1 }
    else if (c == " ") { if (have) val = val (nt++ ? " " : "") tok; tok = ""; have = 0 }
    else { tok = tok c; have = 1 }
  }
  if (have) val = val (nt++ ? " " : "") tok
  k = known[name]
  if (!valid(k, val)) { bad = bad " " k; next }
  gsub(/\047/, "\047\\\047\047", val)
  print k "=\047" val "\047"
}
END { print "CONF_BAD=\047" substr(bad, 2) "\047" }'

load_conf() {
  conf_defaults   # an option removed since the last loop falls back to its default
  if [ -n "$(uci -q get "$UCI_CONF.main")" ]; then
    eval "$(uci -q show "$UCI_CONF.main" | awk -v keys="$CONF_KEYS" -v nums="$CONF_NUMS" "$UCI_AWK")"
    CONF_SRC="uci $UCI_CONF.main"
  elif [ -r "$CONF" ]; then
    # shellcheck source=pw-failover.conf
    . "$CONF"; CONF_SRC=$CONF
  fi
  [ -n "${DAEMON:-}" ] && conf_watch
  # A drill (pw-failover-drill.sh) shortens the switch-back holds until its marker expires.
  if [ -r "$RUN/drill" ]; then
    if [ "$(now)" -lt "$(awk '{print $2}' "$RUN/drill")" ]; then
      # shellcheck disable=SC1091
      [ -r "$RUN/overrides" ] && . "$RUN/overrides"
    else
      rm -f "$RUN/drill" "$RUN/overrides"; log "drill marker expired"
    fi
  fi
  SOCKS=127.0.0.1:$(uci -q get passwall2.@global[0].node_socks_port || echo 1070)
  [ -n "$REPORT_NAME" ] || REPORT_NAME=$(uci -q get system.@system[0].hostname || echo OpenWrt)
  load_manual
}

conf_watch() {   # daemon only: log each setting that changed since the last loop, and bad values
  local k v o changed=
  for k in $CONF_KEYS; do
    eval "v=\$$k; o=\${SEEN_$k-}"
    [ "$v" = "$o" ] && continue
    [ -n "${CONF_WATCHED:-}" ] && changed="$changed, $k ${o:-(empty)} → ${v:-(empty)}"
    eval "SEEN_$k=\$v"
  done
  [ -n "${CONF_WATCHED:-}" ] && [ -n "$changed" ] && event "settings changed ($CONF_SRC): ${changed#, }"
  [ "$CONF_BAD" = "${CONF_BAD_SEEN:-}" ] || { [ -n "$CONF_BAD" ] && event "ignored invalid settings, defaults used: $CONF_BAD"; }
  CONF_WATCHED=1; CONF_BAD_SEEN=$CONF_BAD
}

cmd_conf() {   # the settings in effect: KEY='value' lines, safe to eval; --json for LuCI
  local k v
  if [ "${1:-}" = --json ]; then
    set +u; . /usr/share/libubox/jshn.sh
    json_init; json_add_string source "$CONF_SRC"; json_add_string invalid "$CONF_BAD"
    json_add_object values
    for k in $CONF_KEYS; do eval "v=\$$k"; json_add_string "$k" "$v"; done
    json_close_object; json_dump
  else
    echo "# source: $CONF_SRC${CONF_BAD:+; ignored invalid: $CONF_BAD}"
    for k in $CONF_KEYS; do eval "v=\$$k"; printf "%s='%s'\n" "$k" "$(printf %s "$v" | sed "s/'/'\\\\''/g")"; done
  fi
}

cmd_conf_to_uci() {   # one-time import of $CONF into uci; never overwrites an existing section
  local k v o w
  [ -n "$(uci -q get "$UCI_CONF.main")" ] && { echo "$UCI_CONF.main already exists; nothing imported" >&2; return 1; }
  [ -r "$CONF" ] || { echo "no $CONF to import" >&2; return 1; }
  conf_defaults; . "$CONF"
  touch "/etc/config/$UCI_CONF"
  uci set "$UCI_CONF.main=settings"
  set -f
  for k in $CONF_KEYS; do
    eval "v=\$$k"; o=$(echo "$k" | tr 'A-Z' 'a-z')
    case " $CONF_LISTS " in
      *" $k "*) for w in $v; do uci add_list "$UCI_CONF.main.$o=$w"; done ;;
      *) [ -n "$v" ] && uci set "$UCI_CONF.main.$o=$v" ;;
    esac
  done
  set +f
  uci commit "$UCI_CONF" && echo "imported $CONF into /etc/config/$UCI_CONF; $CONF is no longer read"
}

# --- small helpers ------------------------------------------------------------------------------
now() { date +%s; }
hms() { date ${1:+-d "@$1"} +%H:%M:%S; }
dur() { local s=$1; if [ "$s" -ge 3600 ]; then echo "$((s / 3600))h$((s % 3600 / 60))m"; elif [ "$s" -ge 60 ]; then echo "$((s / 60))m$((s % 60))s"; else echo "${s}s"; fi; }
log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
  [ "$(wc -c < "$LOG")" -gt 65536 ] && tail -c 32768 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  return 0
}
event() { log "$*"; logger -t pw-failover "$*"; }          # key events also reach syslog
# Keep a file to its first 20 and last 150 lines once it passes 24 KB: a days-long outage retried
# every 30 min must not grow it without bound, and its start and end are what matter.
cap_file() {
  [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -gt 24576 ] || return 0
  { head -n 20 "$1"; echo "… (trimmed)"; tail -n 150 "$1"; } > "$1.tmp" && mv "$1.tmp" "$1"
}
# The incident timeline, only while an outage is open; otherwise the line goes to the log alone.
tl() {
  [ -e "$RUN/outage" ] && { printf '%s %s\n' "$(hms)" "$*" >> "$RUN/timeline"; cap_file "$RUN/timeline"; }
  event "$*"
}
# Long-lived children (xray, dnsmasq) must not inherit the lock fds, or they hold the locks forever.
nofd() { "$@" 8>&- 9>&-; }
# observe mode: say what would run instead of running it
act() { if [ "$MODE" = act ]; then nofd "$@"; else log "[observe] would run: $*"; fi; }
scaled() { local v=$(($1 << $2)); [ "$v" -gt "$3" ] && v=$3; echo "$v"; }   # $1 * 2^$2, capped at $3

ug() { uci -q get "passwall2.$1"; }
# Where the egress node is set: a shunt global node sends its default rule to <shunt>.default_node;
# any other global node is the egress node itself.
node_slot() {
  local g; g=$(ug @global[0].node)
  if [ "$(ug "$g.protocol")" = _shunt ]; then echo "$g.default_node"; else echo "@global[0].node"; fi
}
cur_node() { ug "$(node_slot)"; }
# Lock files or dirs that other tools hold while they restart passwall2 (EXTRA_LOCKS).
locks_held() { local l; for l in $EXTRA_LOCKS; do [ -e "$l" ] && { echo "$l"; return 0; }; done; return 1; }
node_label() { local r; r=$(ug "$1.remarks"); echo "${r:-$1}"; }
node_addr() { echo "$(ug "$1.address"):$(ug "$1.port")"; }
# The node the router itself dials for node $1: its pre-proxy when it rides one (passwall2's
# chain_proxy 1), since the node's own server is then reached from the far side of that hop. One
# level, as passwall2 builds it; a pre-proxy that no longer exists is skipped, so the node itself.
node_dial_id() {
  local pre=
  [ "$(ug "$1.chain_proxy")" = 1 ] && pre=$(ug "$1.preproxy_node")
  if [ -n "$pre" ] && [ "$(uci -q get "passwall2.$pre")" = nodes ]; then echo "$pre"; else echo "$1"; fi
}
node_dial_addr() { ug "$(node_dial_id "$1").address"; }
# Is port $1 in the comma-separated list $2 (TIER1_PORT, TIER2_PORT)? An empty list means any port.
port_in() {
  local p IFS=', '
  [ -n "$2" ] || return 0
  for p in $2; do [ "$p" = "$1" ] && return 0; done
  return 1
}

# --- persistent state (fallback node) and tmpfs WAN state -------------------------------------
FALLBACK_NODE=; FALLBACK_SINCE=0; SB_PASSES=0; NODE_SB_K=0
load_state() { FALLBACK_NODE=; FALLBACK_SINCE=0; SB_PASSES=0; NODE_SB_K=0; [ -r "$STATE" ] && . "$STATE"; return 0; }
save_state() {
  printf 'FALLBACK_NODE=%s\nFALLBACK_SINCE=%s\nSB_PASSES=%s\nNODE_SB_K=%s\n' \
    "$FALLBACK_NODE" "$FALLBACK_SINCE" "$SB_PASSES" "$NODE_SB_K" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
clear_state() { rm -f "$STATE"; load_state; }

# The manual override: M_WAN and M_NODE are the pins (empty = automatic), M_UNTIL its expiry (0 =
# until cleared), M_HOLD=1 keeps it even when nothing works inside it.
M_WAN=; M_NODE=; M_SINCE=0; M_UNTIL=0; M_HOLD=0
load_manual() { M_WAN=; M_NODE=; M_SINCE=0; M_UNTIL=0; M_HOLD=0; [ -r "$MANUAL" ] && . "$MANUAL"; return 0; }
save_manual() {
  [ -n "$M_WAN$M_NODE" ] || { rm -f "$MANUAL"; return 0; }
  printf 'M_WAN=%s\nM_NODE=%s\nM_SINCE=%s\nM_UNTIL=%s\nM_HOLD=%s\n' \
    "$M_WAN" "$M_NODE" "$M_SINCE" "$M_UNTIL" "$M_HOLD" > "$MANUAL.tmp" && mv "$MANUAL.tmp" "$MANUAL"
}
pinned() { [ -n "$M_WAN$M_NODE" ]; }
# Where the house belongs: the pinned WAN and node while an override holds, else the primaries.
home_wan() { if [ -n "$M_WAN" ]; then echo "$M_WAN"; else primary_wan; fi; }
home_node() { echo "${M_NODE:-$PRIMARY_NODE}"; }
manual_text() {   # one line on the override in force, or nothing
  pinned || return 0
  printf '📌 Manual override: WAN %s, node %s, %s; %s.\n' "${M_WAN:-automatic}" \
    "$([ -n "$M_NODE" ] && node_label "$M_NODE" || echo automatic)" \
    "$([ "$M_UNTIL" -gt 0 ] && echo "until $(hms "$M_UNTIL")" || echo "until cleared")" \
    "$([ "$M_HOLD" = 1 ] && echo "held even if nothing works in it" || echo "dropped if nothing works in it")"
}

WAN_REASON=down; WAN_SINCE=0; WAN_OK_SINCE=0; WAN_SB_K=0
load_wan() { WAN_REASON=down; WAN_SINCE=0; WAN_OK_SINCE=0; WAN_SB_K=0; [ -r "$RUN/wan" ] && . "$RUN/wan"; return 0; }
save_wan() {
  printf 'WAN_REASON=%s\nWAN_SINCE=%s\nWAN_OK_SINCE=%s\nWAN_SB_K=%s\n' \
    "$WAN_REASON" "$WAN_SINCE" "$WAN_OK_SINCE" "$WAN_SB_K" > "$RUN/wan"
}

# --- nodes --------------------------------------------------------------------------------------
# Hard deny, checked wherever a node is chosen, not only in the chain filter: DENY_NODES, pseudo-nodes
# (_shunt, _balancing…), and anything dialled at a DENY_ADDRS address (node_dial_addr: the
# pre-proxy's for a node behind one).
node_allowed() {
  [ "$(uci -q get "passwall2.$1")" = nodes ] || return 1
  case " $DENY_NODES " in *" $1 "*) return 1 ;; esac
  case "$(ug "$1.protocol")" in ""|_*) return 1 ;; esac
  case " $DENY_ADDRS " in *" $(node_dial_addr "$1") "*) return 1 ;; esac
  return 0
}
CHAIN=
chain_add() { case " $CHAIN " in *" $1 "*) return 0 ;; esac; node_allowed "$1" && CHAIN="$CHAIN $1"; return 0; }
node_chain() {   # primary, then tier 1, then tier 2, each in uci (= LuCI tab) order, then tier 3
  local ids id
  CHAIN=
  # a manual node pin: an incident tries that node alone
  [ -n "$M_NODE" ] && { chain_add "$M_NODE"; echo $CHAIN; return; }
  ids=$(uci -q show passwall2 | sed -n 's/^passwall2\.\([^.=]*\)=nodes$/\1/p')
  [ -n "$PRIMARY_NODE" ] && chain_add "$PRIMARY_NODE"
  [ -n "$TIER1_GROUP" ] && for id in $ids; do
    [ "$(ug "$id.group")" = "$TIER1_GROUP" ] || continue
    port_in "$(ug "$id.port")" "$TIER1_PORT" || continue
    chain_add "$id"
  done
  [ -n "$TIER2_GROUP" ] && for id in $ids; do
    [ "$(ug "$id.group")" = "$TIER2_GROUP" ] || continue
    port_in "$(ug "$id.port")" "$TIER2_PORT" || continue
    chain_add "$id"
  done
  for id in $TIER3_NODES; do chain_add "$id"; done   # named nodes, in the order listed
  echo $CHAIN
}

xray_pid() { pgrep -f "$XRAY_PAT" | head -n1; }
xray_age() {   # seconds; a missing xray counts as old, so a dead tunnel is still probed
  local p t
  p=$(xray_pid); [ -n "$p" ] || { echo 999999; return; }
  t=$(date -r "/proc/$p" +%s 2>/dev/null) || { echo 999999; return; }
  echo $(($(now) - t))
}

# Is this exit address the tunnel's? With EXPECT_EXIT_IPS set, only those addresses are; without,
# anything but an address in PROBE_BAD_LOC (the country the direct path exits in). $2 = trace text.
exit_ok() {
  if [ -n "$EXPECT_EXIT_IPS" ]; then
    case " $EXPECT_EXIT_IPS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
  fi
  case "${2:-}" in *"loc=${PROBE_BAD_LOC:-none} "*) return 1 ;; esac
  return 0
}

# The live tunnel, through the running xray: the exit address it reports must be the tunnel's.
# Cloudflare's trace first, ifconfig.co as a second opinion, so neither service's hiccup alone is an
# outage; either one passes. An answer from a *different* address is a failure, not a pass: traffic
# that works but leaves outside the tunnel is exactly what this must catch. PROBE_WRONG keeps that
# address for the incident (empty when nothing answered at all).
PROBE_OUT=; PROBE_WRONG=
probe() {
  local out ip ip2
  PROBE_WRONG=
  [ -e "$RUN/force-fail" ] && { PROBE_OUT="forced fail ($RUN/force-fail)"; return 1; }
  out=$(curl -s -m 6 -x "socks5h://$SOCKS" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep -E '^(ip|loc)=' | tr '\n' ' ')
  ip=$(echo "$out" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')
  [ -n "$ip" ] && exit_ok "$ip" "$out" && { PROBE_OUT=$out; return 0; }
  ip2=$(curl -s -m 5 -x "socks5h://$SOCKS" https://ifconfig.co 2>/dev/null | head -c 45 | tr -d ' \r\n')
  echo "$ip2" | grep -qE '^[0-9a-fA-F.:]+$' || ip2=
  [ -n "$ip2" ] && exit_ok "$ip2" && { PROBE_OUT="ip=$ip2 (ifconfig.co)"; return 0; }
  PROBE_WRONG=${ip:-$ip2}
  if [ -n "$PROBE_WRONG" ]; then
    PROBE_OUT="wrong exit: trace[${out:-none}] ifconfig.co[${ip2:-none}], expected ${EXPECT_EXIT_IPS:-not $PROBE_BAD_LOC}"
  else
    PROBE_OUT="no answer: trace[none] ifconfig.co[none]"
  fi
  return 1
}

# passwall2's own URL test (the LuCI button): a throwaway xray SOCKS for the node, curl through it.
# Node IPs sit in psw2_vps and xray marks its sockets 255, so this reaches the node directly over
# the main routing table even while the running tunnel is dead. Sets UT for the report.
# 0 = pass, 1 = fail, 2 = no usable result (tester broke, or xray restarted under it).
UT=
url_test() {
  local before out ms
  before=$(xray_pid)
  out=$(nofd timeout -k 5 25 "$TEST_SH" url_test_node "$1" 2>/dev/null | tail -n1)
  [ "$(xray_pid)" = "$before" ] || { UT="interrupted"; return 2; }
  case "$out" in
    200:*|204:*) ms=$(echo "${out#*:}" | awk '{printf "%d", $1 * 1000}'); UT="$ms ms"; return 0 ;;
    000:*) UT="timeout"; return 1 ;;
    [0-9][0-9][0-9]:*) UT="HTTP ${out%%:*}"; return 1 ;;
    *) UT="no result${out:+ ($out)}"; return 2 ;;
  esac
}

# --- WANs ---------------------------------------------------------------------------------------
primary_wan() { set -- $WAN_ORDER; echo "$1"; }
wan_is_up() { [ "$(ifstatus "$1" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)" = true ]; }
wan_dev() {
  local d; d=$(ifstatus "$1" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
  echo "${d:-$(uci -q get "network.$1.device")}"
}
wan_gw() { ifstatus "$1" 2>/dev/null | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null | head -n1; }
wan_of_dev() {
  local w; for w in $WAN_ORDER; do [ "$(wan_dev "$w")" = "$1" ] && { echo "$w"; return; }; done; echo "$1"
}
override_dev() { ip -4 route show default proto "$ROUTE_PROTO" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; }
override_gw() { ip -4 route show default proto "$ROUTE_PROTO" 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p' | head -n1; }
route_dev() { ip -4 route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; }
active_wan() { wan_of_dev "$(route_dev)"; }

targets() {   # ping targets as IPs: host=seed entries use the cached lookup, else the seed
  local t ip
  for t in $WAN_TARGETS; do
    case "$t" in
      *=*) ip=$(cat "$PERSIST/ip.${t%%=*}" 2>/dev/null); echo "${ip:-${t#*=}}" ;;
      *) echo "$t" ;;
    esac
  done
}
LAST_RESOLVE=0
refresh_targets() {   # hourly, only while healthy, so a broken resolver never poisons the cache
  local t h ip
  [ $(($(now) - LAST_RESOLVE)) -ge 3600 ] || return 0
  LAST_RESOLVE=$(now)
  for t in $WAN_TARGETS ${DIRECT_CHECK_URL:+check=$DIRECT_CHECK_URL}; do
    case "$t" in check=*) t=${t#check=}; t=${t#*://}; t=${t%%/*}; t="${t%%:*}=" ;; *=*) ;; *) continue ;; esac
    h=${t%%=*}
    ip=$(nslookup "$h" 127.0.0.1 2>/dev/null | awk '/^Name:/ {n = 1} n && /^Address/ {print $2; exit}')
    case "$ip" in 198.18.*|"") continue ;; esac   # never cache a FakeDNS answer
    echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
    [ "$ip" = "$(cat "$PERSIST/ip.$h" 2>/dev/null)" ] || { echo "$ip" > "$PERSIST/ip.$h"; log "cached $h = $ip"; }
  done
}
# Direct-internet check for one WAN device, outside passwall2. First DIRECT_CHECK_URL, an IP-echo
# URL on passwall2's direct list (its address must be in a direct IP rule such as geoip:<cc>, so the
# router's own request skips the tunnel), fetched with curl bound to the device: an IP back means
# the line works, and it is the line's public IP. Then, if that fails, a ping of WAN_TARGETS bound
# to the device: ICMP never enters passwall2, and it keeps one echo service's outage from looking
# like every WAN dying. SO_BINDTODEVICE skips routes on other devices, so both test this line even
# while the metric-0 override points elsewhere.
# Sets REACH_RTT (ms), REACH_HOW (http|ping), REACH_IP (public IP, http only) and REACH_TAG, the
# "ok <ms> <how> <ip>" verdict the report and page read.
REACH_RTT=; REACH_HOW=; REACH_IP=; REACH_TAG=
direct_url_check() {
  local host port ip out pub t
  [ -n "$DIRECT_CHECK_URL" ] || return 1
  host=${DIRECT_CHECK_URL#*://}; host=${host%%/*}; host=${host%%:*}
  case "$DIRECT_CHECK_URL" in https://*) port=443 ;; *) port=80 ;; esac
  ip=$(cat "$PERSIST/ip.$host" 2>/dev/null)
  out=$(curl -s -m 6 --interface "$1" ${ip:+--resolve "$host:$port:$ip"} -w '\n%{time_total}' \
    "$DIRECT_CHECK_URL" 2>/dev/null) || return 1
  pub=$(echo "$out" | head -n1 | tr -d ' \r'); t=$(echo "$out" | tail -n1)
  echo "$pub" | grep -qE '^[0-9a-fA-F.:]{3,45}$' || return 1
  REACH_IP=$pub; REACH_HOW=http; REACH_RTT=$(echo "$t" | awk '{printf "%d", $1 * 1000}')
  return 0
}
wan_reach() {
  local ip out
  REACH_RTT=; REACH_HOW=; REACH_IP=; REACH_TAG=
  if ! direct_url_check "$1"; then
    for ip in $(targets); do
      out=$(ping -q -c 3 -W 2 -I "$1" "$ip" 2>/dev/null) || continue
      REACH_RTT=$(echo "$out" | sed -n 's|.*= [0-9.]*/\([0-9]*\).*|\1|p'); REACH_HOW=ping
      break
    done
  fi
  [ -n "$REACH_HOW" ] || return 1
  REACH_TAG="ok ${REACH_RTT:-?} $REACH_HOW ${REACH_IP:--}"
  return 0
}
# Last known direct health per WAN, one line each:
#   name dev up(1|0) gw direct(ok|down|-) rtt epoch public-ip how(http|ping)
wanstat_set() {
  { grep -v "^$1 " "$RUN/wanstat" 2>/dev/null
    echo "$1 ${2:--} $3 ${4:--} $5 ${6:--} $(now) ${7:--} ${8:--}"; } > "$RUN/wanstat.tmp" && mv "$RUN/wanstat.tmp" "$RUN/wanstat"
}
wanstat_check() {   # ping one WAN directly if it is up; never raises anything
  local w=$1 dev gw
  dev=$(wan_dev "$w")
  if wan_up_now "$w"; then
    gw=$(wan_gw "$w")
    if wan_reach "$dev"; then wanstat_set "$w" "$dev" 1 "$gw" ok "$REACH_RTT" "$REACH_IP" "$REACH_HOW"; return 0; fi
    wanstat_set "$w" "$dev" 1 "$gw" down; return 1
  fi
  wanstat_set "$w" "$dev" 0 "" -; return 1
}
# Direct checks of every up WAN while the tunnel is healthy. Off by default (WAN_STAT_INTERVAL=0):
# then they run only when the tunnel probe has failed (incidents), for the primary while on a backup
# (switch-back), and once on each `retest`, which sets WANSTAT_NOW.
LAST_WANSTAT=0; WANSTAT_NOW=0
wanstat_refresh() {
  local w
  if [ "$WANSTAT_NOW" = 1 ]; then WANSTAT_NOW=0
  else
    [ "${WAN_STAT_INTERVAL:-0}" -gt 0 ] || return 0
    [ $(($(now) - LAST_WANSTAT)) -ge "$WAN_STAT_INTERVAL" ] || return 0
  fi
  LAST_WANSTAT=$(now)
  for w in $WAN_ORDER; do wanstat_check "$w"; done
}
# Make $1 usable. The primary WAN belongs to netifd and is never bounced. A backup that is down is
# raised with ifup whatever its `auto` setting (wan_walk only reaches it as a last resort), and it is
# lowered again only if this script raised it (recorded in $RUN/raised).
wan_up_now() { wan_is_up "$1" && [ -n "$(wan_gw "$1")" ]; }
RAISE_NOTE=
wan_raise() {
  local w=$1 i=0
  RAISE_NOTE=
  wan_up_now "$w" && return 0
  RAISE_NOTE=not-up
  [ "$w" = "$(primary_wan)" ] && return 1
  if [ "$MODE" != act ]; then tl "$w: down — would ifup it as a last resort"; return 1; fi
  RAISE_NOTE=no-lease
  tl "$w: down, ifup as a last resort, waiting up to ${WAN_UP_WAIT}s for a lease"
  grep -qx "$w" "$RUN/raised" 2>/dev/null || echo "$w" >> "$RUN/raised"
  nofd ifup "$w"
  while [ "$i" -lt "$WAN_UP_WAIT" ]; do
    sleep 2; i=$((i + 2))
    wan_up_now "$w" && return 0
  done
  tl "$w: no lease in ${WAN_UP_WAIT}s"
  wan_lower "$w"
  return 1
}
wan_lower() {
  grep -qx "$1" "$RUN/raised" 2>/dev/null || return 0
  act ifdown "$1"
  sed -i "/^$1\$/d" "$RUN/raised"
  tl "$1: ifdown (pw-failover had raised it)"
}
# Incident order: the primary, then the backups already up, then the backups that are down, each
# group in WAN_ORDER order. A spare modem that is already up is tried before a backup further down
# the list; one that is down is raised only after every other WAN has failed.
wan_walk() {
  [ -n "$M_WAN" ] && { echo "$M_WAN"; return; }   # a manual WAN pin: an incident stays on it
  wan_walk_all
}
wan_walk_all() {   # the walk without a pin, also the page's WAN table
  local pw w up= down=
  pw=$(primary_wan)
  for w in $WAN_ORDER; do
    [ "$w" = "$pw" ] && continue
    if wan_up_now "$w"; then up="$up $w"; else down="$down $w"; fi
  done
  echo "$pw$up$down"
}
wan_walk_label() {   # the walk as status shows it, a backup that would be raised marked (ifup)
  local w pw out=
  pw=$(primary_wan)
  for w in $(wan_walk); do
    if [ "$w" != "$pw" ] && ! wan_up_now "$w"; then out="$out → $w (ifup)"; else out="$out → $w"; fi
  done
  echo "${out# → }${M_WAN:+ (manual pin)}"
}
lower_unused() {   # everything we raised that is not carrying traffic now
  local w a; a=$(active_wan)
  for w in $(cat "$RUN/raised" 2>/dev/null); do [ "$w" = "$a" ] || wan_lower "$w"; done
}

# --- actions ------------------------------------------------------------------------------------
ACTED=0; RESTARTS=0; PRE_XRAY=; EGRESS=
# Before the first change of an incident, look once more: a tunnel that came back by itself must
# not cost the house a restart. Return 1 = it recovered, do nothing.
first_action() {
  [ "$ACTED" = 1 ] && return 0
  if probe; then tl "tunnel recovered on its own before any change"; return 1; fi
  ACTED=1; touch "$RUN/outage.acted"
  return 0
}

# Route all egress through $1. 0 = done (ROUTE_CHANGED says if anything moved), 1 = cannot,
# 3 = the tunnel recovered on its own first.
ROUTE_CHANGED=0
activate_wan() {
  local w=$1 cur dev gw
  ROUTE_CHANGED=0
  cur=$(override_dev)
  if [ "$w" = "$(primary_wan)" ]; then
    [ -z "$cur" ] && return 0
    first_action || return 3
    act ip -4 route flush proto "$ROUTE_PROTO"
  else
    dev=$(wan_dev "$w"); gw=$(wan_gw "$w")
    [ -n "$gw" ] && [ -n "$dev" ] || { tl "$w: no gateway known"; return 1; }
    [ "$cur" = "$dev" ] && return 0
    first_action || return 3
    act ip -4 route replace default via "$gw" dev "$dev" metric 0 proto "$ROUTE_PROTO"
  fi
  ROUTE_CHANGED=1
  tl "egress route → $w"
  return 0
}

apply_node() {
  local id=$1
  node_allowed "$id" || { tl "REFUSED to select $(node_label "$id") ($id): on the deny list"; return 1; }
  [ "$(cur_node)" = "$id" ] && return 0
  [ -n "$(uci -q changes passwall2)" ] && tl "note: committing staged passwall2 edits too: $(uci -q changes passwall2 | tr '\n' ' ')"
  act uci set "passwall2.$(node_slot)=$id"
  act uci commit passwall2
  tl "default node → $(node_label "$id") ($(node_addr "$id"))"
}

# passwall2 has no reload: a restart rebuilds the nft ruleset and drops LAN proxying for 5-15 s.
pw_restart() {
  local i=0
  RESTARTS=$((RESTARTS + 1))
  [ "$RESTARTS" -le "$MAX_RESTARTS" ] || { tl "restart cap ($MAX_RESTARTS) reached"; return 1; }
  [ "$MODE" = act ] || { tl "[observe] would restart passwall2"; return 0; }
  # Never take another tool's lock (its own restart would then silently skip); wait it out.
  while locks_held >/dev/null && [ "$i" -lt 60 ]; do sleep 2; i=$((i + 2)); done
  PRE_XRAY=$(xray_pid)
  tl "restarting passwall2"
  # setsid: a stop/restart of this service must not kill passwall2 halfway through its restart.
  setsid /etc/init.d/passwall2 restart >/dev/null 2>&1 </dev/null 8>&- 9>&- &
  wait $!
  return 0
}

# 0 = the tunnel works through the running xray. $1 = restart: first wait for the new xray.
VERIFY_WRONG=
verify() {
  local i=0 p ok=0
  VERIFY_WRONG=
  if [ "${1:-}" = restart ]; then
    while [ "$i" -lt 90 ]; do
      p=$(xray_pid)
      [ -n "$p" ] && [ "$p" != "$PRE_XRAY" ] && netstat -lnt 2>/dev/null | grep -q ":${SOCKS##*:} " && break
      sleep 3; i=$((i + 3))
    done
    sleep 3
  fi
  for i in 1 2 3; do
    probe && ok=$((ok + 1))
    [ "$i" -lt 3 ] && sleep 5
  done
  if [ "$ok" -ge 2 ]; then
    EGRESS=$(curl -s -m 10 -x "socks5h://$SOCKS" https://ifconfig.co 2>/dev/null | head -c 45 | tr -d ' \r\n')
    tl "verified: $ok/3 probes ok, egress ${EGRESS:-?} via $(active_wan)"
    return 0
  fi
  VERIFY_WRONG=$PROBE_WRONG
  tl "verify failed: $ok/3 probes ok ($PROBE_OUT)"
  return 1
}

# --- incident -----------------------------------------------------------------------------------
record_ut() { printf '%s [%s] %s — %s\n' "$(hms)" "$2" "$(node_label "$1")" "$UT" >> "$RUN/urltests"; cap_file "$RUN/urltests"; }

# 0 = egress verified on $1, 1 = not, 3 = the tunnel recovered on its own.
try_node() {
  local id=$1 w=$2 rc
  url_test "$id"; rc=$?
  [ "$rc" -eq 2 ] && { sleep 5; url_test "$id"; rc=$?; }   # xray churned under it: once more
  record_ut "$id" "$w"
  [ "$rc" -eq 0 ] || return 1
  if [ "$MODE" != act ]; then
    tl "[observe] would use $(node_label "$id") on $w"; touch "$RUN/outage.acted"; return 0
  fi
  first_action || return 3
  apply_node "$id" || return 1
  pw_restart || return 1
  verify restart
}

# Find a working node over WAN $1 (already routed). 0 = ok, 1 = none, 3 = recovered on its own.
SEL_HOW=
select_node() {
  local w=$1 cur id rc bad=" "
  SEL_HOW=
  cur=$(cur_node)
  if [ "$ROUTE_CHANGED" = 0 ]; then
    # Same route, and the running node fails the live probe. If the node itself passes its URL
    # test, the fault is inside the running passwall2: restart it and change nothing else.
    url_test "$cur"; rc=$?
    [ "$rc" -eq 2 ] && { sleep 5; url_test "$cur"; rc=$?; }
    record_ut "$cur" "$w"
    if [ "$rc" -eq 0 ]; then
      tl "$(node_label "$cur") passes its URL test: the fault is in the running passwall2"
      SEL_HOW=restart
      if [ "$MODE" != act ]; then tl "[observe] would restart passwall2"; touch "$RUN/outage.acted"; return 0; fi
      first_action || return 3
      pw_restart && verify restart && return 0
      LAST_WRONG=$VERIFY_WRONG
    fi
    bad=" $cur "
  fi
  for id in $(node_chain); do
    case "$bad" in *" $id "*) continue ;; esac
    SEL_HOW=node
    try_node "$id" "$w"; rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] && return "$rc"
    # Wrong exit address after a switch: a bad node, try the next. The same wrong address from two
    # different nodes means it is not the nodes but passwall2's routing (traffic leaving outside the
    # tunnel), which more switches and restarts cannot fix.
    if [ -n "$VERIFY_WRONG" ]; then
      if [ "$VERIFY_WRONG" = "$LAST_WRONG" ]; then
        tl "two nodes in a row exit at $VERIFY_WRONG, not the tunnel: this is passwall2 routing, not the nodes; stopping"
        echo "$VERIFY_WRONG" > "$RUN/wrong_exit"; WALK_ABORT=1; return 1
      fi
      LAST_WRONG=$VERIFY_WRONG
    fi
    [ "$RESTARTS" -ge "$MAX_RESTARTS" ] && { tl "restart cap reached on $w"; return 1; }
  done
  return 1
}

BACKOFF_IDX=0; NEXT_INCIDENT_AT=0
# One line per WAN the incident reached: name|dev|direct|tunnel. direct: ok <ms> | down | not-up |
# no-lease. tunnel: ok:<node> | restart | failed | -. The report and the status page read it.
wcheck() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$RUN/wancheck"; }
# The outage's cause, from the primary WAN in its first incident: down | not-up | tunnel | node |
# passwall. Written once per outage, so a later retry cannot overwrite what actually broke.
set_cause() { [ -s "$RUN/cause" ] || echo "$1" > "$RUN/cause"; }

incident() {
  local w dev rc primary_up=0 first_backup= pw
  ACTED=0; RESTARTS=0; EGRESS=; LAST_WRONG=; WALK_ABORT=0
  pw=$(home_wan)
  load_wan
  echo "$(now)" >> "$RUN/incidents"
  : > "$RUN/wancheck"; wan_walk > "$RUN/walk"
  touch "$RUN/incident.running"
  tl "incident: $FAIL_THRESHOLD probes failed ($PROBE_OUT); egress $(active_wan), node $(node_label "$(cur_node)")"
  pinned && tl "$(manual_text)"
  tl "WAN order: $(wan_walk_label)"
  for w in $(wan_walk); do
    if ! wan_raise "$w"; then
      tl "$w: not up"; wcheck "$w" "$(wan_dev "$w")" "$RAISE_NOTE" -
      wanstat_set "$w" "$(wan_dev "$w")" 0 "" -
      [ "$w" = "$pw" ] && set_cause not-up
      continue
    fi
    dev=$(wan_dev "$w")
    if ! wan_reach "$dev"; then
      tl "$w: no direct internet: ${DIRECT_CHECK_URL:+no answer from $DIRECT_CHECK_URL and }no ping reply from $(targets | tr '\n' ' ')(outside passwall2)"
      wcheck "$w" "$dev" down -; wanstat_set "$w" "$dev" 1 "$(wan_gw "$w")" down
      [ "$w" = "$pw" ] && set_cause down
      wan_lower "$w"; continue
    fi
    tl "$w: direct internet ok ($REACH_HOW, ${REACH_RTT:-?} ms${REACH_IP:+, public IP $REACH_IP}, outside passwall2)"
    wanstat_set "$w" "$dev" 1 "$(wan_gw "$w")" ok "$REACH_RTT" "$REACH_IP" "$REACH_HOW"
    if [ "$w" = "$pw" ]; then primary_up=1; else [ -z "$first_backup" ] && first_backup=$w; fi
    activate_wan "$w"; rc=$?
    [ "$rc" -eq 3 ] && { incident_self; return; }
    [ "$rc" -eq 0 ] || { wcheck "$w" "$dev" "$REACH_TAG" -; wan_lower "$w"; continue; }
    select_node "$w"; rc=$?
    [ "$rc" -eq 3 ] && { incident_self; return; }
    if [ "$rc" -eq 0 ]; then
      if [ "$SEL_HOW" = restart ]; then
        wcheck "$w" "$dev" "$REACH_TAG" restart; [ "$w" = "$pw" ] && set_cause passwall
      else
        wcheck "$w" "$dev" "$REACH_TAG" "ok:$(cur_node)"; [ "$w" = "$pw" ] && set_cause node
      fi
      incident_ok "$w" "$primary_up"; return
    fi
    if [ "$WALK_ABORT" = 1 ]; then
      wcheck "$w" "$dev" "$REACH_TAG" wrong-exit; set_cause egress
      break
    fi
    tl "$w: direct internet fine, but no tunnel node works over it"
    wcheck "$w" "$dev" "$REACH_TAG" failed
    [ "$w" = "$pw" ] && set_cause tunnel
    [ "$RESTARTS" -ge "$MAX_RESTARTS" ] && break
  done
  incident_failed "$primary_up" "$first_backup"
}

incident_self() { BACKOFF_IDX=0; NEXT_INCIDENT_AT=0; rm -f "$RUN/incident.running"; }

incident_ok() {
  local w=$1 primary_up=$2 node
  if [ "$MODE" != act ]; then
    # Nothing changed, so the tunnel is still down: keep the outage open (its report goes out
    # when the tunnel is back) and look again in 30 min rather than every minute.
    NEXT_INCIDENT_AT=$(($(now) + 1800)); tl "[observe] no change made; next look in 30m"
    return
  fi
  BACKOFF_IDX=0; NEXT_INCIDENT_AT=0
  node=$(cur_node)
  load_state
  if [ "$node" = "$(home_node)" ]; then
    [ -n "$FALLBACK_NODE" ] && clear_state
  elif [ "$node" != "$FALLBACK_NODE" ]; then
    FALLBACK_NODE=$node; FALLBACK_SINCE=$(now); SB_PASSES=0; save_state
  fi
  if [ "$w" = "$(primary_wan)" ] || [ -n "$M_WAN" ]; then   # a pinned WAN has no switch-back
    rm -f "$RUN/wan"
  else
    # nodes = wan pinged but no node worked over it, so the switch-back waits longer
    load_wan
    if [ "$primary_up" = 1 ]; then WAN_REASON=nodes; else WAN_REASON=down; fi
    WAN_SINCE=$(now); WAN_OK_SINCE=0; save_wan
  fi
  lower_unused
  outage_close
}

# Nothing worked anywhere. With the primary WAN pinging, the fault is most likely the far end (the
# server behind the nodes), so go home to it and the primary node rather than spend a metered
# backup's data; with it down, keep the first backup that pings, since direct traffic still works.
# Under a manual override nothing worked inside the pin: drop it and walk again without it, or,
# when it holds, stay on the pinned WAN and node.
incident_failed() {
  local primary_up=$1 first_backup=$2 target delay
  if pinned && [ "$M_HOLD" != 1 ] && [ "$MODE" = act ]; then
    manual_release "nothing worked inside it"
    incident; return
  fi
  if [ -n "$M_WAN" ]; then target=$M_WAN
  elif [ "$primary_up" = 1 ] || [ -z "$first_backup" ]; then target=$(primary_wan); else target=$first_backup; fi
  activate_wan "$target"
  if [ "$ROUTE_CHANGED" = 1 ] || [ "$(cur_node)" != "$(home_node)" ]; then
    apply_node "$(home_node)" && RESTARTS=0 && pw_restart
    [ "$MODE" = act ] && clear_state
  fi
  if [ "$MODE" = act ]; then
    if [ "$target" = "$(primary_wan)" ] || [ -n "$M_WAN" ]; then rm -f "$RUN/wan"; else
      load_wan; WAN_REASON=down; WAN_SINCE=$(now); WAN_OK_SINCE=0; save_wan
    fi
    lower_unused
  fi
  set -- $BACKOFF
  [ "$BACKOFF_IDX" -ge $# ] && BACKOFF_IDX=$(($# - 1))
  shift "$BACKOFF_IDX"; delay=$1
  BACKOFF_IDX=$((BACKOFF_IDX + 1))
  NEXT_INCIDENT_AT=$(($(now) + delay))
  tl "nothing worked; staying on $target with $(node_label "$(home_node)")$(pinned && echo " (manual override holds)"), next attempt in $(dur "$delay")"
}

rate_ok() {   # at most MAX_INCIDENTS_HOUR incidents an hour, then cool down
  local n c
  n=$(now)
  touch "$RUN/incidents"
  awk -v t=$((n - 3600)) '$1 > t' "$RUN/incidents" > "$RUN/incidents.tmp" \
    && mv "$RUN/incidents.tmp" "$RUN/incidents"
  c=$(wc -l < "$RUN/incidents")
  [ "$c" -lt "$MAX_INCIDENTS_HOUR" ] && return 0
  NEXT_INCIDENT_AT=$((n + INCIDENT_COOLDOWN))
  event "$c incidents in the last hour; cooling down $(dur "$INCIDENT_COOLDOWN")"
  return 1
}

# --- outage bookkeeping and reports ---------------------------------------------------------------
# $RUN/outage holds the start time, node and egress when the tunnel first failed; the timeline and
# URL tests accumulate across retries until the tunnel works again, then go out as one report.
FIRST_FAIL_AT=0
outage_open() {
  [ -e "$RUN/outage" ] && return 0
  printf 'O_START=%s\nO_NODE=%s\nO_WAN=%s\n' "$FIRST_FAIL_AT" "$(cur_node)" "$(active_wan)" > "$RUN/outage"
  : > "$RUN/timeline"; : > "$RUN/urltests"; : > "$RUN/wancheck"; rm -f "$RUN/outage.acted" "$RUN/cause" "$RUN/wrong_exit"
  printf '%s %s\n' "$(hms "$FIRST_FAIL_AT")" "first failed probe" >> "$RUN/timeline"
}

tag() {
  [ -e "$RUN/drill" ] && printf '[DRILL] '
  [ "$MODE" = act ] || printf '[OBSERVE] '
  return 0
}

queue() {   # $1 = file with the text; queue it and try to send now
  local f
  f="$REPORTS/$(date +%Y%m%d-%H%M%S)-$$.pending"
  head -c 3900 "$1" > "$f"; rm -f "$1"
  LAST_SEND=0; send_pending
}

# What broke, in one plain sentence, from the primary WAN's verdict in the outage's first incident.
cause_text() {
  local pw tgt
  pw=$(home_wan); tgt=$(targets | tr '\n' ' '); tgt=${tgt% }
  case "$(cat "$RUN/cause" 2>/dev/null)" in
    down) echo "🔌 TOTAL OUTAGE on $pw: its direct internet was down too (${DIRECT_CHECK_URL:+no answer from $DIRECT_CHECK_URL, }no ping reply from $tgt, all outside passwall2). The line failed, not just the tunnel." ;;
    not-up) echo "🔌 TOTAL OUTAGE on $pw: the interface itself was down." ;;
    tunnel) echo "🧱 Tunnel outage on $pw: its direct internet was fine, but no tunnel node worked over it. The line works; the tunnel is blocked or down on it." ;;
    node) echo "🧱 Node outage on $pw: its direct internet was fine; only $(node_label "$1") stopped working over it." ;;
    passwall) echo "⚙️ passwall2 fault: $pw's direct internet and $(node_label "$1") were both fine; passwall2 itself had stopped passing traffic." ;;
    egress) echo "🧭 Traffic left outside the tunnel: it exited at $(cat "$RUN/wrong_exit" 2>/dev/null) instead of ${EXPECT_EXIT_IPS:-the tunnel}, and switching nodes did not change that. Check passwall2's routing (a direct rule or setting), not the line or the nodes." ;;
  esac
}
# Each WAN the last incident considered, in the order it walked them: direct verdict, then tunnel.
wancheck_text() {
  local w line dev direct tun d t old done=0
  for w in $(cat "$RUN/walk" 2>/dev/null); do
    line=$(grep "^$w|" "$RUN/wancheck" 2>/dev/null | tail -n1)
    if [ -z "$line" ]; then
      if [ "$done" = 1 ]; then echo "  $w: not needed"; else echo "  $w: not tried"; fi
      continue
    fi
    old=$IFS; IFS='|'; set -- $line; IFS=$old
    dev=$2; direct=$3; tun=$4
    case "$direct" in
      "ok "?*)
        set -- $direct
        if [ "${3:-}" = http ]; then d="direct ok (http, ${2} ms, public IP ${4:-?})"
        elif [ "${3:-}" = ping ]; then d="direct ok (ping only, ${2} ms${DIRECT_CHECK_URL:+; $DIRECT_CHECK_URL did not answer})"
        else d="direct ok (${2} ms)"; fi ;;
      ok*) d="direct ok" ;;
      down) d="direct DOWN (no ping reply)" ;;
      not-up) d="interface down" ;;
      no-lease) d="raised with ifup, no DHCP lease in ${WAN_UP_WAIT}s" ;;
      *) d=$direct ;;
    esac
    case "$tun" in
      ok:*) t=" → tunnel ok via $(node_label "${tun#ok:}")"; done=1 ;;
      restart) t=" → tunnel ok after a passwall2 restart"; done=1 ;;
      failed) t=" → tunnel FAILED (no node passed its URL test)" ;;
      wrong-exit) t=" → tunnel answers but exits at $(cat "$RUN/wrong_exit" 2>/dev/null): routing, walk stopped" ;;
      *) t= ;;
    esac
    echo "  $w ($dev): $d$t"
  done
}

outage_close() {   # the tunnel works again: report if anything was done, else just log
  local O_START=0 O_NODE= O_WAN= t node w how hold cause
  [ -e "$RUN/outage" ] || return 0
  . "$RUN/outage"
  t=$(($(now) - O_START)); node=$(cur_node); w=$(active_wan)
  if [ ! -e "$RUN/outage.acted" ]; then
    event "tunnel back after $(dur "$t") on its own, no action taken"
    rm -f "$RUN/outage" "$RUN/outage.acted"; return 0
  fi
  how=
  [ "$w" != "$O_WAN" ] && how="egress $O_WAN → $w"
  [ "$node" != "$O_NODE" ] && how="${how:+$how, }node $(node_label "$O_NODE") → $(node_label "$node")"
  [ -z "$how" ] && how="passwall2 restarted, same WAN and node"
  [ "$MODE" = act ] || how="see timeline for what it would have done"
  {
    printf '%s✅ Internet recovered — pw-failover (%s)\n\n' "$(tag)" "$REPORT_NAME"
    cause=$(cause_text "$O_NODE"); [ -n "$cause" ] && printf '%s\n\n' "$cause"
    printf 'Outage: %s → %s (%s)\n' "$(hms "$O_START")" "$(hms)" "$(dur "$t")"
    printf 'Before: egress %s, node %s\n' "$O_WAN" "$(node_label "$O_NODE")"
    printf 'Fix: %s\n' "$how"
    printf 'Now: egress %s, node %s (%s), exit IP %s\n' "$w" "$(node_label "$node")" "$(node_addr "$node")" "${EGRESS:-?}"
    if [ -s "$RUN/wancheck" ]; then printf '\nWAN checks (direct = ping outside passwall2):\n'; wancheck_text; fi
    if [ -s "$RUN/urltests" ]; then printf '\nURL tests:\n'; cat "$RUN/urltests"; fi
    printf '\nTimeline:\n'; cat "$RUN/timeline"
    if [ "$MODE" = act ]; then
      pinned && printf '\n%s' "$(manual_text)"
      load_wan; hold=$WAN_SB_HOLD_DOWN; [ "$WAN_REASON" = nodes ] && hold=$WAN_SB_HOLD_NODES
      if [ -z "$M_WAN" ] && [ "$w" != "$(primary_wan)" ]; then
        if [ "$hold" -gt 0 ]; then
          printf '\nBack to %s once it pings for %s (left it: %s).\n' "$(primary_wan)" "$(dur "$hold")" "$WAN_REASON"
        else
          printf '\nBack to %s%s at the first check, every %s, where it pings and %s answers over it.\n' \
            "$(primary_wan)" "$([ "$node" != "$(home_node)" ] && echo " and $(node_label "$(home_node)")")" \
            "$(dur "$WAN_SB_CHECK")" "$(node_label "$(home_node)")"
        fi
      elif [ -z "$M_NODE" ] && [ "$node" != "$PRIMARY_NODE" ]; then
        if [ "$NODE_SB_PASSES" -gt 1 ]; then
          printf '\nBack to %s after %s URL-test passes in a row, %s apart.\n' \
            "$(node_label "$PRIMARY_NODE")" "$NODE_SB_PASSES" "$(dur "$NODE_SB_INTERVAL")"
        else
          printf '\nBack to %s at its first passing URL test (tested every %s).\n' \
            "$(node_label "$PRIMARY_NODE")" "$(dur "$NODE_SB_INTERVAL")"
        fi
      fi
    fi
  } > "$RUN/report.txt"
  rm -f "$RUN/outage" "$RUN/outage.acted"
  event "recovered: $how"
  queue "$RUN/report.txt"
}

note() {   # a one-off message (switch-backs)
  { printf '%s' "$(tag)"; printf '%s\n' "$@"; } > "$RUN/note.txt"
  queue "$RUN/note.txt"
}

tg_send() {   # $1 = text file. Through the tunnel; the token never reaches the process list.
  local TELEGRAM_BOT_TOKEN= TELEGRAM_CHAT_ID= code
  [ -r "$TG_ENV" ] || { log "no $TG_ENV"; return 1; }
  . "$TG_ENV"
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || { log "telegram creds empty"; return 1; }
  code=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
    | curl -s -m 20 -x "socks5h://$SOCKS" -K - -o /dev/null -w '%{http_code}' \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text@$1" \
        -d disable_web_page_preview=true 2>/dev/null)
  [ "$code" = 200 ] || { log "telegram send failed (HTTP ${code:-none})"; return 1; }
}

LAST_SEND=0
send_pending() {
  local f
  [ $(($(now) - LAST_SEND)) -ge 60 ] || return 0
  LAST_SEND=$(now)
  for f in "$REPORTS"/*.pending; do
    [ -e "$f" ] || continue
    tg_send "$f" || break
    mv "$f" "${f%.pending}.sent"; log "report sent: ${f##*/}"
  done
  # retention: the newest 20 sent, and the newest 50 unsent (Telegram unreachable for weeks)
  ls -1t "$REPORTS"/*.sent 2>/dev/null | tail -n +21 | xargs -r rm -f
  ls -1t "$REPORTS"/*.pending 2>/dev/null | tail -n +51 | xargs -r rm -f
}

# --- switch-back (maintenance, while healthy) ------------------------------------------------------
# One change at a time, WAN first: back to the primary WAN, and only then back to the primary node.
LAST_WAN_SB=0; LAST_NODE_SB=0
maintain() {
  send_pending
  refresh_targets
  wanstat_refresh
  pinned && manual_enforce
  # A pinned part never switches back. A node that is not pinned is still switched back while a
  # pinned backup WAN carries traffic: its URL test runs over that WAN.
  if [ -z "$M_WAN" ] && [ -n "$(override_dev)" ]; then wan_switchback
  elif [ -z "$M_NODE" ]; then node_switchback; fi
}

# Keep the house on the pin. A reboot drops the route and a pinned WAN that bounces takes it with
# it, so put the route back (once the WAN is up again; a down backup gets one ifup). A node changed
# by hand ends the node pin, the way it ends a switch-back.
LAST_ENFORCE=0
manual_enforce() {
  local n dev gw
  if [ -n "$M_NODE" ] && [ "$(cur_node)" != "$M_NODE" ]; then
    event "default node is now $(node_label "$(cur_node)"), set outside pw-failover; dropping the node pin"
    M_NODE=; save_manual
  fi
  [ -n "$M_WAN" ] && [ "$MODE" = act ] || return 0
  n=$(now)
  [ $((n - LAST_ENFORCE)) -ge "$WAN_SB_CHECK" ] || return 0
  LAST_ENFORCE=$n
  if [ "$M_WAN" = "$(primary_wan)" ]; then
    [ -n "$(override_dev)" ] || return 0
  else
    dev=$(wan_dev "$M_WAN"); gw=$(wan_gw "$M_WAN")
    [ -n "$gw" ] && [ "$(override_dev)" = "$dev" ] && [ "$(override_gw)" = "$gw" ] && return 0
    if ! wan_up_now "$M_WAN"; then
      [ -e "$RUN/pin-down" ] && return 0
      touch "$RUN/pin-down"
      event "pinned WAN $M_WAN is down; ifup, and traffic stays on $(active_wan) until it is up"
      grep -qx "$M_WAN" "$RUN/raised" 2>/dev/null || echo "$M_WAN" >> "$RUN/raised"
      nofd ifup "$M_WAN"
      return 0
    fi
  fi
  rm -f "$RUN/pin-down"
  event "egress is on $(active_wan), not the pinned $M_WAN; moving it back"
  if [ "$M_WAN" = "$(primary_wan)" ]; then ip -4 route flush proto "$ROUTE_PROTO"
  else ip -4 route replace default via "$gw" dev "$dev" metric 0 proto "$ROUTE_PROTO"; fi
  RESTARTS=0; PRE_XRAY=
  if [ "$RESTART_ON_WAN_CHANGE" = 1 ]; then pw_restart && verify restart; else verify; fi
  lower_unused
}

# Hand the house back to the watchdog without moving any traffic: a pinned backup WAN becomes an
# ordinary backup (switched back at the first check where the primary works), and a pinned node
# that is not the primary becomes an ordinary fallback node.
manual_release() {
  local node
  pinned || return 0
  node=$(cur_node)
  if [ -n "$M_WAN" ] && [ -n "$(override_dev)" ]; then
    load_wan; WAN_REASON=manual; WAN_SINCE=$(now); WAN_OK_SINCE=0; WAN_SB_K=0; save_wan
  fi
  if [ -n "$M_NODE" ] && [ "$node" != "$PRIMARY_NODE" ]; then
    load_state; FALLBACK_NODE=$node; FALLBACK_SINCE=$(now); SB_PASSES=0; NODE_SB_K=0; save_state
  fi
  rm -f "$MANUAL" "$RUN/pin-down"; load_manual
  tl "manual override ended ($1); automatic failover and switch-back resume"
}
manual_expire() {   # daemon, under the lock: the CLI may have changed or cleared it meanwhile
  local was
  load_manual
  pinned && [ "$M_UNTIL" -gt 0 ] && [ "$(now)" -ge "$M_UNTIL" ] || return 0
  was=$(manual_text)
  manual_release "expired at $(hms "$M_UNTIL")"
  note "📌 Manual override expired — pw-failover ($REPORT_NAME)" "${was#📌 }" \
    "Automatic failover and switch-back resume: egress $(active_wan), node $(node_label "$(cur_node)")."
}

# The first hop of the home node (its pre-proxy, if it rides one: node_dial_id) completes a TLS
# handshake over the primary WAN's own device. Cheap, and the only test that can look at wan while
# the override route sends url_test elsewhere. The handshake is the pass, not an HTTP reply: some
# endpoints (a WARP MASQUE one) finish TLS and then answer a plain GET with nothing.
primary_tls_ok() {
  local addr port sni tls id
  id=$(node_dial_id "$(home_node)")
  addr=$(ug "$id.address"); port=$(ug "$id.port")
  sni=$(ug "$id.tls_serverName"); [ -n "$sni" ] || sni=$addr
  echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 0
  tls=$(curl -s -k -m 8 -o /dev/null -w '%{time_appconnect}' --interface "$1" \
    --resolve "$sni:$port:$addr" "https://$sni:$port/cdn-cgi/trace" 2>/dev/null)
  case "$tls" in *[1-9]*) return 0 ;; *) return 1 ;; esac   # 0.000000 = no handshake
}

wan_switchback() {
  local n pw dev hold prev_dev prev_gw prev_node moved=0 rc
  n=$(now)
  [ $((n - LAST_WAN_SB)) -ge "$WAN_SB_CHECK" ] || return 0
  LAST_WAN_SB=$n
  load_wan
  pw=$(primary_wan); dev=$(wan_dev "$pw")
  if ! wan_is_up "$pw" || ! wan_reach "$dev"; then
    wanstat_set "$pw" "$dev" "$(wan_is_up "$pw" && echo 1 || echo 0)" "$(wan_gw "$pw")" down
    [ "$WAN_OK_SINCE" != 0 ] && { log "$pw: direct check lost again, hold restarts"; WAN_OK_SINCE=0; save_wan; }
    return 0
  fi
  wanstat_set "$pw" "$dev" 1 "$(wan_gw "$pw")" ok "$REACH_RTT" "$REACH_IP" "$REACH_HOW"
  [ "$WAN_OK_SINCE" = 0 ] && { WAN_OK_SINCE=$n; save_wan; event "$pw answers ping again"; }
  hold=$WAN_SB_HOLD_DOWN; [ "$WAN_REASON" = nodes ] && hold=$WAN_SB_HOLD_NODES
  # A failed switch-back doubles the hold; with a zero hold, start that doubling from 5 min so a
  # flapping WAN cannot cost a restart every check.
  [ "$WAN_SB_K" -gt 0 ] && [ "$hold" -lt 300 ] && hold=300
  hold=$(scaled "$hold" "$WAN_SB_K" "$SB_MAX_WAIT")
  [ $((n - WAN_OK_SINCE)) -ge "$hold" ] || return 0
  if ! primary_tls_ok "$dev"; then log "$pw pings but the primary node's TLS does not answer over it"; return 0; fi
  [ "$MODE" = act ] || { log "[observe] would switch egress back to $pw"; return 0; }
  prev_dev=$(override_dev); prev_gw=$(override_gw); prev_node=$(cur_node)
  event "switching egress back to $pw$([ $((n - WAN_OK_SINCE)) -gt 0 ] && echo " (pinging for $(dur $((n - WAN_OK_SINCE))))")"
  ip -4 route flush proto "$ROUTE_PROTO"
  # A fallback node was picked because it works over the backup; it may not work over the primary
  # (a node blocked on one ISP and not the other). The TLS check above just proved the primary node
  # reachable over this WAN, so go back to both at once: one restart, and one rollback if it fails.
  load_state
  if [ -n "$FALLBACK_NODE" ] && [ "$prev_node" = "$FALLBACK_NODE" ]; then
    apply_node "$(home_node)" && moved=1
  fi
  RESTARTS=0; PRE_XRAY=
  if [ "$RESTART_ON_WAN_CHANGE" = 1 ] || [ "$moved" = 1 ]; then pw_restart; verify restart; else verify; fi
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$RUN/wan"; lower_unused
    [ "$moved" = 1 ] && clear_state
    note "↩️ Back on WAN $pw — pw-failover ($REPORT_NAME)" \
      "It answers ping$([ $((n - WAN_OK_SINCE)) -gt 0 ] && echo " (for $(dur $((n - WAN_OK_SINCE))))") and $(node_label "$(home_node)") answers TLS over it; egress had been on $(wan_of_dev "$prev_dev") since $(hms "$WAN_SINCE") ($WAN_REASON)." \
      "Node $(node_label "$(cur_node)")$([ "$moved" = 1 ] && echo " (back from $(node_label "$prev_node"))"), exit IP ${EGRESS:-?}."
  else
    ip -4 route replace default via "$prev_gw" dev "$prev_dev" metric 0 proto "$ROUTE_PROTO"
    [ "$moved" = 1 ] && apply_node "$prev_node"
    RESTARTS=0
    if [ "$RESTART_ON_WAN_CHANGE" = 1 ] || [ "$moved" = 1 ]; then pw_restart && verify restart; fi
    WAN_SB_K=$((WAN_SB_K + 1)); WAN_OK_SINCE=0; save_wan
    # Log only, no Telegram: nothing changed for the house, and a filtered primary repeats it for hours.
    event "switch back to WAN $pw failed verification, rolled back: egress stays on $(wan_of_dev "$prev_dev") with node $(node_label "$(cur_node)"); next try after $(dur "$(scaled "$([ "$hold" -lt 300 ] && echo 300 || echo "$hold")" 1 "$SB_MAX_WAIT")") of $pw pinging"
  fi
}

node_switchback() {
  local n cur need rc fb since passes
  load_state
  [ -n "$FALLBACK_NODE" ] || return 0
  cur=$(cur_node)
  if [ "$cur" != "$FALLBACK_NODE" ]; then
    event "default node is now $(node_label "$cur"), set outside pw-failover; dropping the switch-back"
    clear_state; return 0
  fi
  n=$(now)
  [ $((n - LAST_NODE_SB)) -ge "$NODE_SB_INTERVAL" ] || return 0
  LAST_NODE_SB=$n
  url_test "$PRIMARY_NODE"; rc=$?
  case $rc in 0) SB_PASSES=$((SB_PASSES + 1)) ;; 1) SB_PASSES=0 ;; esac
  save_state
  need=$(scaled "$NODE_SB_PASSES" "$NODE_SB_K" $((SB_MAX_WAIT / NODE_SB_INTERVAL)))
  log "switch-back test $(node_label "$PRIMARY_NODE"): $UT ($SB_PASSES/$need)"
  [ "$SB_PASSES" -ge "$need" ] || return 0
  [ "$MODE" = act ] || return 0
  fb=$FALLBACK_NODE; since=$FALLBACK_SINCE; passes=$SB_PASSES
  event "switching back to $(node_label "$PRIMARY_NODE") after $SB_PASSES passing URL tests"
  RESTARTS=0
  if apply_node "$PRIMARY_NODE" && pw_restart && verify restart; then
    clear_state
    note "↩️ Back on node $(node_label "$PRIMARY_NODE") — pw-failover ($REPORT_NAME)" \
      "It passed $passes URL tests in a row; $(node_label "$fb") had carried the house since $(hms "$since")." \
      "Egress $(active_wan), exit IP ${EGRESS:-?}."
  else
    apply_node "$fb" && pw_restart && verify restart
    NODE_SB_K=$((NODE_SB_K + 1)); SB_PASSES=0; FALLBACK_NODE=$fb; FALLBACK_SINCE=$since; save_state
    event "switch back to $(node_label "$PRIMARY_NODE") failed verification, rolled back to $(node_label "$fb"); next try after $(scaled "$NODE_SB_PASSES" "$NODE_SB_K" 999) passes"
  fi
}

# --- daemon ---------------------------------------------------------------------------------------
# A pause stops the whole loop, in act and observe mode alike: no probes, URL tests, switch-backs,
# route repairs or reports. Only a manual override's expiry still runs.
pause_end() {   # prints when the pause ends (0 = until resumed); fails when not paused
  local e
  [ -r "$PAUSE" ] || return 1
  e=$(cat "$PAUSE")
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$e" = 0 ] || [ "$(now)" -lt "$e" ] || return 1
  echo "$e"
}
pause_text() { if [ "$1" = 0 ]; then echo "until resumed"; else echo "until $(date -d "@$1" '+%F %H:%M')"; fi; }

skip_reason() {
  local e
  if e=$(pause_end); then echo "paused $(pause_text "$e")"; return 0; fi
  [ -e "$PAUSE" ] && { rm -f "$PAUSE"; event "pause expired"; }
  [ "$(now)" -lt "$GRACE_UNTIL" ] && { echo "startup grace until $(hms "$GRACE_UNTIL")"; return 0; }
  [ "$(uci -q get passwall2.@global[0].enabled)" = 1 ] || { echo "passwall2 disabled"; return 0; }
  e=$(ug @global[0].node)
  [ -n "$e" ] || { echo "passwall2 has no global node"; return 0; }
  case "$(ug "$e.protocol")" in _shunt) ;; _*) echo "global node $e is not a node or shunt"; return 0 ;; esac
  /etc/init.d/mwan3 enabled 2>/dev/null && { echo "mwan3 is enabled (conflicts with passwall2)"; return 0; }
  e=$(locks_held) && { echo "$e is held"; return 0; }
  pgrep -f '[/]usr/share/passwall2/app.sh' >/dev/null && { echo "passwall2 app.sh running"; return 0; }
  [ "$(xray_age)" -lt "$XRAY_MIN_AGE" ] && { echo "xray just (re)started"; return 0; }
  return 1
}

# sleep in the background and wait: the TERM trap fires at once, and the orphaned sleep holds no lock
# `retest` sends USR1: the trap ends the nap at once instead of after the full interval. `reload`
# (LuCI's Save & Apply, through the init script) sends USR2: the nap ends and the settings are re-read.
NAP_PID=; RETEST=0
nap() { sleep "${1:-$PROBE_INTERVAL}" 8>&- 9>&- & NAP_PID=$!; wait "$NAP_PID"; NAP_PID=; }

status_write() {   # line-based, never sourced: the probe detail holds brackets and spaces
  printf '%s\n%s\n%s\n%s\n%s\n' "$(now)" "$1" "$FAILS" "$NEXT_INCIDENT_AT" "$2" > "$RUN/status"
  # the daemon's timers, for `status` and the LuCI page (numbers only, safe to source)
  printf 'D_GRACE_UNTIL=%s\nD_LAST_WAN_SB=%s\nD_LAST_NODE_SB=%s\nD_PROBE_INTERVAL=%s\n' \
    "$GRACE_UNTIL" "$LAST_WAN_SB" "$LAST_NODE_SB" "$PROBE_INTERVAL" > "$RUN/daemon.env"
}

run_daemon() {
  local r last_skip=
  exec 8>"$RUN/daemon.lock"
  flock -n 8 || { echo "pw-failover is already running" >&2; exit 1; }
  exec 9>"$RUN/lock"
  # Traps before the pid file: `retest` only signals a pid it can read, and an untrapped USR1 kills.
  trap 'event "stopped"; rm -f "$RUN/daemon.pid"; exit 0' TERM INT
  trap 'RETEST=1; [ -n "$NAP_PID" ] && kill "$NAP_PID" 2>/dev/null' USR1
  trap '[ -n "$NAP_PID" ] && kill "$NAP_PID" 2>/dev/null' USR2
  echo $$ > "$RUN/daemon.pid"
  DAEMON=1; load_conf
  [ -n "$PRIMARY_NODE" ] || { event "PRIMARY_NODE is not set ($CONF_SRC); not starting"; exit 1; }
  FAILS=0; GRACE_UNTIL=$(($(now) + GRACE)); LAST_NODE_SB=$(now)
  # Raised flags for interfaces that are down by now are stale (daemon restart, not reboot).
  for r in $(cat "$RUN/raised" 2>/dev/null); do wan_is_up "$r" || sed -i "/^$r\$/d" "$RUN/raised"; done
  event "started: mode $MODE, settings $CONF_SRC, egress $(active_wan), node $(node_label "$(cur_node)"), grace $(dur "$GRACE")"
  pinned && event "$(manual_text)"
  r=$(pause_end) && event "paused $(pause_text "$r")"
  while :; do
    load_conf
    if [ "$RETEST" = 1 ]; then
      # A manual retest (LuCI or `retest`): run every pending check now instead of on its timer.
      RETEST=0; GRACE_UNTIL=0; LAST_WAN_SB=0; LAST_NODE_SB=0; LAST_WANSTAT=0; WANSTAT_NOW=1; NEXT_INCIDENT_AT=0
      LAST_ENFORCE=0
      event "manual retest requested"
    fi
    if pinned && [ "$M_UNTIL" -gt 0 ] && [ "$(now)" -ge "$M_UNTIL" ]; then
      flock 9; manual_expire; flock -u 9
    fi
    if r=$(skip_reason); then
      [ "$r" = "$last_skip" ] || { log "skipping: $r"; last_skip=$r; }
      status_write skip "$r"
      nap; continue
    fi
    last_skip=
    if probe; then
      [ "$FAILS" -gt 0 ] && log "probe ok again after $FAILS failure(s)"
      FAILS=0; BACKOFF_IDX=0; NEXT_INCIDENT_AT=0
      flock 9
      [ -e "$RUN/outage" ] && outage_close
      maintain
      flock -u 9
      status_write ok "$PROBE_OUT"
    else
      FAILS=$((FAILS + 1))
      [ "$FAILS" -eq 1 ] && FIRST_FAIL_AT=$(now)
      [ "$FAILS" -le "$FAIL_THRESHOLD" ] && log "probe failed ($FAILS/$FAIL_THRESHOLD): $PROBE_OUT"
      if [ "$FAILS" -ge "$FAIL_THRESHOLD" ] && [ "$(now)" -ge "$NEXT_INCIDENT_AT" ] && rate_ok; then
        flock 9
        outage_open
        incident
        rm -f "$RUN/incident.running"
        flock -u 9
        FAILS=0
      fi
      status_write fail "$PROBE_OUT"
      # a failing probe already took ~11 s of timeouts: confirm quickly, not at the healthy pace
      [ "$FAILS" -gt 0 ] && [ "$FAILS" -lt "$FAIL_THRESHOLD" ] && { nap "$FAIL_INTERVAL"; continue; }
    fi
    nap
  done
}

# --- CLI --------------------------------------------------------------------------------------------
take_lock() {   # busybox flock has no -w: poll for up to 3 min
  local i=0
  exec 9>"$RUN/lock"
  until flock -n 9; do
    [ "$i" -lt 180 ] || { echo "busy: the daemon is mid-incident, try again" >&2; exit 1; }
    sleep 2; i=$((i + 2))
  done
}

cmd_status() {
  local AT=0 RESULT=? DETAIL= FAILS=0 NEXT_INCIDENT_AT=0 cur od w dev upd gw direct rtt ts pub how pe
  [ -r "$RUN/status" ] && { read -r AT; read -r RESULT; read -r FAILS; read -r NEXT_INCIDENT_AT; read -r DETAIL; } < "$RUN/status"
  load_state; load_wan
  cur=$(cur_node); od=$(override_dev)
  echo "mode:      $MODE"
  echo "settings:  $CONF_SRC${CONF_BAD:+ (ignored invalid: $CONF_BAD)}"
  echo "daemon:    $(pgrep -f '[p]w-failover.sh run' >/dev/null && echo running || echo STOPPED)"
  echo "probe:     $RESULT ($(hms "$AT")) $DETAIL"
  [ "$FAILS" -gt 0 ] && echo "failures:  $FAILS in a row"
  [ "$NEXT_INCIDENT_AT" -gt "$(now)" ] && echo "backoff:   next incident not before $(hms "$NEXT_INCIDENT_AT")"
  echo "egress:    $(active_wan) ($(route_dev))${od:+ — override via $(wan_of_dev "$od")}"
  [ -n "$od" ] && [ "$WAN_SINCE" != 0 ] && echo "backup:    since $(hms "$WAN_SINCE"), left $(primary_wan) because: $WAN_REASON"
  [ -s "$RUN/raised" ] && echo "raised:    $(tr '\n' ' ' < "$RUN/raised")"
  echo "WAN order: $(wan_walk_label)"
  [ -s "$RUN/wanstat" ] && while read -r w dev upd gw direct rtt ts pub how; do
    printf 'direct:    %-5s %-5s %s\n' "$w" "$dev" "$( [ "$upd" = 1 ] || { echo "interface down"; exit; }
      [ "$direct" = ok ] && echo "ok ${rtt} ms, ${how:-?}$([ "${pub:--}" != - ] && echo ", public IP $pub") ($(hms "$ts"))" \
        || echo "DOWN ($(hms "$ts"))")"
  done < "$RUN/wanstat"
  echo "node:      $(node_label "$cur") [$cur] $(node_addr "$cur")"
  [ "$cur" = "$PRIMARY_NODE" ] || echo "primary:   $(node_label "$PRIMARY_NODE") [$PRIMARY_NODE]"
  [ -n "$FALLBACK_NODE" ] && echo "fallback:  since $(hms "$FALLBACK_SINCE"), switch-back passes $SB_PASSES/$(scaled "$NODE_SB_PASSES" "$NODE_SB_K" 999)"
  pinned && echo "manual:    $(manual_text | sed 's/^📌 Manual override: //')"
  pe=$(pause_end) && echo "paused:    $(pause_text "$pe")"
  [ -r "$RUN/drill" ] && echo "drill:     $(cat "$RUN/drill")"
  [ -e "$RUN/outage" ] && echo "outage:    open since $(. "$RUN/outage"; hms "$O_START")"
  echo "reports:   $(ls "$REPORTS"/*.pending 2>/dev/null | wc -l) pending, $(ls "$REPORTS"/*.sent 2>/dev/null | wc -l) sent"
  echo "--- log"; tail -n "${1:-8}" "$LOG" 2>/dev/null
}

cmd_test_nodes() {   # dry run: URL-test the whole chain, change nothing. $1 = --tsv for the page
  local id first= rc pick tab M_NODE=   # the whole chain even under a node pin
  tab=$(printf '\t')
  take_lock
  for id in $(node_chain); do
    url_test "$id"; rc=$?
    pick=0; [ "$rc" -eq 0 ] && [ -z "$first" ] && first=$id && pick=1
    if [ "${1:-}" = --tsv ]; then
      echo "$id$tab$(node_label "$id")$tab$(node_addr "$id")$tab$UT$tab$pick$tab$rc$tab$(node_tier "$id")"
    else
      [ "$pick" = 1 ] && UT="$UT  <- would pick"
      printf '%-10s %-40s %-24s %s\n' "$id" "$(node_label "$id")" "$(node_addr "$id")" "$UT"
    fi
  done
  [ -n "$first" ] || [ "${1:-}" = --tsv ] || echo "no node passes over the current egress ($(active_wan))"
}

node_tier() {   # where a node sits in the chain, for the status page
  if [ "$1" = "$PRIMARY_NODE" ]; then echo primary
  elif [ -n "$TIER1_GROUP" ] && [ "$(ug "$1.group")" = "$TIER1_GROUP" ] \
    && port_in "$(ug "$1.port")" "$TIER1_PORT"; then echo "tier 1"
  elif [ -n "$TIER2_GROUP" ] && [ "$(ug "$1.group")" = "$TIER2_GROUP" ] \
    && port_in "$(ug "$1.port")" "$TIER2_PORT"; then echo "tier 2"
  else echo "tier 3"; fi
}
daemon_running() { [ -s "$RUN/daemon.pid" ] && kill -0 "$(cat "$RUN/daemon.pid")" 2>/dev/null; }
bg_running() { [ -s "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }
# Long jobs for the LuCI page, which cannot wait past its RPC timeout: detach, write a pid file,
# and let the page poll `json` for the result.
run_bg() {   # $1 = job name, rest = this script's verb and args
  local job=$1; shift
  bg_running "$job" && { echo "$job already running"; return 0; }
  # The ( … & ) subshell is load-bearing: under rpcd's file exec (the LuCI buttons) a plain `cmd &`
  # keeps the call open until rpcd's timeout, even with every fd redirected; the double fork returns
  # at once (measured 2026-10-12: 30 s timeout vs 0 s).
  ( setsid sh -c 'echo $$ > "$1/$2.pid"; shift 2; "$@"; rm -f "$0"' "$RUN/$job.pid" "$RUN" "$job" "$@" \
    </dev/null >"$RUN/$job.out" 2>&1 & )
  echo "$job started"
}

cmd_json() {   # everything the LuCI page shows, in one call
  local AT=0 RESULT=unknown DETAIL= FAILS=0 NEXT=0 D_GRACE_UNTIL=0 D_LAST_WAN_SB=0 D_LAST_NODE_SB=0
  local D_PROBE_INTERVAL=0 O_START=0 O_NODE= O_WAN= cur od pw n w line up f old tab
  local id label addr res pick rc tier pos=0 aw pe
  set +u   # jshn reads unset variables by design
  . /usr/share/libubox/jshn.sh
  [ -r "$RUN/status" ] && { read -r AT; read -r RESULT; read -r FAILS; read -r NEXT; read -r DETAIL; } < "$RUN/status"
  [ -r "$RUN/daemon.env" ] && . "$RUN/daemon.env"
  load_state; load_wan
  cur=$(cur_node); od=$(override_dev); pw=$(primary_wan); n=$(now); tab=$(printf '\t'); aw=$(active_wan)
  json_init
  json_add_int now "$n"
  json_add_string name "$REPORT_NAME"
  json_add_string mode "$MODE"
  json_add_string settings "$CONF_SRC"
  json_add_string settings_invalid "$CONF_BAD"
  json_add_boolean daemon "$(daemon_running && echo 1 || echo 0)"
  pe=$(pause_end) || pe=
  json_add_boolean paused "$([ -n "$pe" ] && echo 1 || echo 0)"
  json_add_int paused_until "${pe:-0}"   # 0 while paused = until resumed
  json_add_int grace_until "${D_GRACE_UNTIL:-0}"
  json_add_string drill "$(cat "$RUN/drill" 2>/dev/null)"
  json_add_boolean incident_running "$([ -e "$RUN/incident.running" ] && echo 1 || echo 0)"
  json_add_string busy "$(bg_running revert && echo revert)$(bg_running nodetest && echo nodetest)$(bg_running manual && echo manual)"
  json_add_int next_incident_at "${NEXT:-0}"

  json_add_object probe
  json_add_string result "$RESULT"; json_add_int at "${AT:-0}"; json_add_string detail "$DETAIL"
  json_add_int fails "${FAILS:-0}"; json_add_int threshold "$FAIL_THRESHOLD"; json_add_int interval "$PROBE_INTERVAL"
  json_add_string ip "$(echo "$DETAIL" | sed -n 's/.*ip=\([^ ]*\).*/\1/p')"
  json_add_string loc "$(echo "$DETAIL" | sed -n 's/.*loc=\([^ ]*\).*/\1/p')"
  json_close_object

  json_add_object egress
  json_add_string wan "$aw"; json_add_string dev "$(route_dev)"; json_add_string primary "$pw"
  json_add_boolean override "$([ -n "$od" ] && echo 1 || echo 0)"
  json_add_int since "${WAN_SINCE:-0}"; json_add_string reason "$WAN_REASON"
  json_add_int ok_since "${WAN_OK_SINCE:-0}"; json_add_int sb_k "${WAN_SB_K:-0}"
  json_add_int next_check "$([ -n "$od" ] && echo $((D_LAST_WAN_SB + WAN_SB_CHECK)) || echo 0)"
  json_add_string order "$(wan_walk)"
  json_close_object

  json_add_object manual
  json_add_boolean active "$(pinned && echo 1 || echo 0)"
  json_add_string wan "$M_WAN"; json_add_string node "$M_NODE"
  json_add_string node_label "$([ -n "$M_NODE" ] && node_label "$M_NODE")"
  json_add_int since "${M_SINCE:-0}"; json_add_int until "${M_UNTIL:-0}"; json_add_boolean hold "${M_HOLD:-0}"
  json_add_string result "$(tail -n 1 "$RUN/manual.out" 2>/dev/null)"
  json_add_int result_at "$([ -e "$RUN/manual.out" ] && date -r "$RUN/manual.out" +%s || echo 0)"
  json_close_object

  json_add_array wans   # every WAN, also under a WAN pin
  for w in $(wan_walk_all); do
    pos=$((pos + 1))
    line=$(grep "^$w " "$RUN/wanstat" 2>/dev/null); set -- $line
    json_add_object
    json_add_string name "$w"; json_add_int pos "$pos"; json_add_string dev "$(wan_dev "$w")"
    up=0; wan_up_now "$w" && up=1
    json_add_boolean up "$up"; json_add_string gw "$(wan_gw "$w")"
    json_add_boolean primary "$([ "$w" = "$pw" ] && echo 1 || echo 0)"
    json_add_boolean active "$([ "$w" = "$aw" ] && echo 1 || echo 0)"
    json_add_boolean raised "$(grep -qx "$w" "$RUN/raised" 2>/dev/null && echo 1 || echo 0)"
    json_add_boolean last_resort "$([ "$w" != "$pw" ] && [ "$up" = 0 ] && echo 1 || echo 0)"
    json_add_boolean pinned "$([ "$w" = "$M_WAN" ] && echo 1 || echo 0)"
    json_add_string direct "${5:-}"; json_add_string rtt "$([ "${6:-}" != - ] && echo "${6:-}")"
    json_add_int checked "${7:-0}"
    json_add_string public_ip "$([ "${8:-}" != - ] && echo "${8:-}")"; json_add_string how "$([ "${9:-}" != - ] && echo "${9:-}")"
    json_close_object
  done
  json_close_array

  json_add_object node
  json_add_string id "$cur"; json_add_string label "$(node_label "$cur")"; json_add_string addr "$(node_addr "$cur")"
  json_add_string primary_id "$PRIMARY_NODE"; json_add_string primary_label "$(node_label "$PRIMARY_NODE")"
  json_add_string primary_addr "$(node_addr "$PRIMARY_NODE")"; json_add_string slot "$(node_slot)"
  json_add_boolean fallback "$([ -n "$FALLBACK_NODE" ] && echo 1 || echo 0)"
  json_add_int fallback_since "${FALLBACK_SINCE:-0}"; json_add_int sb_passes "${SB_PASSES:-0}"
  json_add_int sb_need "$(scaled "$NODE_SB_PASSES" "${NODE_SB_K:-0}" 999)"
  json_add_int next_test "$([ -n "$FALLBACK_NODE" ] && [ -z "$od" ] && echo $((D_LAST_NODE_SB + NODE_SB_INTERVAL)) || echo 0)"
  json_close_object

  json_add_object outage
  if [ -r "$RUN/outage" ]; then . "$RUN/outage"; json_add_boolean open 1; else json_add_boolean open 0; fi
  json_add_int since "${O_START:-0}"
  json_add_string cause "$(cause_text "${O_NODE:-$cur}")"
  json_add_string wancheck "$([ -s "$RUN/wancheck" ] && wancheck_text)"
  json_add_string timeline "$(cat "$RUN/timeline" 2>/dev/null)"
  json_add_string urltests "$(cat "$RUN/urltests" 2>/dev/null)"
  json_close_object

  json_add_object nodetest
  json_add_boolean running "$(bg_running nodetest && echo 1 || echo 0)"
  json_add_int at "$([ -e "$RUN/nodetest.tsv" ] && date -r "$RUN/nodetest.tsv" +%s || echo 0)"
  json_add_array rows
  if [ -r "$RUN/nodetest.tsv" ]; then
    while IFS="$tab" read -r id label addr res pick rc tier; do
      [ -n "$id" ] || continue
      json_add_object
      json_add_string id "$id"; json_add_string label "$label"; json_add_string addr "$addr"
      json_add_string result "$res"; json_add_boolean pick "${pick:-0}"; json_add_string tier "$tier"
      json_add_boolean pass "$([ "$rc" = 0 ] && echo 1 || echo 0)"
      json_close_object
    done < "$RUN/nodetest.tsv"
  fi
  json_close_array
  json_close_object

  json_add_array reports   # newest first: what the Telegram chat got (or will get, if pending)
  for f in $(ls -1t "$REPORTS"/*.sent "$REPORTS"/*.pending 2>/dev/null | head -n 6); do
    json_add_object
    json_add_int at "$(date -r "$f" +%s)"; json_add_string text "$(cat "$f")"
    json_add_boolean pending "$(case "$f" in *.pending) echo 1 ;; *) echo 0 ;; esac)"
    json_close_object
  done
  json_close_array

  json_add_string log "$(tail -n 40 "$LOG" 2>/dev/null)"
  json_dump
}

cmd_revert() {   # back to the primary WAN and node right now; ends a manual override
  local changed=0
  MODE=act; take_lock
  pinned && { rm -f "$MANUAL" "$RUN/pin-down"; load_manual; event "manual override ended by revert"; echo "manual override ended"; }
  [ -n "$(override_dev)" ] && { ip -4 route flush proto "$ROUTE_PROTO"; changed=1; echo "override route removed"; }
  rm -f "$RUN/wan"
  for r in $(cat "$RUN/raised" 2>/dev/null); do wan_lower "$r"; done
  [ "$(cur_node)" != "$PRIMARY_NODE" ] && { apply_node "$PRIMARY_NODE"; changed=1; echo "node → $(node_label "$PRIMARY_NODE")"; }
  clear_state
  if [ "$changed" = 1 ]; then RESTARTS=0; pw_restart; verify restart && echo "tunnel ok, exit IP ${EGRESS:-?}" || echo "tunnel NOT ok yet"; else echo "already on primary WAN and node"; fi
}

# manual <wan|-> <node|-> [minutes] [hold]: pin the egress WAN, the node, or both ("-" = automatic),
# for <minutes> (0 = until cleared). hold=1 keeps the pin even when nothing works inside it.
manual_args() {   # prints why the arguments are wrong
  local w=$1 id=$2 min=$3 hold=$4
  [ "$w" = - ] && [ "$id" = - ] && { echo "pin a WAN, a node or both (- means automatic)"; return 1; }
  if [ "$w" != - ]; then
    case " $WAN_ORDER " in *" $w "*) ;; *) echo "$w is not a WAN in WAN_ORDER ($WAN_ORDER)"; return 1 ;; esac
  fi
  if [ "$id" != - ]; then
    case "$id" in *[!A-Za-z0-9_]*) echo "bad node id: $id"; return 1 ;; esac
    node_allowed "$id" || { echo "$id is not a node pw-failover may use (missing, on a deny list or a pseudo-node)"; return 1; }
  fi
  case "$min" in ''|*[!0-9]*) echo "minutes must be a whole number, 0 = until cleared"; return 1 ;; esac
  case "$hold" in 0|1) ;; *) echo "hold must be 0 or 1"; return 1 ;; esac
}
cmd_manual() {
  local w=${1:--} id=${2:--} min=${3:-0} hold=${4:-0} err changed=0 dev gw
  err=$(manual_args "$w" "$id" "$min" "$hold") || { echo "manual: $err" >&2; return 2; }
  [ "$w" = - ] && w=; [ "$id" = - ] && id=
  MODE=act; take_lock
  # A down backup is raised first; without a lease nothing changes, an earlier pin included. The
  # primary belongs to netifd and is never raised, so it can be pinned only while it is up.
  if [ -n "$w" ] && [ "$w" = "$(primary_wan)" ]; then
    wan_up_now "$w" || { echo "manual: $w is down; nothing changed" >&2; return 1; }
  elif [ -n "$w" ]; then
    wan_raise "$w" || { echo "manual: $w is down and got no lease in ${WAN_UP_WAIT}s; nothing changed" >&2; return 1; }
  fi
  M_WAN=$w; M_NODE=$id; M_SINCE=$(now); M_HOLD=$hold; M_UNTIL=0
  [ "$min" -gt 0 ] && M_UNTIL=$((M_SINCE + min * 60))
  save_manual; rm -f "$RUN/pin-down"
  tl "manual override set: $(manual_text | sed 's/^📌 Manual override: //')"
  if [ -n "$w" ]; then
    rm -f "$RUN/wan"   # a pinned WAN has no switch-back
    if [ "$w" = "$(primary_wan)" ]; then
      [ -n "$(override_dev)" ] && { ip -4 route flush proto "$ROUTE_PROTO"; changed=1; }
    else
      dev=$(wan_dev "$w"); gw=$(wan_gw "$w")
      if [ "$(override_dev)" != "$dev" ] || [ "$(override_gw)" != "$gw" ]; then
        ip -4 route replace default via "$gw" dev "$dev" metric 0 proto "$ROUTE_PROTO"; changed=1
      fi
    fi
    [ "$changed" = 1 ] && tl "egress route → $w (manual)"
  fi
  if [ -n "$id" ]; then
    clear_state   # the pinned node is no fallback, and nothing switches it back
    [ "$(cur_node)" = "$id" ] || { apply_node "$id" && changed=1; }
  fi
  lower_unused
  [ "$changed" = 1 ] && [ -e "$RUN/outage" ] && touch "$RUN/outage.acted"
  if [ "$changed" = 1 ]; then
    RESTARTS=0; pw_restart
    if verify restart; then echo "pinned; tunnel ok, exit IP ${EGRESS:-?}"; else echo "pinned; tunnel NOT ok yet ($PROBE_OUT)"; fi
  else
    echo "pinned; traffic was already there, nothing restarted"
  fi
}
cmd_manual_clear() {
  MODE=act; take_lock
  pinned || { echo "no manual override"; return 0; }
  manual_release "cleared by hand"
  echo "manual override cleared; egress $(active_wan), node $(node_label "$(cur_node)")"
}

mkdir -p "$RUN" "$REPORTS"
case "${1:-}" in
  run) run_daemon ;;
  status) load_conf; cmd_status "${2:-8}" ;;
  node-id) cur_node ;;
  test-nodes) load_conf; cmd_test_nodes "${2:-}" ;;
  test-nodes-bg)
    load_conf; run_bg nodetest sh -c "\"\$0\" test-nodes --tsv > '$RUN/nodetest.tmp' && mv '$RUN/nodetest.tmp' '$RUN/nodetest.tsv'" "$0" ;;
  revert) load_conf; cmd_revert ;;
  revert-bg) load_conf; run_bg revert "$0" revert ;;
  manual) load_conf; shift; cmd_manual "$@" ;;
  manual-bg)   # check the arguments here, so the page sees a refusal; the move itself runs detached
    load_conf; shift
    err=$(manual_args "${1:--}" "${2:--}" "${3:-0}" "${4:-0}") || { echo "manual: $err" >&2; exit 2; }
    bg_running manual && { echo "a manual override change is already running" >&2; exit 1; }
    run_bg manual "$0" manual "${1:--}" "${2:--}" "${3:-0}" "${4:-0}" ;;
  manual-clear) load_conf; cmd_manual_clear ;;
  manual-clear-bg)
    load_conf; bg_running manual && { echo "a manual override change is already running" >&2; exit 1; }
    run_bg manual "$0" manual-clear ;;
  json) load_conf; cmd_json ;;
  retest)
    daemon_running || { echo "the pw-failover daemon is not running" >&2; exit 1; }
    kill -USR1 "$(cat "$RUN/daemon.pid")" && echo "retest requested" ;;
  reload)   # re-read the settings now; a stopped daemon reads them when it starts
    daemon_running && kill -USR2 "$(cat "$RUN/daemon.pid")"; exit 0 ;;
  conf) load_conf; cmd_conf "${2:-}" ;;
  defaults) cmd_conf --json ;;
  conf-to-uci) cmd_conf_to_uci ;;
  pause)   # pause [minutes], default 30; 0 = until resumed. The daemon is woken to see it at once.
    min=${2:-30}
    case "$min" in ''|*[!0-9]*) echo "pause: minutes must be a whole number, 0 = until resumed" >&2; exit 2 ;; esac
    if [ "$min" = 0 ]; then e=0; else e=$(($(now) + min * 60)); fi
    echo "$e" > "$PAUSE"; load_conf
    event "paused $(pause_text "$e")$([ "$min" = 0 ] || echo " ($(dur $((min * 60))))")"
    daemon_running && kill -USR2 "$(cat "$RUN/daemon.pid")"; exit 0 ;;
  resume)
    rm -f "$PAUSE"; load_conf; event "resumed"
    daemon_running && kill -USR2 "$(cat "$RUN/daemon.pid")"; exit 0 ;;
  test-telegram)
    load_conf
    printf '🧪 pw-failover test message from %s (mode %s, egress %s, node %s)\n' \
      "$REPORT_NAME" "$MODE" "$(active_wan)" "$(node_label "$(cur_node)")" > "$RUN/test.txt"
    tg_send "$RUN/test.txt" && echo sent || { echo "send FAILED"; tail -n 3 "$LOG"; exit 1; }
    ;;
  *) echo "usage: $0 run | status [lines] | json | node-id | retest | reload | test-nodes [--tsv] |" \
       "test-nodes-bg | revert | revert-bg | pause [minutes] | resume | test-telegram |" \
       "manual <wan|-> <node|-> [minutes] [hold] | manual-bg … | manual-clear | manual-clear-bg |" \
       "conf [--json] | defaults | conf-to-uci" >&2; exit 2 ;;
esac
