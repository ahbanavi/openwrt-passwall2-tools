#!/bin/sh
# passwall2 local patch: DNS queries of types xray's DNS module cannot answer (MX, SRV, TXT, NS,
# public PTR …) go to the remote DNS through the tunnel instead of the direct DNS.
#
# passwall2 sends every DNS query from the LAN into xray's `dns-out` outbound. Its rules hand A and
# AAAA to the DNS module (proxied names through the tunnel, direct names direct), answer HTTPS (65)
# empty, and send every other type `direct`: rewritten to the direct DNS (passwall2's local
# forwarder, which asks the WAN-side resolvers) with `dialerProxy = "direct"`. So an MX or TXT lookup
# of a proxied name leaves over the ISP in cleartext, and the authoritative server sees the ISP's
# subnet as the EDNS client subnet. upstream util_xray.lua (main, 2026-10-26) still hard-codes
# `local type_dns = direct_type_dns`; its `remote_type_dns` is never used, and has no address for a
# TCP remote DNS anyway.
#
# The patch keeps passwall2's rules and only moves where `direct` goes: the remote DNS server, over
# its protocol, dialed through the default (tunnel) outbound. It applies only while the default node
# is a proxy and the remote DNS is not set to go direct; a DoH-only remote DNS is left as it was.
# Why and how: README.md next to this script.
#
# Idempotent. Re-run after every luci-app-passwall2 upgrade, which overwrites the file:
#   ssh root@<router> 'sh -s' < passwall2-dns-nonip.sh
# An optional argument patches another copy (a dry run): sh -s /tmp/x/util_xray.lua
# The patch only takes effect at the next passwall2 restart.
F=${1:-/usr/lib/lua/luci/passwall2/util_xray.lua}
TAG='local patch (passwall2-dns-nonip.sh)'

if grep -qF "$TAG" "$F"; then
	echo "already patched"
	exit 0
fi

cp -p "$F" "$F.pre-dns-nonip"
awk -v tag="$TAG" '
	{ print }
	{ t = $0; sub(/^[ \t]+/, "", t) }
	t == "local type_dns = direct_type_dns" {
		ind = $0; sub(/[^ \t].*$/, "", ind)
		print ind "-- " tag ": query types the DNS module cannot"
		print ind "-- answer (MX, SRV, TXT …) go to the remote DNS through the tunnel, not to the direct DNS"
		print ind "local _np_server = remote_dns_udp_server or remote_dns_tcp_server"
		print ind "local _np_port = remote_dns_udp_server and remote_dns_udp_port or remote_dns_tcp_port"
		print ind "local _np_out = COMMON.default_outbound_tag"
		print ind "if _np_server and remote_dns_detour ~= \"direct\" and _np_out and _np_out ~= \"direct\" and _np_out ~= \"blackhole\" then"
		print ind "\ttype_dns = {"
		print ind "\t\tsettings = {"
		print ind "\t\t\trewriteAddress = _np_server,"
		print ind "\t\t\trewritePort = tonumber(_np_port) or 53,"
		print ind "\t\t\trewriteNetwork = _remote_dns_proto or \"tcp\","
		print ind "\t\t\trules = direct_type_dns.settings.rules"
		print ind "\t\t},"
		print ind "\t\tstreamSettings = { sockopt = { dialerProxy = _np_out } }"
		print ind "\t}"
		print ind "end"
		n++
	}
	END {
		if (n != 1) { printf "anchor found %d times, want 1\n", n > "/dev/stderr"; exit 1 }
	}
' "$F.pre-dns-nonip" > "$F.new"

if [ $? = 0 ] && grep -qF "$TAG" "$F.new" && lua -e "assert(loadfile('$F.new'))" 2>/dev/null; then
	chmod 644 "$F.new"
	mv "$F.new" "$F"
	echo "patched (original kept as $F.pre-dns-nonip)"
else
	rm -f "$F.new"
	echo "anchor not found or Lua does not parse: passwall2 changed, patch by hand; $F unchanged" >&2
	exit 1
fi
