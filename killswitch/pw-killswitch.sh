#!/bin/sh
# pw-killswitch.sh — passwall2 killswitch for an OpenWrt router.
# Installed as /root/scripts/pw-killswitch.sh and run by /etc/init.d/pw-killswitch. Settings are
# uci /etc/config/pw-killswitch, edited on LuCI's Network ▸ Killswitch. Write-up: README.md next to this script.
#
# While passwall2 and its proxy are up, nothing changes. The moment passwall2 stops or restarts,
# or its proxy stops listening, TCP and UDP from the LAN and from the router itself may leave only
# for destinations in the active shunt's direct lists (the shunt rules set to `_direct`).
# Everything else is refused, and LAN DNS is answered only for names in those lists.
#
# How the gate learns passwall2's state without a gap:
#   A heartbeat rule at the top of passwall2's own decision chains (PSW2_NAT and PSW2_OUTPUT_NAT
#   for TCP, PSW2_MANGLE and PSW2_OUTPUT_MANGLE for UDP) sets mark bit HB on every packet that
#   passwall2 lets through to be routed direct. Our forward and output chains admit a connection
#   whose packet carries the bit, and police every other one against the direct lists. passwall2's
#   stop deletes the jumps into those chains first and the chains after, so the heartbeat dies at
#   the same instant as the redirects it stands for: a stop or restart never leaves a moment where
#   traffic is neither proxied nor policed. The daemon only ever puts the heartbeat back, once
#   passwall2 is healthy again, and takes it away when the proxy stops listening while passwall2's
#   rules stay loaded.
#
#   The router's own traffic always gets through to xray's own sockets (mark 255: passwall2 must
#   reach its nodes to come back), to port 53 (passwall2 resolves node names while it starts) and
#   over loopback, which is where passwall2 redirects the router's proxied traffic. Its TCP resets
#   pass too: the kernel sends one without mark 255 when a late packet finds xray's socket gone.
#
#   A proxied TCP connection is DNATed to the router and stays local after xray dies; it gets an
#   RST. A tproxied UDP flow does not: once the tproxy rule is gone, its packets are forwarded as
#   an established flow. That is why admission is remembered per connection (ct label) and every
#   packet of a connection that was not admitted is policed, not only `ct state new`.
#
#   ⚠ The heartbeat must never touch a packet passwall2 has tproxy-marked: its policy route is an
#   exact match on fwmark 0x50535732, and one extra bit sends the packet out instead of to xray.
#   PSW2_RULE overwrites the whole mark of every packet it tproxies, so marking at the top of
#   PSW2_MANGLE is safe for LAN packets. Loopback packets arrive already marked, hence `iif != lo`.
#   In the output chains xray's own packets (mark 255) are left alone: our output chain lets them
#   through anyway, and PSW2_OUTPUT_MANGLE is a route chain, where a changed mark means a re-route.
#   Port 53 is left unmarked: passwall2 accepts DNS there and redirects it in dstnat, so a marked
#   DNS packet in the forward path means passwall2 is halfway through its teardown.
#
# Verbs: run | ensure | load | print | compile [--force] | compile-bg | teardown |
#        test <seconds> | test-stop | json | status | refused [n]
set -u

VERSION=1                    # bump when compile output changes shape; part of the fingerprint
CONF=pw-killswitch
SELF=/root/scripts/pw-killswitch.sh
INIT=/etc/init.d/pw-killswitch
LIB=/etc/pw-killswitch       # compiled lists, kept on disk so the gate has them at boot
RUN=/var/run/pw-killswitch   # daemon state, events, test flag (tmpfs)
T=pwks                       # our table: inet pwks
PT=passwall2                 # passwall2's table: inet passwall2
HB=0x20000000                # heartbeat mark bit; 0x50535732 (passwall2's tproxy mark) lacks it
HB_CLEAR=0xdfffffff
LABEL=100                    # ct label bit of an admitted connection
TAG=pw-killswitch
HB_CHAINS="PSW2_NAT PSW2_MANGLE PSW2_MANGLE_V6 PSW2_OUTPUT_NAT PSW2_OUTPUT_MANGLE PSW2_OUTPUT_MANGLE_V6"
DIRECT_GID=9912              # passwall2's own direct group (utils.sh), never redirected by it
PW2_FWMARK=0x50535732        # passwall2's tproxy mark (FWMARK in nftables.sh)
DNS_PORT=6053
DYN_TIMEOUT=1d               # how long an IP learned from a direct name stays allowed
GEOVIEW=/usr/bin/geoview
RESOLV=/tmp/resolv.conf.d/resolv.conf.auto
REFUSED_GAP=600              # a flow refused again within this many seconds extends its row in the log
REFUSED_KEEP=100             # log rows kept per state, so an outage cannot push out what was refused while armed
REFUSED_AGE=604800           # and none older than 7 days

log() { logger -t "$TAG" "$*"; }
die() { echo "$TAG: $*" >&2; exit 1; }

event() {  # event <message>: one line for the LuCI page's event list, and syslog
	mkdir -p "$RUN"
	echo "$(date +%s) $*" >> "$RUN/events"
	if [ "$(wc -l < "$RUN/events")" -gt 80 ]; then
		tail -n 50 "$RUN/events" > "$RUN/events.tmp" && mv -f "$RUN/events.tmp" "$RUN/events"
	fi
	log "$*"
}

enabled() { [ "$(uci -q get "$CONF.main.enabled")" = 1 ]; }
logging() { [ "$(uci -q get "$CONF.main.log_refused")" != 0 ]; }   # the log of refused connections; on unless 0

geo_paths() {
	local d
	d=$(uci -q get passwall2.@global_rules[0].v2ray_location_asset)
	d=${d:-/usr/share/v2ray/}
	GEOIP=${d%/}/geoip.dat
	GEOSITE=${d%/}/geosite.dat
}

shunt_rules() {  # shunt rule sections in file order, which is passwall2's first-match order
	uci -q show passwall2 | sed -n 's/^passwall2\.\([A-Za-z0-9_]*\)=shunt_rules$/\1/p'
}

# --- passwall2's state -----------------------------------------------------------------------

# Read passwall2's table (terse, with handles) into shell variables:
#   PW2_TABLE NAT_JUMP MANGLE_JUMP TCP_PORT UDP_PORT HB_PRESENT HB_<chain> WHITE_SETS
pw2_facts() {
	PW2_TABLE=0 NAT_JUMP=0 MANGLE_JUMP=0 TCP_PORT= UDP_PORT= HB_PRESENT= WHITE_SETS=
	local c
	for c in $HB_CHAINS; do eval "HB_$c="; done
	eval "$(nft -t -a list table inet $PT 2>/dev/null | awk -v hbc="$HB_CHAINS" -v tag="$TAG" '
		BEGIN { n = split(hbc, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
		{ seen = 1 }
		/^\tset / { if ($2 ~ /^psw2_[A-Za-z0-9_]+_white6?$/) white = white " " $2; next }
		/^\tchain / { cur = $2; if (cur in want) present = present " " cur; next }
		/^\t}/ { cur = ""; next }
		cur == "dstnat" && /jump PSW2_NAT( |$)/ { nat = 1 }
		cur == "mangle_prerouting" && /jump PSW2_MANGLE( |$)/ { mangle = 1 }
		cur == "PSW2_NAT" && tcp == "" && match($0, /redirect to :[0-9]+/) { tcp = substr($0, RSTART + 13, RLENGTH - 13) }
		cur == "PSW2_MANGLE" && udp == "" && match($0, /tproxy (ip )?to :[0-9]+/) {
			x = substr($0, RSTART, RLENGTH); sub(/.*:/, "", x); udp = x }
		(cur in want) && index($0, "comment \"" tag "\"") && match($0, /# handle [0-9]+$/) {
			hb[cur] = hb[cur] " " substr($0, RSTART + 9) }
		END {
			if (!seen) exit
			print "PW2_TABLE=1"
			print "NAT_JUMP=" (nat + 0); print "MANGLE_JUMP=" (mangle + 0)
			print "TCP_PORT=" tcp; print "UDP_PORT=" udp
			print "HB_PRESENT=\"" present "\""; print "WHITE_SETS=\"" white "\""
			for (c in hb) print "HB_" c "=\"" hb[c] "\""
		}')"
}

listening() {  # listening <tcp|udp> <port>
	local f=u
	[ "$1" = tcp ] && f=t
	netstat -ln$f 2>/dev/null | awk -v p=":$2" '{ if (substr($4, length($4) - length(p) + 1) == p) f = 1 } END { exit !f }'
}

# Is passwall2 healthy? Sets OK (1/0) and WHY (empty when OK), and the pw2_facts variables.
pw2_check() {
	OK=0 WHY= STARTING=0 TCP_LISTEN=0 UDP_LISTEN=0
	pw2_facts
	# only a start or stop: URL tests and LuCI's passwall2 pages also run app.sh (`run_socks`)
	pgrep -f '/usr/share/passwall2/app\.sh st[ao][rp]' >/dev/null 2>&1 && STARTING=1
	[ -n "$TCP_PORT" ] && listening tcp "$TCP_PORT" && TCP_LISTEN=1
	[ -n "$UDP_PORT" ] && listening udp "$UDP_PORT" && UDP_LISTEN=1
	if [ "$(uci -q get passwall2.@global[0].enabled)" != 1 ]; then WHY="passwall2 is disabled"
	elif [ "$PW2_TABLE" != 1 ] || [ "$NAT_JUMP" != 1 ]; then WHY="passwall2's rules are not loaded"
	elif [ "$STARTING" = 1 ]; then WHY="passwall2 is starting or stopping"
	elif [ -z "$TCP_PORT" ]; then WHY="passwall2 redirects no TCP"
	elif [ "$TCP_LISTEN" != 1 ]; then WHY="the proxy is not listening on TCP :$TCP_PORT"
	elif [ "$MANGLE_JUMP" = 1 ] && [ -n "$UDP_PORT" ] && [ "$UDP_LISTEN" != 1 ]; then
		WHY="the proxy is not listening on UDP :$UDP_PORT"
	else OK=1
	fi
}

hb_complete() {  # every passwall2 decision chain that exists carries the heartbeat
	local c h
	[ -n "$HB_PRESENT" ] || return 1
	for c in $HB_PRESENT; do eval "h=\${HB_$c:-}"; [ -n "$h" ] || return 1; done
	return 0
}

hb_any() {
	local c h
	for c in $HB_CHAINS; do eval "h=\${HB_$c:-}"; [ -n "$h" ] && return 0; done
	return 1
}

arm() {  # put the heartbeat at the top of each decision chain that lacks it, in one transaction
	local c h f="$RUN/arm.nft"
	: > "$f"
	for c in $HB_PRESENT; do
		eval "h=\${HB_$c:-}"
		[ -n "$h" ] && continue
		case $c in
			PSW2_OUTPUT_*) m='meta mark & 0xff != 0xff' ;;   # the router's own packets, not xray's
			*) m='iif != "lo"' ;;                             # LAN packets, not loopback re-entries
		esac
		printf 'insert rule inet %s %s %s th dport != 53 meta mark set meta mark | %s comment "%s"\n' \
			"$PT" "$c" "$m" "$HB" "$TAG" >> "$f"
	done
	[ -s "$f" ] && nft -f "$f"
}

disarm() {  # take every heartbeat out of passwall2's chains
	local c h x f="$RUN/disarm.nft"
	mkdir -p "$RUN"
	: > "$f"
	for c in $HB_CHAINS; do
		eval "h=\${HB_$c:-}"
		for x in $h; do echo "delete rule inet $PT $c handle $x" >> "$f"; done
	done
	[ -s "$f" ] && nft -f "$f"
}

dns_redirected() { nft list chain inet $T dns 2>/dev/null | grep -q redirect; }

dns_rules() {  # the redirect of LAN DNS to our resolver, used while engaged; one rule per line
	echo "ip saddr @lan4 meta l4proto { tcp, udp } th dport 53 counter name dns redirect to :$DNS_PORT"
	echo "ip6 saddr @lan6 meta l4proto { tcp, udp } th dport 53 counter name dns redirect to :$DNS_PORT"
}

dns_set() {  # dns_set on|off
	local l
	if [ "$1" = on ]; then
		{ echo "flush chain inet $T dns"; dns_rules | while read -r l; do echo "add rule inet $T dns $l"; done; } | nft -f -
	else
		nft flush chain inet $T dns
	fi
}

# --- the log of refused connections ----------------------------------------------------------
#
# While log_refused is on, chain record notes each refused packet in refused4/refused6, keyed by
# source, destination, protocol and port, with a packet counter per key. Only refused packets get
# there, so traffic that is let through pays nothing. Each second the daemon moves what is there
# into $RUN/refused (tmpfs), one row per flow, oldest first by last seen:
#   <first seen> <last seen> <packets> <armed|engaged> <source> <destination> <proto> <port>
# A flow refused again within REFUSED_GAP seconds extends its row. At most REFUSED_KEEP rows per
# state and REFUSED_AGE seconds are kept, about 20 KB.

log_rules() {  # what chain record holds while the log is on; one rule per line
	echo "update @refused4 { ip saddr . ip daddr . meta l4proto . th dport }"
	echo "update @refused6 { ip6 saddr . ip6 daddr . meta l4proto . th dport }"
}

log_set() {  # log_set on|off; off also forgets what was logged
	local l
	if [ "$1" = on ]; then
		{ echo "flush chain inet $T record"; log_rules | while read -r l; do echo "add rule inet $T record $l"; done; } | nft -f -
	else
		printf 'flush chain inet %s record\nflush set inet %s refused4\nflush set inet %s refused6\n' $T $T $T | nft -f - 2>/dev/null
		rm -f "$RUN/refused"
	fi
}

log_fold() {  # log_fold <armed|engaged>: move what chain record noted since the last call into $RUN/refused
	local s e now
	now=$(date +%s)
	: > "$RUN/refused.in"
	for s in refused4 refused6; do
		e=$(nft list set inet $T $s 2>/dev/null | tr -d '\n\t' | sed -n 's/.*elements = { \(.*\) }.*/\1/p')
		[ -n "$e" ] || continue
		# "<src> . <dst> . <proto> . <port> counter packets <n> bytes <n> expires <t>", comma-separated
		echo "$e" | sed 's/, /\n/g' | awk '{ for (i = 8; i < NF; i++) if ($i == "packets") print $1, $3, $5, $7, $(i + 1) }' >> "$RUN/refused.in"
		nft destroy element inet $T $s "{ $(echo "$e" | sed 's/ counter packets [0-9]* bytes [0-9]*//g; s/ expires [0-9a-z]*//g') }" 2>/dev/null
	done
	[ -s "$RUN/refused.in" ] || return 0
	touch "$RUN/refused"
	awk -v now="$now" -v st="$1" -v gap=$REFUSED_GAP -v old="$RUN/refused" '
		FILENAME == old { n++; f[n] = $1; l[n] = $2; p[n] = $3; k[n] = $4 " " $5 " " $6 " " $7 " " $8; last[k[n]] = n; next }
		{
			key = st " " $1 " " $2 " " $3 " " $4; i = last[key]
			if (i && now - l[i] <= gap) { l[i] = now; p[i] += $5 }
			else { n++; f[n] = now; l[n] = now; p[n] = $5; k[n] = key; last[key] = n }
		}
		END { for (i = 1; i <= n; i++) print f[i], l[i], p[i], k[i] }
	' "$RUN/refused" "$RUN/refused.in" | sort -n -k2,2 > "$RUN/refused.tmp"
	# two passes over the same, non-empty file: count the rows per state, then keep the newest of each
	awk -v now="$now" -v keep=$REFUSED_KEEP -v age=$REFUSED_AGE '
		NR == FNR { c[$4]++; next }
		{ c[$4]--; if (c[$4] < keep && now - $2 <= age) print }
	' "$RUN/refused.tmp" "$RUN/refused.tmp" > "$RUN/refused.new" && mv -f "$RUN/refused.new" "$RUN/refused"
	rm -f "$RUN/refused.in" "$RUN/refused.tmp"
}

# --- our table -------------------------------------------------------------------------------

dyn_elements() {  # dyn_elements <set>: its live elements with their remaining lifetime
	local e
	e=$(nft list set inet $T "$1" 2>/dev/null | tr -d '\n\t' | sed -n 's/.*elements = { \(.*\) }.*/\1/p' \
		| sed 's/ timeout [0-9a-z]*//g; s/ expires / timeout /g')
	[ -n "$e" ] && printf '\n\t\telements = { %s }' "$e"
}

# render <engaged 0|1> <lists 0|1> <carry learned IPs 0|1>: the whole table, as one nft script.
# The empty-table + delete-table prologue makes the load an atomic replace.
render() {
	local d4= d6=
	if [ "$3" = 1 ]; then d4=$(dyn_elements dyn4); d6=$(dyn_elements dyn6); fi
	cat <<EOF
#!/usr/sbin/nft -f
# GENERATED by $SELF — rebuilt at boot and whenever the direct lists change.
table inet $T {}
delete table inet $T

table inet $T {
	counter blocked {}
	counter allowed {}
	counter dns {}
	counter invalid {}

	set lan4 {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 }
	}

	set lan6 {
		type ipv6_addr
		flags interval
		elements = { fc00::/7, fe80::/10 }
	}

	# never internet: private, link-local, loopback, documentation and multicast ranges.
	# 198.18.0.0/15 is left out on purpose, it is passwall2's fake-IP range.
	set reserved4 {
		type ipv4_addr
		flags interval
		elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12,
			     192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3 }
	}

	set reserved6 {
		type ipv6_addr
		flags interval
		elements = { ::/127, fc00::/7, fe80::/10, ff00::/8 }
	}

	# IPs of direct names: passwall2's own *_white sets, copied while it runs, and our resolver's
	# answers while engaged
	set dyn4 {
		type ipv4_addr
		flags interval,timeout
		auto-merge
		timeout $DYN_TIMEOUT$d4
	}

	set dyn6 {
		type ipv6_addr
		flags interval,timeout
		auto-merge
		timeout $DYN_TIMEOUT$d6
	}

	# refused packets by source, destination, protocol and port, while the log is on; the daemon
	# moves them to $RUN/refused every second, and the timeout bounds them if it does not
	set refused4 {
		type ipv4_addr . ipv4_addr . inet_proto . inet_service
		size 1024
		flags dynamic,timeout
		timeout 1h
		counter
	}

	set refused6 {
		type ipv6_addr . ipv6_addr . inet_proto . inet_service
		size 1024
		flags dynamic,timeout
		timeout 1h
		counter
	}
EOF
	[ "$2" = 1 ] && cat "$LIB/sets.nft" 2>/dev/null
	cat <<EOF

	chain allow {
		ct label set $LABEL counter name allowed accept
	}

	# its own chain: a full set ends the rule that adds to it, and that must not skip the reject
	chain record {
$(logging && log_rules | sed 's/^/\t\t/')
	}

	chain block {
		jump record
		meta l4proto tcp counter name blocked reject with tcp reset
		counter name blocked reject with icmpx admin-prohibited
	}

	# what is let through while passwall2 is not handling it; the direct lists in passwall2's order
	chain gate {
		ip daddr @reserved4 accept
		ip6 daddr @reserved6 accept
		# a stray packet of a connection conntrack no longer knows, such as a late FIN after xray
		# closed a proxied one: it skips NAT, so passwall2 never redirects it either
		ct state invalid counter name invalid drop
EOF
	[ "$2" = 1 ] && cat "$LIB/policy.nft" 2>/dev/null
	cat <<EOF
		ip daddr @dyn4 goto allow
		ip6 daddr @dyn6 goto allow
		goto $( [ "$2" = 1 ] && cat "$LIB/default" 2>/dev/null || echo block )
	}

	chain forward {
		type filter hook forward priority filter - 5; policy accept;
		meta mark & $HB == $HB meta mark set meta mark & $HB_CLEAR ct label set $LABEL accept
		ct label $LABEL accept
		ct direction reply accept
		meta l4proto != { tcp, udp } accept
		goto gate
	}

	# the router's own traffic, after passwall2's nat_output (filter - 1) has redirected it.
	# ⚠ oif here is the device of the packet's first route: passwall2's re-routes to xray do not
	# change it. A TCP redirect shows as daddr 127.0.0.1 (reserved4), a UDP tproxy as its mark.
	chain output {
		type filter hook output priority filter + 5; policy accept;
		oif "lo" accept
		meta mark & $HB == $HB meta mark set meta mark & $HB_CLEAR ct label set $LABEL accept
		ct label $LABEL accept
		ct direction reply accept
		meta l4proto != { tcp, udp } accept
		meta mark & 0xff == 0xff accept
		# a reset: the kernel answering a late packet for a socket that is already gone, such as a
		# tunnel xray has closed. No socket means no mark 255. It carries no data, and it answers a
		# packet that already came in from that address.
		tcp flags & rst == rst accept
		# passwall2's tproxy mark: the route chain has already sent it to xray over loopback, though
		# oif still names the WAN. Only passwall2's live rules set it.
		meta mark $PW2_FWMARK accept
		meta skgid $DIRECT_GID accept
		th dport 53 accept
		goto gate
	}

	chain dns {
		type nat hook prerouting priority dstnat - 2; policy accept;
EOF
	[ "$1" = 1 ] && dns_rules | while read -r l; do printf '\t\t%s\n' "$l"; done
	printf '\t}\n}\n'
}

load() {  # (re)build our table atomically, keeping the learned IPs and the current DNS state
	local eng=1
	mkdir -p "$RUN"
	pw2_facts
	hb_complete && eng=0
	render $eng 1 1 > "$RUN/table.nft"
	nft -f "$RUN/table.nft" 2> "$RUN/load.err" && return 0
	# a malformed carry-over or list must never leave the house without a gate
	render $eng 1 0 > "$RUN/table.nft"
	nft -f "$RUN/table.nft" 2> "$RUN/load.err" && { event "table rebuilt without the learned IPs"; return 0; }
	render $eng 0 0 > "$RUN/table.nft"
	if nft -f "$RUN/table.nft" 2> "$RUN/load.err"; then
		event "the compiled lists failed to load, so only private ranges count as direct: $(head -c 300 "$RUN/load.err" | tr '\n' ' ')"
		return 0
	fi
	event "failed to load the nft table: $(head -c 300 "$RUN/load.err" | tr '\n' ' ')"
	return 1
}

ensure() { nft list chain inet $T output >/dev/null 2>&1 || load; }

remove_gate() {  # our table and the heartbeat, gone. Only for a disabled killswitch.
	local had=0
	pw2_facts
	hb_any && had=1
	disarm
	nft list chain inet $T forward >/dev/null 2>&1 && had=1
	nft delete table inet $T 2>/dev/null
	rm -f "$RUN/state" "$RUN/test"
	[ $had = 1 ] && event "turned off: traffic is no longer gated"
	return 0
}

teardown() {  # stop the daemon first, so it cannot rebuild what is being removed
	local pid
	pid=$(cat "$RUN/pid" 2>/dev/null)
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	rm -f "$RUN/pid" "$RUN/alive"
	remove_gate
}

# --- the direct lists ------------------------------------------------------------------------

wan_dns() {  # passwall2's own direct DNS: app.sh takes the first WAN resolvers in resolv.conf.auto
	local u
	u=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$RESOLV" 2>/dev/null | grep -vxE '0\.0\.0\.0|127\.0\.0\.1' \
		| awk '!s[$0]++' | head -n 2)
	echo ${u:-8.8.8.8}
}

dns_upstreams() {  # our resolver's upstreams: the setting, else what passwall2 uses for direct DNS
	local u
	u=$(uci -q get "$CONF.main.dns_server")
	if [ -n "$u" ]; then echo $u; else wan_dns; fi
}

fingerprint() {  # changes whenever the compiled output could
	local node
	node=$(uci -q get passwall2.@global[0].node)
	geo_paths
	{
		echo "v=$VERSION node=$node"
		# default_node changes on every failover; only whether it is _direct matters here
		uci -q show "passwall2.$node" | grep -v '\.default_node='
		[ "$(uci -q get "passwall2.$node.default_node")" = _direct ] && echo default_direct
		for r in $(shunt_rules); do uci -q show "passwall2.$r"; done
		dns_upstreams
		stat -c '%n %s %Y' "$GEOIP" "$GEOSITE" 2>/dev/null
	} | md5sum | cut -d' ' -f1
}

ips() {  # ips <rule> <out>: the rule's ip_list as addresses in <out>.4 and <out>.6
	local e cats= f
	: > "$2.4"; : > "$2.6"
	for e in $(uci -q get "passwall2.$1.ip_list" | tr -d '\r' | sed 's/#.*//'); do
		case $e in
			geoip:!*|ext:*|*:!*) echo "$1: $e is not supported and was left out" >> "$W/warn" ;;
			geoip:*) cats="$cats,${e#geoip:}" ;;
			*:*) echo "$e" >> "$2.6" ;;
			*) echo "$e" >> "$2.4" ;;
		esac
	done
	if [ -n "$cats" ]; then
		$GEOVIEW -type geoip -action extract -input "$GEOIP" -strict=false -list "${cats#,}" -ipv6=false >> "$2.4" 2>> "$W/geo.err"
		$GEOVIEW -type geoip -action extract -input "$GEOIP" -strict=false -list "${cats#,}" -ipv4=false >> "$2.6" 2>> "$W/geo.err"
	fi
	# one malformed entry must not fail the whole nft load, so keep only well-formed addresses
	for f in 4 6; do
		if [ $f = 4 ]; then re='^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; else re='^[0-9a-fA-F:]*:[0-9a-fA-F:.]*(/[0-9]{1,3})?$'; fi
		grep -vE "$re" "$2.$f" | grep . | sed "s/^/$1: not an IPv$f address, left out: /" >> "$W/warn"
		grep -E "$re" "$2.$f" | sort -u > "$2.$f.ok"; mv -f "$2.$f.ok" "$2.$f"
	done
}

doms() {  # doms <rule>: the rule's domain_list as plain suffixes, one per line
	local e cats=
	for e in $(uci -q get "passwall2.$1.domain_list" | tr -d '\r' | sed 's/#.*//'); do
		case $e in
			domain:*) echo "${e#domain:}" ;;
			full:*) echo "${e#full:}" ;;   # dnsmasq has no exact match: its subdomains count too
			geosite:*@*|geosite:!*) echo "$1: $e is not supported and was left out" >> "$W/warn" ;;
			geosite:*) cats="$cats,${e#geosite:}" ;;
			*:*) echo "$1: $e is not supported and was left out" >> "$W/warn" ;;
			*.*) echo "$e" ;;              # xray reads a bare string as a substring; a suffix here
			*) echo "$1: $e is not supported and was left out" >> "$W/warn" ;;
		esac
	done
	[ -n "$cats" ] && $GEOVIEW -type geosite -action extract -input "$GEOSITE" -strict=false -list "${cats#,}" 2>> "$W/geo.err"
	return 0
}

emit_set() {  # emit_set <name> <ipv4_addr|ipv6_addr> < addresses
	printf '\n\tset %s {\n\t\ttype %s\n\t\tflags interval\n\t\tauto-merge\n\t\telements = {' "$1" "$2"
	awk 'NR > 1 { printf "," } { printf "\n\t\t\t%s", $0 }'
	printf '\n\t\t}\n\t}\n'
}

# compile [--force]: turn the active shunt's rules into the gate's IP sets and the resolver's
# name list. Each rule keeps its place in the order, because passwall2's first match wins: an
# address in Proxy's list is refused even if Direct, further down, also lists it.
compile() {
	local fp node default=block i=0 r a v net pfx q o inv note n4 n6 nd ups changed=0
	mkdir -p "$RUN" "$LIB"
	exec 8> "$RUN/compile.lock"
	flock -n 8 || { echo "a compile is already running"; return 0; }
	fp=$(fingerprint)
	if [ "${1:-}" != --force ] && [ "$fp" = "$(cat "$LIB/fp" 2>/dev/null)" ]; then echo "lists unchanged"; return 0; fi
	W=$(mktemp -d /tmp/pwks.XXXXXX) || return 1
	trap 'rm -rf "$W"' EXIT
	geo_paths
	node=$(uci -q get passwall2.@global[0].node)
	: > "$W/rules"; : > "$W/dom"; : > "$W/warn"; : > "$W/sets"; : > "$W/policy"
	if [ -n "$node" ] && [ "$(uci -q get "passwall2.$node.protocol")" = _shunt ]; then
		[ "$(uci -q get "passwall2.$node.default_node")" = _direct ] && default=allow
		for r in $(shunt_rules); do
			a=$(uci -q get "passwall2.$node.$r") || continue
			[ -n "$a" ] || continue
			i=$((i + 1))
			case $a in _direct) v=direct ;; *) v=proxy ;; esac
			net=$(uci -q get "passwall2.$r.network"); net=${net:-tcp,udp}
			case $net in tcp) pfx='meta l4proto tcp ' ;; udp) pfx='meta l4proto udp ' ;; *) pfx= ;; esac
			q=
			for o in source port inbound protocol; do [ -n "$(uci -q get "passwall2.$r.$o")" ] && q="$q $o"; done
			inv=$(uci -q get "passwall2.$r.invert")
			note=
			if [ $v = direct ] && { [ -n "$q" ] || [ "$inv" = 1 ]; }; then
				[ "$inv" = 1 ] && q="$q invert"
				echo "$i|$r|$v|$net|0|0|0|left out: it applies only to part of the traffic (${q# })" >> "$W/rules"
				continue
			fi
			if [ $v = proxy ] && [ "$inv" = 1 ]; then
				printf '\t\t%sgoto block  # %s: inverted, so nothing after it counts\n' "$pfx" "$r" >> "$W/policy"
				echo "$i|$r|$v|$net|0|0|0|inverted: every rule after it is ignored" >> "$W/rules"
				break
			fi
			[ -n "$q" ] && note="applied to all traffic, not only by${q}"
			ips "$r" "$W/r$i"
			n4=$(wc -l < "$W/r$i.4"); n6=$(wc -l < "$W/r$i.6")
			[ $v = direct ] && o=allow || o=block
			if [ "$n4" -gt 0 ]; then
				emit_set "r${i}_4" ipv4_addr < "$W/r$i.4" >> "$W/sets"
				printf '\t\t%sip daddr @r%s_4 goto %s  # %s\n' "$pfx" "$i" "$o" "$r" >> "$W/policy"
			fi
			if [ "$n6" -gt 0 ]; then
				emit_set "r${i}_6" ipv6_addr < "$W/r$i.6" >> "$W/sets"
				printf '\t\t%sip6 daddr @r%s_6 goto %s  # %s\n' "$pfx" "$i" "$o" "$r" >> "$W/policy"
			fi
			doms "$r" > "$W/d$i"
			nd=$(wc -l < "$W/d$i")
			sed "s/^/$i $v /" "$W/d$i" >> "$W/dom"
			echo "$i|$r|$v|$net|$n4|$n6|$nd|$note" >> "$W/rules"
		done
	else
		echo "the global node is not a shunt, so only private ranges count as direct" >> "$W/warn"
	fi
	echo "$default" > "$W/default"

	# Each name gets the verdict of the first rule that matches it, by suffix. dnsmasq answers a
	# query from its most specific listed suffix, and every rule matching the query also matches
	# that suffix, so a verdict per listed name is exact. A proxied name below a direct one needs
	# its own refusing line; a proxied name with no direct parent is refused by default.
	awk '
		{ d = tolower($3); sub(/\.$/, "", d)
		  if (d !~ /^[a-z0-9_]([a-z0-9_.-]*[a-z0-9_])?$/) next
		  i = $1 + 0; rv[i] = $2
		  if (!(d in first) || i < first[d]) first[d] = i }
		END {
			for (d in first) {
				b = first[d]; s = d
				while ((p = index(s, ".")) > 0) { s = substr(s, p + 1); if ((s in first) && first[s] < b) b = first[s] }
				fv[d] = rv[b]
			}
			for (d in first) {
				if (fv[d] == "direct") { print "D", d; continue }
				s = d
				while ((p = index(s, ".")) > 0) { s = substr(s, p + 1); if ((s in fv) && fv[s] == "direct") { print "B", d; break } }
			}
		}' "$W/dom" | sort -k2 > "$W/names"

	ups=$(dns_upstreams)
	{
		echo "# GENERATED by $SELF compile — rewritten when passwall2's rules change."
		echo "# The killswitch's resolver: LAN DNS reaches it only while the killswitch is engaged."
		cat <<EOF
port=$DNS_PORT
local-service
no-resolv
no-hosts
no-poll
cache-size=0
dns-forward-max=1000
edns-packet-max=1232
EOF
		[ "$default" = allow ] && for u in $ups; do echo "server=$u"; done
		awk -v up="$ups" -v set="4#inet#$T#dyn4,6#inet#$T#dyn6" '
			function outd(   k) { if (!n) return; for (k = 1; k <= nu; k++) print "server=" b "/" u[k]; print "nftset=" b "/" set; b = ""; n = 0 }
			function outb() { if (!m) return; print "server=" bb "/#"; bb = ""; m = 0 }
			BEGIN { nu = split(up, u, " ") }
			$1 == "D" { b = b "/" $2; if (++n == 50) outd() }
			$1 == "B" { bb = bb "/" $2; if (++m == 50) outb() }
			END { outd(); outb() }' "$W/names"
	} > "$W/dns.conf"

	nd=$(grep -c '^D ' "$W/names"); nb=$(grep -c '^B ' "$W/names")
	{
		echo "compiled=$(date +%s)"
		echo "node=$node"
		echo "default=$default"
		echo "upstreams=$ups"
		echo "names=$nd"
		echo "refused=$nb"
		echo "ipv4=$(awk -F'|' '$3 == "direct" { s += $5 } END { print s + 0 }' "$W/rules")"
		echo "ipv6=$(awk -F'|' '$3 == "direct" { s += $6 } END { print s + 0 }' "$W/rules")"
	} > "$W/meta"
	[ -s "$W/geo.err" ] && sed 's/^/geoview: /' "$W/geo.err" | head -n 5 >> "$W/warn"

	for o in sets.nft:sets policy.nft:policy default:default dns.conf:dns.conf; do
		cmp -s "$W/${o#*:}" "$LIB/${o%%:*}" || changed=1
	done
	if [ $changed = 1 ]; then
		mv -f "$W/sets" "$LIB/sets.nft.new" && mv -f "$W/policy" "$LIB/policy.nft.new" \
			&& mv -f "$W/default" "$LIB/default.new" && mv -f "$W/dns.conf" "$LIB/dns.conf.new" || return 1
		for o in sets.nft policy.nft default dns.conf; do mv -f "$LIB/$o.new" "$LIB/$o"; done
	fi
	mv -f "$W/rules" "$LIB/rules"; mv -f "$W/warn" "$LIB/warn"; mv -f "$W/meta" "$LIB/meta"
	echo "$fp" > "$LIB/fp"
	if [ $changed = 1 ]; then
		event "direct lists compiled: $i rules, $(awk -F= '$1 == "ipv4" { print $2 }' "$LIB/meta") IPv4 and $(awk -F= '$1 == "ipv6" { print $2 }' "$LIB/meta") IPv6 entries, $nd names"
		if enabled; then
			load
			"$INIT" reload   # procd restarts the resolver, whose config file changed
		fi
	else
		echo "lists unchanged"
	fi
}

# --- the daemon ------------------------------------------------------------------------------

sync_white() {  # copy passwall2's own learned direct IPs into dyn4/dyn6
	local s d e
	for s in $WHITE_SETS; do
		case $s in *6) d=dyn6 ;; *) d=dyn4 ;; esac
		e=$(nft list set inet $PT "$s" 2>/dev/null | tr -d '\n\t' | sed -n 's/.*elements = { \(.*\) }.*/\1/p' \
			| sed 's/ timeout [0-9a-z]*//g; s/ expires [0-9a-z]*//g')
		[ -n "$e" ] && nft add element inet $T $d "{ $e }" 2>/dev/null
	done
	return 0
}

testing() {  # a test run forces the engaged state until it expires
	local until
	until=$(cat "$RUN/test" 2>/dev/null) || return 1
	[ "$(date +%s)" -lt "${until:-0}" ] && return 0
	rm -f "$RUN/test"
	event "test ended"
	return 1
}

run() {
	local now n_ok=0 tick=0 last= state why was lg= lb= b
	mkdir -p "$RUN"
	echo $$ > "$RUN/pid"
	trap 'rm -f "$RUN/pid"; exit 0' TERM INT
	enabled && ensure
	read -r last _ 2>/dev/null < "$RUN/state" || last=
	while :; do
		now=$(date +%s)
		echo "$now" > "$RUN/alive"
		# The setting is followed here too, not only through procd's reload trigger: reload_config
		# sends no event for a config it has not seen before, as after a boot or a fresh install.
		if ! enabled; then
			[ "$last" = off ] || { remove_gate; last=off; }
			sleep 2
			continue
		fi
		if ! nft list chain inet $T output >/dev/null 2>&1; then
			load && [ "$last" != off ] && event "our table was missing and has been reloaded"
		fi
		pw2_check
		testing && { OK=0; WHY="test run"; }
		# arm only after two healthy rounds in a row; disarm at the first unhealthy one
		if [ $OK = 1 ]; then
			n_ok=$((n_ok + 1))
			[ $n_ok -ge 2 ] && ! hb_complete && arm && pw2_facts
		else
			n_ok=0
			hb_any && { disarm; pw2_facts; }
		fi
		if hb_complete; then state=armed; why=; else state=engaged; why=${WHY:-waiting for passwall2 to stay healthy for two seconds}; fi
		if [ $state = armed ]; then dns_redirected && dns_set off; else dns_redirected || dns_set on; fi
		was=$last
		if [ "$state" != "$last" ]; then
			if [ $state = armed ]; then event "released: passwall2 is healthy, traffic flows normally"
			else event "engaged: $why"; fi
			echo "$state $now" > "$RUN/state"
			last=$state
		fi
		echo "$why" > "$RUN/why"
		# the log of refused connections: follow the setting, and fold in whatever the counter says
		# was refused since the last round. Only a round armed at both ends counts as armed.
		if logging; then
			[ "$lg" = 1 ] || { log_set on; [ -n "$lg" ] && event "refused connections are logged"; lg=1; }
			b=$(counter blocked); b=${b%% *}
			if [ "$b" != "$lb" ]; then
				lb=$b
				if [ "$was" = armed ] && [ $state = armed ]; then log_fold armed; else log_fold engaged; fi
			fi
		elif [ "$lg" != 0 ]; then
			log_set off; [ -n "$lg" ] && event "refused connections are no longer logged"; lg=0; lb=
		fi
		tick=$((tick + 1))
		if [ $((tick % 30)) = 1 ]; then
			[ $state = armed ] && sync_white
			fp=$(fingerprint)
			if [ "$fp" != "$(cat "$LIB/fp" 2>/dev/null)" ] && [ "$fp" != "$(cat "$RUN/tried" 2>/dev/null)" ]; then
				echo "$fp" > "$RUN/tried"   # one try per change: a failing compile is not retried in a loop
				( setsid "$SELF" compile > /dev/null 2>&1 & )
			fi
		fi
		sleep 1
	done
}

# --- reporting -------------------------------------------------------------------------------

counter() {  # counter <name>: "packets bytes"
	nft list counter inet $T "$1" 2>/dev/null | awk '/packets/ { print $2, $4; f = 1 } END { if (!f) print 0, 0 }'
}

set_size() { nft -j list set inet $T "$1" 2>/dev/null | jsonfilter -e '@.nftables[*].set.elem[*]' 2>/dev/null | wc -l; }

json() {
	local now alive st since state why u l t m
	set +u   # jshn.sh reads variables it never sets
	. /usr/share/libubox/jshn.sh
	now=$(date +%s)
	pw2_check
	alive=$(cat "$RUN/alive" 2>/dev/null)
	read -r st since 2>/dev/null < "$RUN/state" || { st=; since=0; }
	if ! enabled || ! nft list chain inet $T forward >/dev/null 2>&1; then state=off why=
	elif hb_complete; then state=armed why=
	else state=engaged; why=$(cat "$RUN/why" 2>/dev/null); [ -n "$why" ] || why=$WHY
	fi
	json_init
	json_add_int now "$now"
	json_add_boolean enabled "$(enabled && echo 1 || echo 0)"
	json_add_boolean daemon "$([ -n "$alive" ] && [ $((now - alive)) -lt 10 ] && echo 1 || echo 0)"
	json_add_string state "$state"
	json_add_boolean log_refused "$(logging && echo 1 || echo 0)"
	json_add_string reason "$why"
	json_add_int since "${since:-0}"
	json_add_int test_until "$(cat "$RUN/test" 2>/dev/null || echo 0)"
	json_add_object pw2
	json_add_boolean enabled "$([ "$(uci -q get passwall2.@global[0].enabled)" = 1 ] && echo 1 || echo 0)"
	json_add_boolean rules "$NAT_JUMP"
	json_add_boolean starting "$STARTING"
	json_add_string tcp_port "$TCP_PORT"
	json_add_boolean tcp_listen "$TCP_LISTEN"
	json_add_string udp_port "$UDP_PORT"
	json_add_boolean udp_listen "$UDP_LISTEN"
	json_add_string healthy_reason "$WHY"
	json_close_object
	json_add_object dns
	json_add_boolean running "$(pgrep -f "dnsmasq.*$LIB/dns.conf" >/dev/null && echo 1 || echo 0)"
	json_add_int port "$DNS_PORT"
	json_add_boolean redirect "$(dns_redirected && echo 1 || echo 0)"
	json_add_array upstreams
	for u in $(awk -F= '$1 == "upstreams" { print $2 }' "$LIB/meta" 2>/dev/null); do json_add_string "" "$u"; done
	json_close_array
	json_add_string wan_dns "$(wan_dns | tr '\n' ' ' | sed 's/ $//')"
	json_close_object
	json_add_object lists
	for k in compiled node default names refused ipv4 ipv6; do
		json_add_string "$k" "$(awk -F= -v k="$k" '$1 == k { print substr($0, length(k) + 2) }' "$LIB/meta" 2>/dev/null)"
	done
	json_add_int dyn4 "$(set_size dyn4)"
	json_add_int dyn6 "$(set_size dyn6)"
	json_add_array rules
	while IFS='|' read -r i r v n n4 n6 nd note; do
		json_add_object ""
		json_add_string name "$r"; json_add_string verdict "$v"; json_add_string network "$n"
		json_add_int ipv4 "$n4"; json_add_int ipv6 "$n6"; json_add_int names "$nd"; json_add_string note "$note"
		json_close_object
	done < "$LIB/rules" 2>/dev/null
	json_close_array
	json_add_array warnings
	while read -r l; do json_add_string "" "$l"; done < "$LIB/warn" 2>/dev/null
	json_close_array
	json_close_object
	json_add_object counters
	for k in blocked allowed dns invalid; do
		set -- $(counter $k)
		json_add_object "$k"; json_add_int packets "$1"; json_add_int bytes "$2"; json_close_object
	done
	json_close_object
	# newest first; read from a file, since jshn keeps its state in this shell's variables
	tail -n 25 "$RUN/events" 2>/dev/null | sed '1!G;h;$!d' > "$RUN/events.json.tmp"
	json_add_array events
	while read -r t m; do
		json_add_object ""; json_add_int t "$t"; json_add_string msg "$m"; json_close_object
	done < "$RUN/events.json.tmp"
	json_close_array
	rm -f "$RUN/events.json.tmp"
	# the log of refused connections, newest first, one "<first> <last> <packets> <state> <src> <dst> <proto> <port>" each
	sort -rn -k2,2 "$RUN/refused" 2>/dev/null > "$RUN/refused.json.tmp"
	json_add_array refused
	while read -r l; do json_add_string "" "$l"; done < "$RUN/refused.json.tmp"
	json_close_array
	rm -f "$RUN/refused.json.tmp"
	json_dump
}

status() {
	local st since
	pw2_check
	read -r st since 2>/dev/null < "$RUN/state" || { st=; since=; }
	if ! enabled; then echo "killswitch: off (disabled in /etc/config/$CONF)"
	elif hb_complete; then echo "killswitch: armed — passwall2 is healthy, traffic flows normally"
	else echo "killswitch: ENGAGED — $(cat "$RUN/why" 2>/dev/null || echo "$WHY")"
	fi
	[ -n "${since:-}" ] && echo "since:      $(date -d "@$since" '+%F %T' 2>/dev/null || echo "$since")"
	echo "passwall2:  ${WHY:-healthy}"
	echo "heartbeat:  ${HB_PRESENT:-no decision chains}$(for c in $HB_CHAINS; do eval "h=\${HB_$c:-}"; [ -n "$h" ] && printf ' %s=handle%s' "$c" "$h"; done)"
	echo "dns:        redirect $(dns_redirected && echo on || echo off), resolver $(pgrep -f "dnsmasq.*$LIB/dns.conf" >/dev/null && echo running || echo stopped) on :$DNS_PORT"
	echo "counters:   blocked $(counter blocked | cut -d' ' -f1) pkts, allowed $(counter allowed | cut -d' ' -f1), dns $(counter dns | cut -d' ' -f1), invalid dropped $(counter invalid | cut -d' ' -f1)"
	echo "learned:    $(set_size dyn4) IPv4, $(set_size dyn6) IPv6"
	refused 5 | sed 's/^/refused:    /'
	[ -f "$LIB/meta" ] && sed 's/^/lists:      /' "$LIB/meta"
	[ -s "$LIB/warn" ] && sed 's/^/warning:    /' "$LIB/warn"
	tail -n "${1:-8}" "$RUN/events" 2>/dev/null | while read -r t m; do echo "event:      $(date -d "@$t" '+%F %T' 2>/dev/null) $m"; done
}

refused() {  # refused [n]: the newest n rows of the log of refused connections, newest first
	if [ ! -s "$RUN/refused" ]; then
		if logging; then echo "none logged"; else echo "not logged (log_refused is 0)"; fi
		return 0
	fi
	sort -rn -k2,2 "$RUN/refused" | head -n "$1" | while read -r f l p s src dst pr port; do
		printf '%s while %s: %s -> %s %s/%s, %s packets%s\n' "$(date -d "@$l" '+%F %T' 2>/dev/null)" "$s" \
			"$src" "$dst" "$pr" "$port" "$p" "$([ "$f" = "$l" ] || date -d "@$f" '+, since %F %T' 2>/dev/null)"
	done
}

case "${1:-}" in
	run) run ;;
	ensure) ensure ;;
	load) load ;;
	print) pw2_facts; if hb_complete; then render 0 1 1; else render 1 1 1; fi ;;   # what load would load
	compile) compile "${2:-}" ;;
	compile-bg) ( setsid "$SELF" compile --force > /dev/null 2>&1 & ); echo "compiling in the background" ;;
	teardown) teardown ;;
	test)
		s=${2:-30}
		case $s in ''|*[!0-9]*) die "test takes a number of seconds" ;; esac
		[ "$s" -ge 5 ] && [ "$s" -le 600 ] || die "test runs 5 to 600 seconds"
		enabled || die "the killswitch is disabled"
		mkdir -p "$RUN"; echo $(( $(date +%s) + s )) > "$RUN/test"
		event "test started for ${s}s"
		echo "engaged for ${s}s" ;;
	test-stop) rm -f "$RUN/test" && event "test stopped"; echo "test stopped" ;;
	json) json ;;
	status) status "${2:-8}" ;;
	refused)
		case ${2:-20} in ''|*[!0-9]*) die "refused takes a number of rows" ;; esac
		refused "${2:-20}" ;;
	*) die "usage: $0 run|ensure|load|print|compile [--force]|compile-bg|teardown|test <s>|test-stop|json|status|refused [n]" ;;
esac
