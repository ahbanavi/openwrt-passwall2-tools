#!/bin/sh
# pw-failover-drill.sh — break the tunnel or the primary WAN on purpose, to prove pw-failover
# end to end. Runs on the router and leaves nothing behind but kernel state that expires:
#
#   ssh root@<router> sh -s -- node 12 < pw-failover-drill.sh   # drop the primary node's first hop
#   ssh root@<router> sh -s -- wan 10  < pw-failover-drill.sh   # drop all of the primary WAN's device, both ways
#   ssh root@<router> sh -s -- clear   < pw-failover-drill.sh   # end a drill now
#
# The drill cuts the house's internet until pw-failover recovers it, and it cuts this machine's
# internet too, so arm it and stay idle. Three dead-mans remove the block, none needing SSH:
#   1. the nft set elements carry a kernel timeout of <minutes>;
#   2. a setsid sleep deletes the whole table 30 s after that;
#   3. nothing is persisted, so a reboot clears it.
# Manual escape from the LAN: ssh root@<router> 'nft delete table inet pwf_drill'
#
# While the marker is up, reports are tagged [DRILL] and the switch-back holds are shortened.
set -u

KIND=${1:-}; MIN=${2:-10}
RUN=/var/run/pw-failover
SCRIPT=/root/scripts/pw-failover.sh
TABLE="inet pwf_drill"

die() { echo "refused: $*" >&2; exit 1; }

case "$KIND" in
  clear)
    nft delete table $TABLE 2>/dev/null && echo "block removed" || echo "no block"
    rm -f "$RUN/drill" "$RUN/overrides"; echo "drill marker removed"
    exit 0 ;;
  node|wan) ;;
  *) echo "usage: sh -s -- node|wan [minutes] | clear" >&2; exit 2 ;;
esac
case "$MIN" in ''|*[!0-9]*) die "minutes must be a number" ;; esac
[ "$MIN" -ge 2 ] && [ "$MIN" -le 20 ] || die "minutes must be 2-20"

# Only drill a healthy, armed watchdog sitting on the primary WAN and node.
pgrep -f '[p]w-failover.sh run' >/dev/null || die "the pw-failover daemon is not running"
# the settings in effect, from uci or pw-failover.conf, as the script itself resolves them
eval "$("$SCRIPT" conf)" || die "cannot read the settings"
[ "$MODE" = act ] || die "MODE is not act"
[ -e /etc/pw-failover/pause ] && die "pw-failover is paused"
[ -e "$RUN/drill" ] && die "a drill is already running ($(cat "$RUN/drill"))"
nft list table $TABLE >/dev/null 2>&1 && die "table pwf_drill already exists"
[ -n "$(ip -4 route show default proto 201)" ] && die "a backup WAN is active"
[ -s /etc/pw-failover/state ] && die "a fallback node is active"
[ -s /etc/pw-failover/manual ] && die "a manual override is set"
[ "$("$SCRIPT" node-id)" = "$PRIMARY_NODE" ] || die "the egress node is not the primary"
"$SCRIPT" status 0 | grep -q '^probe: *ok' || die "the tunnel probe is not ok right now"

if [ "$KIND" = node ]; then
  # The server the router dials: the primary's pre-proxy when it rides one (passwall2's
  # chain_proxy 1), as node_dial_id in pw-failover.sh. TCP and UDP, for a QUIC hop.
  id=$PRIMARY_NODE; pre=$(uci -q get "passwall2.$id.preproxy_node")
  [ "$(uci -q get "passwall2.$id.chain_proxy")" = 1 ] && [ -n "$pre" ] \
    && [ "$(uci -q get "passwall2.$pre")" = nodes ] && id=$pre
  addr=$(uci -q get "passwall2.$id.address"); port=$(uci -q get "passwall2.$id.port")
  echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || die "$id's address is not an IPv4 address: $addr"
  case "$port" in ''|*[!0-9]*) die "$id's port is not a number: $port" ;; esac
fi

# The marker outlives the block by 30 min so the shortened switch-back applies to the drill.
echo "$KIND $(($(date +%s) + MIN * 60 + 1800))" > "$RUN/drill"
cat > "$RUN/overrides" <<'EOF'
NODE_SB_INTERVAL=60
NODE_SB_PASSES=1
WAN_SB_HOLD_DOWN=0
WAN_SB_HOLD_NODES=0
EOF

# Dead-man 2 goes in before the block does.
setsid sh -c "sleep $((MIN * 60 + 30)); nft delete table $TABLE 2>/dev/null" </dev/null >/dev/null 2>&1 &

nft -f - <<'EOF' || { rm -f "$RUN/drill" "$RUN/overrides"; die "nft table failed"; }
table inet pwf_drill {
  set node_ep { type ipv4_addr . inet_service; flags timeout; }
  set wan_if  { type ifname; flags timeout; }
  chain out  { type filter hook output priority -300; policy accept; meta l4proto { tcp, udp } ip daddr . th dport @node_ep drop; }
  chain pre  { type filter hook prerouting priority -300; policy accept; iifname @wan_if drop; }
  chain post { type filter hook postrouting priority 300; policy accept; oifname @wan_if drop; }
}
EOF

if [ "$KIND" = node ]; then
  nft add element $TABLE node_ep "{ $addr . $port timeout ${MIN}m }"
  echo "armed: $addr:$port tcp+udp dropped from the router for ${MIN} min"
else
  set -- $WAN_ORDER
  dev=$(uci -q get "network.$1.device")
  nft add element $TABLE wan_if "{ \"$dev\" timeout ${MIN}m }"
  echo "armed: all traffic on $1 ($dev) dropped for ${MIN} min"
fi
logger -t pw-failover "DRILL armed: $KIND for ${MIN} min"
