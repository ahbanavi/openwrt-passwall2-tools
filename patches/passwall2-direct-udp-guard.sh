#!/bin/sh
# passwall2 local patch: the `direct` outbound sends UDP only where a routing rule sends UDP direct
# by address or port, checked per packet. Everything else it drops.
#
# xray keys a transparent-proxy UDP session by the client's source address and port alone
# (full cone: `connID{src}` in app/proxyman/inbound/worker.go, unless XRAY_CONE_DISABLED). The
# session's first packet picks the outbound, and every later packet of that socket rides it,
# whatever its destination. So once a socket's first packet went `direct`, its later packets to
# addresses the shunt sends through the tunnel leave over the ISP from your own address. With
# enable_geoview_ip=1 the direct IP lists are handled in nftables before xray sees a packet, so what
# still binds a session to `direct` is a sniffed QUIC name in a direct domain rule, and any direct
# rule that matches by port.
#
# freedom checks `finalRules` against each UDP packet's own destination, and each reply's source,
# just before it sends (proxy/freedom/freedom.go, xray-core 26.10.21). passwall2 always writes
# `[{ action = "allow" }]`. The patch derives the allow list from the routing rules that send UDP
# to `direct`: their `ip` lists, and their `port` for a port rule. `geoip:private` and the direct
# DNS server stay allowed for xray's own direct DNS. Direct rules that match only by domain,
# protocol or inbound add nothing, so their UDP is dropped; a blocked first packet blackholes that
# session for 30-90 s (freedom's default blockDelay). TCP is untouched. It applies only while the
# default outbound is a proxy. Why and how: README.md next to this script.
#
# Idempotent. Re-run after every luci-app-passwall2 upgrade, which overwrites the file:
#   ssh root@<router> 'sh -s' < passwall2-direct-udp-guard.sh
# An optional argument patches another copy (a dry run): sh -s /tmp/x/util_xray.lua
# The patch only takes effect at the next passwall2 restart.
F=${1:-/usr/lib/lua/luci/passwall2/util_xray.lua}
TAG='local patch (passwall2-direct-udp-guard.sh)'

if grep -qF "$TAG" "$F"; then
	echo "already patched"
	exit 0
fi

BLOCK=$(mktemp) || exit 1
trap 'rm -f "$BLOCK"' EXIT
cat > "$BLOCK" <<EOF
-- $TAG: xray keys a UDP session by
-- source port alone, so a socket's later packets ride the outbound its first packet chose.
-- Direct UDP may reach only what a routing rule sends direct by address or port, per packet.
do
	local _g_out = COMMON.default_outbound_tag
	if routing and routing.rules and _g_out and _g_out ~= "direct" and _g_out ~= "blackhole" then
		local _g_ip, _g_seen, _g_rules = {}, {}, {}
		local function _g_add(w)
			if w and w ~= "" and not _g_seen[w] then
				_g_seen[w] = true
				table.insert(_g_ip, w)
			end
		end
		_g_add("geoip:private")
		_g_add(direct_dns_udp_server)
		for _, r in ipairs(routing.rules) do
			if r.outboundTag == "direct" and (r.network or "tcp,udp"):find("udp", 1, true)
				and not r.domains and not r.domain and not r.protocol and not r.inboundTag then
				if r.ip and r.port then
					table.insert(_g_rules, { action = "allow", network = "udp", ip = r.ip, port = r.port })
				elseif r.ip then
					for _, w in ipairs(r.ip) do _g_add(w) end
				elseif r.port then
					table.insert(_g_rules, { action = "allow", network = "udp", port = r.port })
				end
			end
		end
		table.insert(_g_rules, 1, { action = "allow", network = "udp", ip = _g_ip })
		table.insert(_g_rules, { action = "block", network = "udp" })
		table.insert(_g_rules, { action = "allow" })
		direct_outbound.settings = direct_outbound.settings or {}
		direct_outbound.settings.finalRules = _g_rules
	end
end
EOF

cp -p "$F" "$F.pre-direct-udp-guard"
awk -v block="$BLOCK" '
	{ t = $0; sub(/^[ \t]+/, "", t) }
	t == "local direct_outbound = {" { seen = 1 }
	seen && !done && t == "if COMMON.default_outbound_tag == \"direct\" then" {
		ind = $0; sub(/[^ \t].*$/, "", ind)
		while ((getline l < block) > 0) print (l == "" ? "" : ind l)
		done = 1
		n++
	}
	{ print }
	END {
		if (n != 1) { printf "anchor found %d times, want 1\n", n > "/dev/stderr"; exit 1 }
	}
' "$F.pre-direct-udp-guard" > "$F.new"

if [ $? = 0 ] && grep -qF "$TAG" "$F.new" && lua -e "assert(loadfile('$F.new'))" 2>/dev/null; then
	chmod 644 "$F.new"
	mv "$F.new" "$F"
	echo "patched (original kept as $F.pre-direct-udp-guard)"
else
	rm -f "$F.new"
	echo "anchor not found or Lua does not parse: passwall2 changed, patch by hand; $F unchanged" >&2
	exit 1
fi
