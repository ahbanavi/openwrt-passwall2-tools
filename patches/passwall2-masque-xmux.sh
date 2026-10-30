#!/bin/sh
# passwall2 local patch: let a MASQUE node emit Xray's masqueSettings.xmux, so the node opens
# several CONNECT-IP tunnels instead of one. passwall2 26.10.20 has no field for it.
# The node's uci option masque_xmux_max_connections (e.g. 8) becomes xmux.maxConnections; without
# it the generated config is unchanged:
#   uci set passwall2.<node>.masque_xmux_max_connections=8; uci commit passwall2
# LuCI keeps the option when the node is saved, since it only writes the fields it shows.
# Why and how: README.md next to this script.
#
# Idempotent. Re-run after every luci-app-passwall2 upgrade, which overwrites the file:
#   ssh root@<router> 'sh -s' < passwall2-masque-xmux.sh
# An optional argument patches another copy (a dry run): sh -s /tmp/x/util_xray.lua
# The patch only takes effect at the next passwall2 restart.
F=${1:-/usr/lib/lua/luci/passwall2/util_xray.lua}

if grep -q masque_xmux_max_connections "$F"; then
	echo "already patched"
	exit 0
fi
if [ "$(grep -c 'address = node.masque_warp_address' "$F")" != 1 ]; then
	echo "anchor not found once in $F: passwall2 changed, patch by hand" >&2
	exit 1
fi

cp -p "$F" "$F.orig"
awk '
	/address = node\.masque_warp_address/ { seen = 1 }
	{ print }
	seen == 1 && /^\t+\} or nil,$/ {
		print "\t\t\t\t\txmux = (tonumber(node.masque_xmux_max_connections) or 0) > 0 and {"
		print "\t\t\t\t\t\tmaxConnections = tonumber(node.masque_xmux_max_connections)"
		print "\t\t\t\t\t} or nil,"
		seen = 2
	}
' "$F.orig" > "$F.new"

if grep -q masque_xmux_max_connections "$F.new" && lua -e "assert(loadfile('$F.new'))"; then
	mv "$F.new" "$F"
	echo "patched (original kept as $F.orig)"
else
	rm -f "$F.new"
	echo "patch failed, $F unchanged" >&2
	exit 1
fi
