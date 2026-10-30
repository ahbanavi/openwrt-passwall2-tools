#!/bin/sh
# passwall2 local patch: bring back global_forwarding.force_proxy_lan_ip. Upstream had it from
# a7278fed (2026-04-05) until 163a4ab2 (2026-07-03) replaced it with the Direct IP List;
# passwall2 26.10.20 has no way to force an address through the core.
#
# passwall2 puts every literal IP in any node's address= into psw2_vps, plus the resolved IPs of node
# hostnames at runtime, and the first rule of each chain returns psw2_vps direct, ahead of every shunt
# rule. With this patch the listed addresses also go into psw2_proxy_lan, and every psw2_vps return
# skips them, so traffic to them enters the core even while a node dials them:
#   uci add_list passwall2.@global_forwarding[0].force_proxy_lan_ip='<your VPS IP>'
# The value `all` drops the psw2_vps return from the LAN chains (PSW2_NAT, PSW2_MANGLE,
# PSW2_MANGLE_V6) altogether, so LAN traffic to any node address follows the shunt rules like any
# other. The router's own chains keep the return: xray's sockets carry mark 255 anyway, and a
# watchdog on the router may dial a node address over a bound WAN.
#   uci add_list passwall2.@global_forwarding[0].force_proxy_lan_ip='all'
# Only the nftables path is patched (use_nft=1). Why and how: README.md next to this script.
#
# Idempotent: always rebuilt from the untouched nftables.sh.orig. Re-run after every
# luci-app-passwall2 upgrade, which overwrites the file:
#   ssh root@<router> 'sh -s' < passwall2-force-proxy.sh
# An optional argument patches another copy (a dry run): sh -s /tmp/x/nftables.sh
# The patch only takes effect at the next passwall2 restart.
F=${1:-/usr/share/passwall2/nftables.sh}
V=FORCE_PROXY_LAN_ALL   # marker of this version of the patch

if grep -q "$V" "$F"; then
	echo "already patched"
	exit 0
fi
# An earlier version of this patch is in place: rebuild from the original it kept.
if grep -q NFTSET_PROXY_LAN "$F"; then
	[ -f "$F.orig" ] || { echo "$F is patched but $F.orig is missing; patch by hand" >&2; exit 1; }
else
	cp -p "$F" "$F.orig"
fi

awk '
	{ t = $0; sub(/^[ \t]+/, "", t) }
	t == "NFTSET_WAN=\"psw2_wan\"" { print; print "NFTSET_PROXY_LAN=\"psw2_proxy_lan\""; a1++; next }
	t == "NFTSET_WAN6=\"psw2_wan6\"" { print; print "NFTSET_PROXY_LAN6=\"psw2_proxy_lan6\""; a2++; next }
	t == "gen_nftset $NFTSET_VPS ipv4_addr 0 \"-1\"" { print; print "\tgen_nftset $NFTSET_PROXY_LAN ipv4_addr 0 \"-1\""; a3++; next }
	t == "gen_nftset $NFTSET_VPS6 ipv6_addr 0 \"-1\"" { print; print "\tgen_nftset $NFTSET_PROXY_LAN6 ipv6_addr 0 \"-1\""; a4++; next }
	t == "get_local_ips ip6 | insert_nftset $NFTSET_LOCAL6" {
		print
		print "\t# local patch (passwall2-force-proxy.sh): force_proxy_lan_ip skips psw2_vps"
		print "\tconfig_t_get global_forwarding force_proxy_lan_ip | tr \" \" \"\\n\" | grep -vx all | grep -v \":\" | insert_nftset $NFTSET_PROXY_LAN"
		print "\tconfig_t_get global_forwarding force_proxy_lan_ip | tr \" \" \"\\n\" | grep -vx all | grep \":\" | insert_nftset $NFTSET_PROXY_LAN6"
		print "\tFORCE_PROXY_LAN_ALL=0"
		print "\tconfig_t_get global_forwarding force_proxy_lan_ip | tr \" \" \"\\n\" | grep -qx all && FORCE_PROXY_LAN_ALL=1"
		a5++; next
	}
	t == "destroy_nftset $NFTSET_VPS" { print; print "\tdestroy_nftset $NFTSET_PROXY_LAN"; a6++; next }
	t == "destroy_nftset $NFTSET_VPS6" { print; print "\tdestroy_nftset $NFTSET_PROXY_LAN6"; a7++; next }
	index($0, "ip daddr @$NFTSET_VPS counter return") {
		sub(/ip daddr @\$NFTSET_VPS counter return/, "ip daddr @$NFTSET_VPS ip daddr != @$NFTSET_PROXY_LAN counter return"); r4++
	}
	index($0, "ip6 daddr @$NFTSET_VPS6 counter return") {
		sub(/ip6 daddr @\$NFTSET_VPS6 counter return/, "ip6 daddr @$NFTSET_VPS6 ip6 daddr != @$NFTSET_PROXY_LAN6 counter return"); r6++
	}
	# the LAN chains drop the return entirely under `all`
	index($0, "PSW2_NAT ip daddr @$NFTSET_VPS ") || index($0, "PSW2_MANGLE ip daddr @$NFTSET_VPS ") || index($0, "PSW2_MANGLE_V6 ip6 daddr @$NFTSET_VPS6 ") {
		ind = $0; sub(/[^ \t].*$/, "", ind)
		print ind "[ \"$FORCE_PROXY_LAN_ALL\" = 1 ] || \\"
		lan++
	}
	{ print }
	END {
		if (a1 != 1 || a2 != 1 || a3 != 1 || a4 != 1 || a5 != 1 || a6 != 1 || a7 != 1 || r4 < 1 || r6 < 1 || lan != 3) {
			printf "anchors %d%d%d%d%d%d%d, returns v4 %d v6 %d, LAN chains %d\n", a1, a2, a3, a4, a5, a6, a7, r4, r6, lan > "/dev/stderr"
			exit 1
		}
		printf "psw2_vps returns patched: v4 %d, v6 %d, LAN chains %d\n", r4, r6, lan > "/dev/stderr"
	}
' "$F.orig" > "$F.new"

if [ $? = 0 ] && sh -n "$F.new" && grep -q "$V" "$F.new"; then
	chmod 755 "$F.new"
	mv "$F.new" "$F"
	echo "patched (original kept as $F.orig)"
else
	rm -f "$F.new"
	echo "anchors not found as expected: passwall2 changed, patch by hand; $F unchanged" >&2
	exit 1
fi
