# pw-killswitch — a killswitch for passwall2 on OpenWrt

A killswitch for an OpenWrt router that runs [passwall2](https://github.com/xiaorouji/openwrt-passwall2)
with xray. While passwall2 is healthy it changes nothing. The moment passwall2 stops, restarts, or its
proxy dies, TCP and UDP from the LAN and from the router itself may leave only for destinations that
passwall2's shunt would send direct anyway, and everything else is refused. LAN DNS then answers only
names from those direct lists. When passwall2 is healthy again, the gate opens by itself.

It is one busybox `ash` script, a procd service, a small dnsmasq instance, and a LuCI page
(*Network ▸ Killswitch*) with a card on *Status ▸ Overview*. It never edits passwall2's config and
never restarts passwall2.

Related, in this repo: [five local patches for passwall2](../patches/) that close the leaks a
healthy passwall2 still has, and [pw-failover](../failover/), which moves passwall2 to another node
or WAN when the tunnel dies. The killswitch covers the time passwall2 is *not* healthy; the patches
cover the time it is.

## Requirements

Tested on OpenWrt 25.12.6 (x86_64) with `luci-app-passwall2` 26.10.20-r1 and `xray-core` 26.10.21-r1.

- passwall2 on the nftables backend (`use_nft=1`), with a shunt node as the global node. Without a
  shunt, only private ranges count as direct.
- `localhost_proxy=1`, so passwall2 proxies the router's own traffic too. That is the only setup it
  was tested with.
- `dnsmasq-full` (the resolver uses `nftset=`), `geoview` (passwall2 already pulls it in),
  `jsonfilter`, and nftables 1.0.8 or later for `nft destroy` (tested with 1.1.6).
- The paths are fixed: the script lives at `/root/scripts/pw-killswitch.sh`. To move it, change
  `SELF` in the script, `SCRIPT` in the init and in `luci/killswitch.js`, and the paths in
  `luci/acl.json`.

## Install

From a machine that can SSH to the router, in this directory:

```sh
R=root@<router>
ssh $R 'mkdir -p /root/scripts /etc/pw-killswitch /www/luci-static/resources/view/pw-killswitch /www/luci-static/resources/view/status/include'
ssh $R 'cat > /root/scripts/pw-killswitch.sh.new && chmod 700 /root/scripts/pw-killswitch.sh.new && mv -f /root/scripts/pw-killswitch.sh.new /root/scripts/pw-killswitch.sh' < pw-killswitch.sh
ssh $R 'cat > /etc/init.d/pw-killswitch.new && chmod 755 /etc/init.d/pw-killswitch.new && mv -f /etc/init.d/pw-killswitch.new /etc/init.d/pw-killswitch' < pw-killswitch.init
ssh $R 'cat > /usr/share/luci/menu.d/luci-app-pw-killswitch.json' < luci/menu.json
ssh $R 'cat > /usr/share/rpcd/acl.d/luci-app-pw-killswitch.json' < luci/acl.json
ssh $R 'cat > /www/luci-static/resources/view/pw-killswitch/killswitch.js' < luci/killswitch.js
ssh $R 'cat > /www/luci-static/resources/view/status/include/36_pw_killswitch.js' < luci/overview.js
ssh $R 'rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache; /etc/init.d/rpcd reload'
ssh $R '[ -n "$(uci -q get pw-killswitch.main)" ] || { touch /etc/config/pw-killswitch; uci set pw-killswitch.main=main; uci set pw-killswitch.main.enabled=1; uci commit pw-killswitch; }'
```

The first time, arm a dead-man that turns the killswitch off again unless you confirm that everything
still works:

```sh
ssh $R "rm -f /tmp/pw-killswitch.keep; ( setsid sh -c 'sleep 300; [ -f /tmp/pw-killswitch.keep ] || { uci set pw-killswitch.main.enabled=0; uci commit pw-killswitch; /etc/init.d/pw-killswitch reload; }' >/dev/null 2>&1 </dev/null & )"
ssh $R '/root/scripts/pw-killswitch.sh compile --force; /etc/init.d/pw-killswitch enable; /etc/init.d/pw-killswitch restart; sleep 4; /root/scripts/pw-killswitch.sh status'
ssh $R touch /tmp/pw-killswitch.keep    # once the LAN still works and status says armed
```

To survive a sysupgrade, add `/root/scripts/pw-killswitch.sh`, the init script, its
`/etc/rc.d/S18pw-killswitch` link and the four LuCI files to `/etc/sysupgrade.conf`.
`/etc/config/pw-killswitch` is kept anyway. The compiled lists in `/etc/pw-killswitch/` are rebuilt,
so they need no backup.

To update, rerun the same commands. Always write a new file and rename it, as above: rewriting the
file under the running daemon can corrupt it. A restart of the service never opens the gate.

## How it works

### Three states

| State | When | Traffic |
|---|---|---|
| *armed* | passwall2 is enabled, its rules are loaded, no start or stop is running, and its proxy listens on the TCP and UDP redirect ports, for two checks in a row | unchanged, exactly as passwall2 routes it |
| *engaged* | anything else, or a test | TCP and UDP from the LAN and the router only to the direct lists; LAN DNS answered only for direct-list names |
| *off* | `enabled` is `0` | not gated; the table and the heartbeat are removed |

What is gated is TCP and UDP, the traffic passwall2 proxies. ICMP and other protocols pass in every
state, since passwall2 never proxies them. Private, link-local and multicast ranges always pass.
`198.18.0.0/15`, passwall2's fake-IP range, does not.

Packets that conntrack marks invalid are dropped in every state, and counted as `invalid`. They are
strays, such as a client's late FIN after xray has closed a proxied connection. They skip NAT, so
passwall2 never redirects them, and they would otherwise leave un-NATed over the ISP.

### The heartbeat

The killswitch's own chains can't see passwall2's table, so passwall2 tells them, per packet. One rule
at the top of each of passwall2's own decision chains sets mark bit `0x20000000`. In the LAN chains
(`PSW2_NAT`, `PSW2_MANGLE`) it reads:

```text
iif != "lo" th dport != 53 meta mark set meta mark | 0x20000000 comment "pw-killswitch"
```

In the router's chains (`PSW2_OUTPUT_NAT`, `PSW2_OUTPUT_MANGLE`) `iif != "lo"` becomes
`meta mark & 0xff != 0xff`, which leaves xray's own packets alone.

Only packets that passwall2 then lets through to be routed direct reach the killswitch's chains with
that bit. A redirected or tproxied packet goes to xray on the router: a LAN packet never reaches the
forward hook, and a router packet leaves by loopback. The `forward` chain (priority `filter - 5`) and
the `output` chain (`filter + 5`, after passwall2's `nat_output` has redirected) admit a connection
whose packet carries the bit, label it (`ct label 100`) and clear the bit. Every other packet goes to
the shared chain `gate`, which checks it against the direct lists.

passwall2's stop deletes the jumps into all four chains first, and the chains after. So the heartbeat
dies at the same instant as the redirects it stands for. A stop or restart never leaves a moment
where traffic is neither proxied nor checked, and that doesn't depend on the daemon noticing
anything. The daemon only puts the heartbeat back, and only after two healthy checks a second apart.

⚠ The heartbeat must never add a bit to a packet that passwall2 has tproxy-marked. passwall2's policy
route is an exact match, `fwmark 0x50535732 lookup 999`, and an extra bit sends the packet out
instead of to xray, which breaks all proxied UDP. `PSW2_RULE` overwrites the whole mark of every
packet it tproxies, so marking at the top of `PSW2_MANGLE` is safe for LAN packets. Loopback packets
arrive already marked, hence `iif != "lo"`.

Port 53 is left unmarked. With DNS redirection on, `PSW2_MANGLE` accepts DNS and `dstnat` redirects
it to passwall2's dnsmasq. passwall2's stop deletes the `dstnat` redirect before the `PSW2_MANGLE`
jump, so a marked DNS packet in the forward path would mean a query leaking in that gap.

### Why admission is per connection

A proxied TCP connection is DNATed to the router, and conntrack keeps it local after xray dies: it
gets an RST. A tproxied UDP flow is not DNATed. Once the tproxy rule is gone, its next packets are
forwarded as an established flow. So every packet of a connection that wasn't admitted is checked,
not only `ct state new`, and a connection passwall2 had sent direct keeps its `ct label` through a
restart.

### The router's own traffic

passwall2 proxies the router's own TCP and UDP too: `nat_output` redirects TCP to xray, and
`mangle_output` routes UDP to it over loopback. The `output` chain gates the rest like the LAN's,
except for what the router needs to bring passwall2 back:

| Always passes | Why |
|---|---|
| loopback, `127.0.0.0/8` | local services, and the router's TCP after passwall2 redirects it to xray |
| mark 255 | xray's own sockets: the connections to its nodes, the throwaway xray of a URL test. passwall2 sets it on every xray outbound |
| TCP resets | the kernel's answer to a late packet for a socket already gone, such as a tunnel xray has closed. No socket means no mark 255. A reset carries no data and answers a packet that already came in from that address |
| mark `0x50535732` | passwall2's tproxy mark: the router's UDP that passwall2's route chain has already sent to xray over loopback. Only passwall2's live rules set it |
| gid 9912 | passwall2's direct group, which passwall2 itself never redirects |
| port 53 | the router's DNS. passwall2 resolves node names while it starts; gating them could keep it from ever coming back |
| replies, ICMP, private ranges | as for the LAN |

So while engaged the router can still resolve any name over the ISP, but connects only to direct
destinations. Package updates, passwall2's rule updates and any notifications the router sends fail
until passwall2 is back.

### The direct lists

`compile` reads the active shunt (`passwall2.@global[0].node`) and walks its shunt rules in file
order, which is passwall2's first-match order. Each rule with an assignment on the shunt counts:
`_direct` makes it *direct*, anything else *proxied*.

- **IPs.** Each rule's `ip_list` becomes one nft set: literal addresses, plus `geoip:` categories
  expanded with `geoview`. The gate tests the sets in rule order, so an address in a proxied rule's
  list is refused even when a direct rule further down also lists it.
- **Names.** Each rule's `domain_list` (`domain:`, `full:`, `geosite:` expanded with `geoview`) goes
  into the resolver's config. Each name takes the verdict of the first rule that matches it by
  suffix. dnsmasq answers from the most specific listed suffix, and every rule matching a query also
  matches that suffix, so a verdict per listed name is exact. A proxied name below a direct suffix
  gets its own refusing line.
- **Learned IPs.** Sets `dyn4`/`dyn6` (lifetime 1 day) hold the addresses of direct names. While
  armed, the daemon copies passwall2's own `psw2_*_white` sets into them every 30 s. While engaged,
  the resolver adds its answers itself (`nftset=`).
- **The rest.** Traffic no rule matches takes the verdict of the shunt's default node: allowed when
  it is `_direct`, refused otherwise.

What is left out, and listed under *Left out of the lists* on the page:

- A direct rule with `source`, `port`, `inbound`, `protocol` or `invert` set, since it covers only
  part of the traffic. A "game mode" rule that sends a port range direct is refused while engaged.
- A proxied rule with those qualifiers is applied to all traffic, which is stricter. An inverted
  proxied rule ends the list.
- `regexp:`, `keyword:`, `ext:`, `geosite:x@attr` and negated entries. `full:` is treated as a
  suffix, since dnsmasq has no exact match.

The daemon fingerprints the inputs every 30 s: the shunt node and its rules, the geo files, and the
resolver's upstreams. The shunt's `default_node` is left out of the fingerprint (only whether it is
`_direct` counts), so a failover watchdog that switches nodes, such as [pw-failover](../failover/), doesn't trigger a
recompile. A change
recompiles in the background (about 1.4 s for ~60 000 names), reloads the table if the output
changed, and reloads the service so procd restarts the resolver.

### DNS while engaged

While engaged, chain `dns` (nat, priority `dstnat - 2`, ahead of passwall2's own DNS redirect) sends
every LAN query on port 53 to the killswitch's resolver on `:6053`. It forwards direct-list names to
its upstreams and answers `REFUSED` for everything else. A DNS server in front of the router that
doesn't cache a refusal works again as soon as the gate opens. Old answers it still serves from its
cache while engaged don't get through either: the gate refuses those connections.

The upstreams default to passwall2's own direct DNS: the first two WAN resolvers in
`/tmp/resolv.conf.d/resolv.conf.auto`. passwall2's output chain exempts exactly those, so the
resolver also works while xray is dead but passwall2's rules are loaded. A different `dns_server`
lacks that exemption in that one case.

Between passwall2's stop and the daemon's next check, up to one second, the redirect isn't in place
yet. Queries then reach the forward chain, are refused there, and time out. Nothing leaks.

### The daemon

`pw-killswitch.sh run`, once a second:

1. If `enabled` is `0`, remove the table and the heartbeat, and idle.
2. If the table is missing, rebuild it from `/etc/pw-killswitch/`.
3. Check passwall2: `uci` enabled, `jump PSW2_NAT` in `dstnat`, no `app.sh start` or `app.sh stop`
   running, and the TCP and UDP redirect ports listening. Other `app.sh` runs, such as a URL test or
   a LuCI passwall2 page, don't count.
4. Healthy twice in a row: add any missing heartbeat. Unhealthy once: remove the heartbeat.
5. Armed: DNS redirect off. Engaged: on. Log a line on each change of state.

It follows `enabled` itself, because procd's reload trigger isn't reliable: `reload_config` sends no
event for a config file it hasn't seen since boot.

Stopping the service, or a crashed daemon, leaves the gate as it is. If passwall2 then restarts, the
heartbeat is gone and nothing puts it back, so the house stays engaged until the daemon runs again.
procd respawns it every 5 s.

### The log of refused connections

While `log_refused` is on (*Log refused connections* on the page, the default), the `block` chain
first jumps to chain `record`, which adds each refused packet to set `refused4` or `refused6`, keyed
by source, destination, protocol and port, with a packet counter per key. Only refused packets reach
it, so traffic that is let through pays nothing. In each round where the `blocked` counter moved,
the daemon moves those entries into `/var/run/pw-killswitch/refused`, one row per flow:

```text
<first seen> <last seen> <packets> <armed|engaged> <source> <destination> <proto> <port>
```

- A row is *armed* only when the gate was armed at both ends of the round.
- A flow refused again within 10 minutes extends its row.
- The newest 100 rows of each state are kept, none older than 7 days, about 20 KB at most, so an
  outage can't push out the armed rows. A reboot clears them.
- The router's own refused traffic shows its WAN address as the source.
- Each set holds at most 1024 keys, which expire after an hour if the daemon isn't there to move them.
  A refusal that doesn't fit still happens; it is only not logged.

The page names the sources from LuCI's host hints.

## Settings

uci `/etc/config/pw-killswitch`, section `main`, also on the LuCI page:

| Option | Meaning |
|---|---|
| `enabled` | `1` on, `0` off: the gate and the heartbeat are removed. Stopping the service does not turn it off; this does |
| `dns_server` | optional list: where the resolver sends direct names while engaged. Empty: passwall2's direct DNS. An IP, optionally with `#port` |
| `log_refused` | the log of refused connections; on unless `0` |

## Operations

```sh
/root/scripts/pw-killswitch.sh status         # state, reason, heartbeat, counters, lists, events
/root/scripts/pw-killswitch.sh status 20      # … with 20 events
/root/scripts/pw-killswitch.sh refused 50     # the 50 newest refused connections
/root/scripts/pw-killswitch.sh test 30        # engage for 30 s (5-600) while passwall2 keeps running
/root/scripts/pw-killswitch.sh test-stop
/root/scripts/pw-killswitch.sh compile --force   # rebuild the lists now (the page's *Rebuild lists*)
/root/scripts/pw-killswitch.sh print          # the table `load` would load, for `nft -c -f -`
/root/scripts/pw-killswitch.sh json           # what the LuCI page reads
uci set pw-killswitch.main.enabled=0 && uci commit pw-killswitch   # off within 2 s; =1 is back within 5 s
```

State is in `/var/run/pw-killswitch/` (tmpfs), events also in `logread -e pw-killswitch`.

A test engages the killswitch while passwall2 keeps running. Proxied traffic still flows, but DNS
answers only direct names, and the few connections passwall2 sends direct without them being in the
direct lists are refused. To see the real thing, restart passwall2 while sampling from a LAN host: a
proxied site must stop answering, and never show the ISP's address.

The LuCI page polls `json` every 3 s. The rpcd ACL allows it `json`, `test *`, `test-stop` and
`compile-bg`, uci read and write of `pw-killswitch`, LuCI's host hints, and nothing else.

Measured on my router, with a sampler making one fresh connection every ~0.3 s:

| Event | Proxied | Direct | Engaged for |
|---|---|---|---|
| `/etc/init.d/passwall2 restart` | tunnel exit or refused, never another address | all answered | 7 s |
| `kill -9` of the xray, passwall2 restarted 5 s later | tunnel exit or no answer, never another address | all answered | 16 s |
| `/etc/init.d/passwall2 restart`, sampled on the router itself | tunnel exit or refused, never another address | all answered | 7 s |

## Things that bite

- **The house reaches only direct sites and the page says engaged.** Read the reason. *passwall2 is
  disabled* or *the proxy is not listening* means passwall2 itself is down, and the killswitch is
  doing its job. *passwall2's rules are not loaded* for more than a few seconds, with passwall2
  running, means the daemon can't find `jump PSW2_NAT` in `dstnat`, for example after an upgrade that
  renamed passwall2's chains. Then update `pw2_facts` and `HB_CHAINS` in the script, or turn the
  killswitch off until you have.
- **`blocked` counts up right after an install or a re-enable.** Connections that existed before the
  table loaded carry no label. Those passwall2 sent direct to an address outside the direct lists,
  such as node addresses, are refused once and reconnect. In steady state `blocked` stays at 0 while
  armed.
- **`blocked` grows while armed.** That is traffic that never enters passwall2's chains, so it never
  carries the heartbeat: anything in passwall2's `psw2_direct` that isn't a private range
  (`nft list set inet passwall2 psw2_direct`). passwall2 puts every WAN DNS server there, whole, so
  with `1.1.1.1` as a WAN's DNS, a phone's DoH to `1.1.1.1:443` is refused every few seconds. It
  also means that traffic leaves outside the tunnel while passwall2 is healthy: give each WAN its own
  gateway as DNS instead (see *Things that bite* in the
  [patches write-up](../patches/README.md#things-that-bite)). For packet
  detail, log the refusals for a while (a table reload drops these rules):

  ```sh
  for s in new established related untracked; do
    nft insert rule inet pwks block ct state $s limit rate 30/second burst 300 packets log prefix "\"pwksB $s \"" flags all; done
  logread -e pwksB | tail
  for h in $(nft -a list chain inet pwks block | sed -n "s/.*pwksB.* handle //p"); do nft delete rule inet pwks block handle $h; done
  ```

- **Node addresses while engaged.** passwall2 returns every node address (`psw2_vps`) direct ahead of
  its shunt rules. While armed that traffic carries the heartbeat and passes; while engaged it is
  refused unless the direct lists hold it. Patch 4 of the
  [patches](../patches/README.md#4-lan-traffic-to-a-node-address-leaves-over-the-isp)
  sends LAN traffic to node addresses through the shunt in the first place.
- **IPv6 to the internet is refused even while armed** when passwall2 doesn't proxy IPv6
  (`ipv6_tproxy=0`): no IPv6 packet then carries the heartbeat. Without an IPv6 uplink nothing is
  lost; with one, IPv6 would otherwise bypass the tunnel.
- **An output-hook rule sees the WAN as `oif` for traffic that goes to xray.** In the output hook,
  `oif` is the device of the packet's first route. When passwall2 re-routes the router's UDP to xray
  or redirects its TCP, the packet leaves by loopback, but later output chains still read the WAN.
  So the `output` chain recognises redirected TCP by its `127.0.0.1` destination and tproxied UDP by
  its mark, not by `oif`. Diagnose egress at postrouting.
- **The counters are older than *built*.** *built* is when the lists were last compiled. The counters
  reset only when the table is loaded: at boot, and when a compile changes the lists or the
  resolver's upstreams.
- **The page looks unchanged after an update.** The browser caches the page's script under LuCI's
  own version, which an update doesn't change. Reload with DevTools' *Disable cache* ticked, or clear
  the site's data.
- **Times differ.** The page shows the browser's local time; `status` and `logread` show the router's.

Use at your own risk. Not part of passwall2, and not affiliated with it.
