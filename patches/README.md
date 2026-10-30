# Five local patches for passwall2

Five small shell scripts that patch [passwall2](https://github.com/xiaorouji/openwrt-passwall2) on an
OpenWrt router running xray. Three close leaks, where traffic or DNS that the shunt sends through the
tunnel still left over the ISP from the house's own address. Two add an option passwall2 lacks.

Each script edits one installed file in place. Each one is idempotent, keeps a copy of the original,
checks that the result still parses, and refuses with the file unchanged when its anchor lines are not
where it expects them. None of them touches your uci config.

Tested on OpenWrt 25.12.6 (x86_64, apk) with `luci-app-passwall2` 26.10.20-r1, `xray-core` 26.10.21-r1
and the nftables backend (`use_nft=1`). Other versions may move the anchors; the script then says so.

| # | Script | Patches | What it changes |
|---|---|---|---|
| 1 | [`passwall2-masque-xmux.sh`](#1-masque-xmux-several-tunnels-per-node) | `util_xray.lua` | a MASQUE node can open several tunnels (`xmux.maxConnections`) |
| 2 | [`passwall2-dns-nonip.sh`](#2-mx-txt-srv-and-other-dns-types-leave-over-the-isp) | `util_xray.lua` | MX, TXT, SRV, NS and PTR lookups go through the tunnel instead of the ISP |
| 3 | [`passwall2-direct-udp-guard.sh`](#3-udp-leaves-over-the-isp-after-a-direct-packet-on-the-same-socket) | `util_xray.lua` | a UDP socket whose first packet went direct can no longer send its later packets anywhere direct |
| 4 | [`passwall2-force-proxy.sh`](#4-lan-traffic-to-a-node-address-leaves-over-the-isp) | `nftables.sh` | brings back `force_proxy_lan_ip`, plus `all`: LAN traffic to node addresses follows the shunt |
| 5 | [`passwall2-resolve-address.sh`](#5-node-hostnames-pin-their-whole-domain-to-the-direct-dns) | `subscribe.lua`, LuCI form | a per-subscription *Resolve server domains to IPs* checkbox, so node hostnames stop pinning their domain to the direct DNS |

`udp-reuse-probe.py` reproduces the leak that patch 3 closes, from any LAN client.

Related, in this repo: [pw-killswitch](../killswitch/), for the time passwall2 is down or
restarting (LAN and router traffic then reaches only the shunt's direct lists), and
[pw-failover](../failover/), which moves passwall2 to another node or WAN when the tunnel dies. These
patches cover the time passwall2 is healthy; the killswitch covers the rest.

## Applying

From a machine that can SSH to the router:

```sh
for p in passwall2-masque-xmux passwall2-dns-nonip passwall2-direct-udp-guard passwall2-force-proxy passwall2-resolve-address; do
  echo "== $p"; ssh root@<router> 'sh -s' < $p.sh || echo "FAILED: $p"
done
ssh root@<router> /etc/init.d/passwall2 restart
```

Each prints `patched` or `already patched`. A patch takes effect at the next passwall2 restart, which
regenerates xray's config and the nft rules. passwall2 has no reload, so the restart is a 5-15 s blip
for the whole LAN.

Every script also takes the file to patch as an argument, which makes a dry run easy: copy the files
to `/tmp/x/` and run `sh passwall2-dns-nonip.sh /tmp/x/util_xray.lua`. Patch 5 takes two
(`subscribe.lua`, then `node_subscribe_config.lua`).

Pick only the ones you want; they don't depend on each other. Patches 4 and 5 work best together:
once 5 turns node hostnames into IPs, those IPs land in `psw2_vps`, and 4 keeps LAN traffic to them on
the tunnel.

To take one out, copy its backup back and restart passwall2:

| Script | Backup |
|---|---|
| 1 | `util_xray.lua.orig` |
| 2 | `util_xray.lua.pre-dns-nonip` |
| 3 | `util_xray.lua.pre-direct-udp-guard` |
| 4 | `nftables.sh.orig` |
| 5 | `subscribe.lua.pre-resolve-address`, `node_subscribe_config.lua.pre-resolve-address` |

Patches 1-3 share `util_xray.lua`, and each backup holds the file as it was just before that patch.
So restore the backup of the last one you applied, or restore the oldest one and re-run the patches
you want to keep.

## After every passwall2 upgrade

An upgrade of `luci-app-passwall2` overwrites every patched file. Nothing reports it: the generated
config stays valid, a leak just reopens or a feature turns off. So:

1. Back up the config: `uci export passwall2 > /root/passwall2.pre-upgrade-$(date +%Y%m%d-%H%M%S).uci`.
2. Upgrade: `apk update && apk upgrade luci-app-passwall2 xray-core`.
3. Re-run every patch. One that reports its anchors missing has to be ported to the new code. Don't
   skip it.
4. Restart passwall2 once and check that the tunnel is back.
5. Check that each patch is live:

   ```sh
   ssh root@<router> "J=/tmp/etc/passwall2/acl/acl_default.json; \
     grep -c maxConnections \$J; \
     jsonfilter -i \$J -e '@.outbounds[@.tag=\"dns-out\"].streamSettings.sockopt.dialerProxy'; \
     jsonfilter -i \$J -e '@.outbounds[@.tag=\"direct\"].settings.finalRules' | grep -c block; \
     nft list chain inet passwall2 PSW2_NAT | grep -c psw2_vps; \
     grep -c resolve_address /usr/lib/lua/luci/model/cbi/passwall2/client/node_subscribe_config.lua"
   ```

   Want, in order: `1` or more (patch 1, while a MASQUE node with the option is in use), the tag of
   the default outbound and not `direct` (2), `1` (3), `0` (4 with `all`), `1` (5).

⚠ If you use custom geo files (a `geosite.dat` with extra categories, say), an upgrade of the
`v2ray-geosite` package puts the stock file back. xray then refuses its config with `failed to check
code <CATEGORY> from geosite.dat`, and the house has no tunnel. Pin both geo packages in
`/etc/apk/world` (`v2ray-geoip=<version>`, `v2ray-geosite=<version>`) so that `apk upgrade` leaves
them alone.

## 1. MASQUE XMUX: several tunnels per node

**Problem.** xray-core 26.10 can reach Cloudflare WARP over MASQUE (CONNECT-IP, RFC 9484) on HTTP/2
over TCP 443, which makes a good pre-proxy for getting other nodes past an SNI filter. One MASQUE
tunnel is one HTTP/2 stream over one TCP connection, carrying all the inner flows, and on my line it
topped out around 8-9 MB/s. Another endpoint address or port doesn't help. More tunnels do add up:
xray's `masqueSettings.xmux.maxConnections` sets how many. passwall2 26.10.20 (and its master branch
in late October 2026) has no field for it.

**Patch.** `util_xray.lua` reads a new node option, `masque_xmux_max_connections`, and emits
`xmux = { maxConnections = N }` in the node's `masqueSettings`. Without the option the generated
config is the same as before.

```sh
uci set passwall2.<node>.masque_xmux_max_connections=8; uci commit passwall2; /etc/init.d/passwall2 restart
grep -c maxConnections /tmp/etc/passwall2/acl/acl_default.json    # 1 or more
```

LuCI keeps the option when you save the node, since it only writes the fields it shows.

Eight 8 MB downloads at once, through an end node chained over the MASQUE node, MB/s (one line, one
evening; yours will differ):

| `maxConnections` | Mean | Worst |
|---|---|---|
| 1 | 10.8 | 10.1 |
| 2 | 20.4 | 19.8 |
| 4 | 17.7 | 9.5 |
| 6 | 19.5 | 14.5 |
| 8 | 20.6 | 15.6 |
| 12 | 20.4 | 18.2 |
| 16 | 16.8 | 12.2 |

A single download stays at one tunnel's speed. Each xray process that uses the node opens its own
tunnels, so two of them chained through it (the main shunt and an extra SOCKS listener, say) open
twice as many.

## 2. MX, TXT, SRV and other DNS types leave over the ISP

**Symptom.** From a LAN client, `dig +short TXT o-o.myaddr.l.google.com @8.8.8.8` shows your ISP's
subnet as `edns0-client-subnet`, while A and AAAA lookups are fine.

**Cause.** passwall2 sends every LAN DNS query into xray's `dns-out` outbound. Its rules hand A and
AAAA to xray's DNS module (proxied names through the tunnel, direct names direct), answer HTTPS (type
65) empty, and send every other type `direct`: to passwall2's local direct-DNS forwarder, which asks
the WAN-side resolvers in cleartext. `util_xray.lua` hard-codes `local type_dns = direct_type_dns`
(upstream `main` too, checked 2026-10-26). Its `remote_type_dns` is never used, and no LuCI setting
changes this path; switching the remote DNS between TCP and UDP doesn't either. So an MX, SRV or TXT
lookup of a proxied name left over the ISP in cleartext. In my house that was about 0.7 % of all
queries, mostly MX and SRV.

**Patch.** It keeps passwall2's rules and only moves where `direct` goes: to the remote DNS server,
over its protocol, dialed through the default outbound (`dialerProxy`), so MX and the rest still get
real answers. It applies only while the default node is a proxy and the remote DNS isn't set to go
direct. A DoH-only remote DNS is left as it was.

```sh
jsonfilter -i /tmp/etc/passwall2/acl/acl_default.json -e '@.outbounds[@.tag="dns-out"].streamSettings'   # dialerProxy is the tunnel's tag
dig +short TXT o-o.myaddr.l.google.com @8.8.8.8    # from the LAN: edns0-client-subnet is the tunnel exit's /24
```

## 3. UDP leaves over the ISP after a direct packet on the same socket

**Symptom.** A STUN server sees your ISP address from a UDP socket that had just sent QUIC to a name
your shunt sends direct, at an address outside your direct IP lists. A fresh socket shows the
tunnel's address. `python3 -I udp-reuse-probe.py <a direct-listed name>` prints `DIRECT: leak`.

**Cause.** xray keys a transparent-proxy UDP session by the client's source address and port alone.
That is full-cone behaviour: `connID{src}` in `app/proxyman/inbound/worker.go`, unless
`XRAY_CONE_DISABLED=true`. The session's first packet picks the outbound, and every later packet of
that socket rides the same outbound to its own destination, because freedom sends each packet where
the packet says. So once a socket's first packet went `direct`, all its later UDP left over the ISP,
whatever the shunt says for those addresses.

With `enable_geoview_ip=1`, passwall2 loads the direct geoip and IP lists into nft sets and sends
those packets out before xray sees them, so a direct *address* never starts such a session. What
does start one:

- a QUIC packet whose sniffed name a direct domain rule matches, at an address in no nft direct set
  (xray's `IPIfNonMatch` doesn't resolve a sniffed name, so the name alone decides);
- any direct rule that matches by port, such as a "game mode" rule that sends a port range direct.

Before the fix, QUIC to `1.0.0.1` with a direct-listed name, then STUN from the same socket, showed
the ISP address 3 times out of 3 for each of three names. A real app leaks only when it reuses such a
socket for other destinations. Browsers open one socket per QUIC connection, but WebRTC, games and
VoIP apps reuse sockets.

**Patch.** freedom checks its `finalRules` against each UDP packet's destination and each reply's
source, just before it sends (`proxy/freedom/freedom.go`, xray-core 26.10.21). passwall2 always
writes `[{ action = "allow" }]`. The patch fills the `direct` outbound's `finalRules` from the
routing rules that send UDP to `direct`:

- their `ip` lists, plus `geoip:private` and the direct DNS server, for xray's own direct DNS;
- their `port`, for a rule that matches by port and has no IPs.

Every other UDP packet through `direct` is dropped. TCP is untouched. A LuCI edit or a rule flip
carries over at the restart it causes anyway. The result looks like:

```json
[{ "network": "udp", "action": "allow", "ip": ["geoip:private", "127.0.0.1", "geoip:<cc>", "…"] },
 { "action": "block", "network": "udp" },
 { "action": "allow" }]
```

What it costs:

- QUIC to a direct-listed name at an address in no nft direct set is dropped, and the browser falls
  back to TCP, which stays direct. That happens mostly right after a passwall2 restart, until the
  shunt's learned-address set fills again.
- A blocked first packet blackholes its whole session for 30-90 s (freedom's default `blockDelay`),
  so that socket's later UDP is dropped too, not tunnelled.
- `finalRules` can't match a source address, so while a port rule is active its ports pass for every
  device's direct session.
- A direct rule that matches only by `protocol` loses its UDP.

Two alternatives were weighed. Setting the direct domain rules to `network='tcp'` closes the QUIC
case by tunnelling it instead, but leaves port rules and every future domain rule open (LuCI's
default is `tcp,udp`). `XRAY_CONE_DISABLED=true` closes everything, but gives every tunnelled UDP
flow a symmetric NAT.

```sh
jsonfilter -i /tmp/etc/passwall2/acl/acl_default.json -e '@.outbounds[@.tag="direct"].settings.finalRules' | grep -c block   # 1
python3 -I udp-reuse-probe.py <direct-listed name> [more …]    # from the LAN: T0 and T1 tunnel, the rest dropped
```

## 4. LAN traffic to a node address leaves over the ISP

**Symptom.** SSH from a LAN machine to your VPS shows the house's ISP address as the client, so the
ISP sees you talk to your proxy server. Or `curl --resolve www.cloudflare.com:443:<node IP>
https://www.cloudflare.com/cdn-cgi/trace` shows the ISP address, while a neighbouring IP shows the
tunnel.

**Cause.** On every start passwall2 fills the nft set `psw2_vps` with every literal IP in any node's
`address=` or `download_address=`, used or not, and `helper_dnsmasq.lua` adds the resolved addresses
of node hostnames at runtime. The first rule of each passwall2 chain returns `psw2_vps` direct, ahead
of every shunt rule. That stops xray's own node connections from looping, but it also sends every LAN
connection to those addresses straight out. Node addresses are often your own VPS, or Cloudflare
anycast IPs shared by thousands of sites.

Upstream had an option for this, `force_proxy_lan_ip`, from `a7278fed` (2026-04-05) until `163a4ab2`
(2026-07-03) replaced it with the Direct IP List, which only feeds `psw2_direct`. 26.10.20 has nothing
like it.

**Patch.** It brings `global_forwarding.force_proxy_lan_ip` back on the nftables path. The listed
addresses go into a new set, `psw2_proxy_lan`, and every `psw2_vps` return skips them. The value
`all` drops the return from the LAN chains (`PSW2_NAT`, `PSW2_MANGLE`, `PSW2_MANGLE_V6`) altogether,
so LAN traffic to any node address follows the shunt like any other. The router's own chains keep the
return: xray's sockets carry mark 255 and bypass anyway, and a watchdog on the router (such as
[pw-failover](../failover/)) may need to dial a node address over a bound WAN.

```sh
uci add_list passwall2.@global_forwarding[0].force_proxy_lan_ip='all'
uci add_list passwall2.@global_forwarding[0].force_proxy_lan_ip='<your VPS IP>'   # also for the router's own traffic to it
uci commit passwall2; /etc/init.d/passwall2 restart
nft list chain inet passwall2 PSW2_NAT | grep -c psw2_vps    # 0 with `all`
```

A LAN device that runs its own proxy client to one of these nodes is now tunnelled twice, which works
but is slower.

## 5. Node hostnames pin their whole domain to the direct DNS

**Symptom.** Lookups of some ordinary site from the LAN leave over the ISP in cleartext, though the
shunt proxies that site. `/tmp/etc/passwall2/acl/acl_default_dnsmasq.d/001-server.conf` on the router
holds a `server=/.<that domain>/<direct DNS>` line.

**Cause.** For every node whose address is a hostname, `helper_dnsmasq.lua` pins that domain, and
every name under it, to the direct DNS in the LAN dnsmasq. Those lookups never reach xray, so neither
patch 2 nor a proxy rule for the domain changes them. CDN-fronted nodes often use a big third-party
site's domain as their address (it resolves to the CDN), and then every lookup of that site, by every
device in the house, goes direct. The pins can't simply be dropped: they are how the router resolves
a node's hostname without the tunnel. passwall2's own *Domain DNS Resolve* only changes which DNS xray
uses for the node and leaves the pin in place.

**Patch.** A per-subscription checkbox, *Resolve server domains to IPs* (uci `resolve_address`), just
above *Domain DNS Resolve* in the subscription form. On each update of a ticked subscription:

- a node address that is a hostname becomes its IPv4 address, resolved with the direct DNS passwall2
  itself uses for node domains (the first two WAN resolvers), so the router gets the address it would
  have used anyway, frozen at import;
- before that, an empty SNI or transport Host is set to the hostname, so TLS and Host stay as they
  were, and the hostname is kept in the node option `resolved_from`.

Left alone: names a `_direct` rule of the active shunt matches (`geosite:` lists through geoview),
since they go direct anyway; protocols other than vless, vmess, trojan, shadowsocks, socks and http;
names that resolve to nothing or to a private address (a poisoned answer); and the WARP endpoint
hostname. After an update passwall2 finds the nodes in use again by their address; the patch makes it
compare `resolved_from` there, so a node keeps its identity when its IP changes.

The IP changes only at an update that changes the subscription, or at a manual update. If the
provider moves a node, it fails until then.

```sh
uci set passwall2.<subscription>.resolve_address=1; uci commit passwall2    # or tick it in LuCI, then update the subscription
uci -X show passwall2 | grep resolved_from
cat /tmp/etc/passwall2/acl/acl_default_dnsmasq.d/001-server.conf          # no pin for those domains
```

## Checking for leaks

From a LAN client, every address must be the tunnel's exit, and every DNS answer must carry the
exit's subnet:

```sh
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=
curl -s --http3-only https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=         # QUIC
dig +short TXT o-o.myaddr.l.google.com @8.8.8.8                                     # non-A DNS (patch 2)
dig +short +tls TXT o-o.myaddr.l.google.com @1.1.1.1                                # DoT
curl -s --resolve www.cloudflare.com:443:<IP from psw2_vps> https://www.cloudflare.com/cdn-cgi/trace | grep ^ip=   # patch 4
python3 -I udp-reuse-probe.py <direct-listed name>                                  # patch 3
```

For a passive view of real traffic, record what leaves the WAN ports for a while, then compare each
destination with passwall2's own sets (`nft get element inet passwall2 <set> '{ <ip> }'`). xray's own
sockets carry mark 255, so they are skipped. Take the table down when done:

```sh
nft -f - <<'EOF'
table inet leakaudit {
	set fwd4 { type ipv4_addr . ipv4_addr . inet_proto . inet_service; flags dynamic,timeout; timeout 3h; size 65535; counter; }
	set loc4 { type ipv4_addr . ipv4_addr . inet_proto . inet_service; flags dynamic,timeout; timeout 3h; size 65535; counter; }
	chain post {
		type filter hook postrouting priority srcnat - 10; policy accept;
		oifname != { "<wan dev>", "<other wan dev>" } return
		meta mark & 0xff == 0xff return
		meta l4proto != { tcp, udp } return
		fib saddr type local add @loc4 { ip saddr . ip daddr . meta l4proto . th dport } return
		add @fwd4 { ip saddr . ip daddr . meta l4proto . th dport }
	}
}
EOF
nft -j list set inet leakaudit fwd4    # forwarded LAN flows that left directly
nft delete table inet leakaudit
```

## Things that bite

- **WAN DNS addresses go direct on every port.** passwall2 takes every `nameserver` in
  `/tmp/resolv.conf.d/resolv.conf.auto` for the ISP's resolver and adds the whole address to
  `psw2_direct` at start (logged as `Add ISP IPv4 DNS to the whitelist`). If a WAN's `dns` is
  `1.1.1.1`, then DoH, DoT and HTTPS to `1.1.1.1` from the LAN all leave direct. Give each WAN its own
  gateway as `dns` (with `peerdns 0`), which a private range already sends direct.
- **ICMP is never proxied.** Ping and traceroute leave direct whatever the shunt says. That's
  passwall2's design, not a leak these patches cover.
- **Diagnose egress at postrouting.** In an output-hook rule, `oif` is the device of the packet's
  first route, so the router's tproxied UDP shows the WAN device although it leaves by loopback to
  xray.
- **Your own scripts may key on passwall2's names.** Anything that reads chain names (`PSW2_NAT`,
  `PSW2_MANGLE` …) or outbound tags breaks quietly when an upgrade renames them, such as
  [pw-killswitch](../killswitch/)'s heartbeat.
  Check after each upgrade.

Use at your own risk. These patches are not part of passwall2, and they are not affiliated with it.
