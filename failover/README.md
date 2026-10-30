# pw-failover — passwall2 node and WAN failover for OpenWrt

A small watchdog for an OpenWrt router that runs [passwall2](https://github.com/xiaorouji/openwrt-passwall2)
with xray. When the tunnel dies it moves passwall2 to another node, chosen by a real URL test. When
the primary WAN dies it moves all egress to a backup WAN. After recovery it sends one Telegram
report, and once the primary is healthy again it switches back by itself.

It is one busybox `ash` script plus a procd service, with optional LuCI pages (*Network ▸ Failover*)
and a card on *Status ▸ Overview*. It needs no mwan3, no extra packet marks and no `ip rule`s.

Related, in this repo: [pw-killswitch](../killswitch/), which keeps traffic from leaving outside the
tunnel while passwall2 is down, and [five local patches](../patches/) for leaks a healthy passwall2
still has.

## What it does

- **Detect.** Every 20 s (`PROBE_INTERVAL`) it fetches Cloudflare's `/cdn-cgi/trace` through the
  running xray's SOCKS port, with `ifconfig.co` as a second opinion.
  - Set `EXPECT_EXIT_IPS` to your tunnel's exit address. A probe then passes only on that address,
    and any other one counts as a failure. That catches traffic that still works but silently
    leaves outside the tunnel.
  - Without it, `PROBE_BAD_LOC` can reject your direct exit's country instead.
  - Failed probes are retried 5 s apart, and three in a row open an incident.
  - If two nodes in a row show the same wrong exit, the watchdog treats it as a routing problem,
    not a node problem, and stops switching nodes.
- **Pick a WAN.** It tries the WANs in this order:
  - the primary, which it never bounces;
  - the backups that are already up, in `WAN_ORDER` order;
  - the backups that are down, which it raises with `ifup` as a last resort, whatever their `auto`
    setting.

  So a spare LTE modem that is already up is tried before a backup further down the list, and one
  that is down is raised only when everything else has failed. The watchdog lowers it again
  afterwards, and only if it raised it.

  A WAN is up when it passes the *direct check*, run bound to its device:
  - an optional IP-echo URL (`DIRECT_CHECK_URL`) that passwall2 routes direct, which also shows that
    line's public IP;
  - otherwise a ping of `WAN_TARGETS`. ICMP never enters passwall2.

  Use targets on passwall2's direct list. A backup carries traffic through a single
  `default via <gw> dev <dev> metric 0 proto 201` route, which beats the primary's metric. netifd
  ignores that route, and a reboot clears it.
- **Pick a node.** The running node goes first. If it passes its own URL test, the fault is inside
  passwall2, and a restart fixes it. Otherwise the watchdog tests `PRIMARY_NODE`, then every node
  in `TIER1_GROUP` (optionally only some ports, e.g. `443,2083`), then `TIER2_GROUP`, in LuCI
  order, then the `TIER3_NODES` you name, in the order listed. It uses the first that passes, then
  restarts and verifies. If no node works over a WAN that still pings, the next WAN gets the same
  chain.
- **Choose the URL test.** It runs passwall2's own `test.sh url_test_node`, the same test as the
  LuCI *URL Test* button. passwall2 puts every node address in `psw2_vps` and marks xray's sockets
  255, so the test reaches the node directly even while the running tunnel is dead.
- **Report.** When the tunnel works again it sends one Telegram message covering the whole outage.
  It opens with what broke, in plain words:
  - **TOTAL OUTAGE on wan:** the primary's direct internet was down too. Direct means a ping bound
    to the WAN's device; ICMP never enters passwall2.
  - **Tunnel outage on wan:** the line was fine, but no tunnel node worked over it.
  - **Node outage:** the line was fine, and only the running node failed.
  - **passwall2 fault:** the line and the node were both fine, and a restart fixed it.

  The message then holds:
  - a direct-then-tunnel verdict for every WAN it walked;
  - the WAN and node before and after;
  - every URL test with its milliseconds or `timeout`;
  - the timeline, the exit IP, and when the switch-back is due.

  The message goes out through the tunnel. Unsent reports are queued on disk and retried.
- **Switch back.** While on a fallback node, it URL-tests the primary every 5 min and switches back
  after 6 passes. While on a backup WAN, it pings the primary every minute and switches back once
  the primary has answered for 5 min. The WAN switch-back also returns to the primary node, since a
  fallback picked over the backup may not work over the primary WAN. That wait is 30 min if the
  primary was left because no node worked over it. A switch-back that fails verification is rolled
  back, and the wait doubles.
- **Stay safe.**
  - It refuses pseudo-nodes and your `DENY_NODES`/`DENY_ADDRS`. A node behind a pre-proxy
    (passwall2's chain proxy) is matched on the pre-proxy's address, the one the router dials.
  - It probes once more before its first change, so a tunnel that recovered by itself costs no
    restart.
  - It makes at most 6 restarts per incident, and runs at most 3 incidents an hour.
  - It backs off when nothing works: 5, 10, 20, then 30 min.
  - It respects a node you pick by hand.
  - It waits out other tools' restart locks (`EXTRA_LOCKS`).
  - It does nothing while mwan3 is enabled.

### Manual override

The manual override pins the egress WAN, the tunnel node, or both, so traffic goes through them
until you clear it or it expires. Set it with *Manual override…* on the *Status* tab, or with
`pw-failover.sh manual <wan|-> <node|-> [minutes] [hold]` (`-` leaves that part automatic,
`minutes` 0 means until cleared). It keeps the router on a WAN or node the watchdog would otherwise
leave, without pausing the watchdog or switching it to `observe`.

Setting it moves traffic at once: a pinned backup WAN gets the watchdog's metric-0 route (raised
with `ifup` first if it is down; without a lease within `WAN_UP_WAIT` nothing changes), a pinned
node becomes the egress node, and if either changed, passwall2 restarts once and the tunnel is
verified.

While it holds:

- A pinned part is never switched back.
- An incident looks for a fix only inside the pin:

  | Pinned | An incident tries |
  |---|---|
  | WAN | that WAN alone, with the whole node chain |
  | node | that node alone, over every WAN in the usual order |
  | both | a passwall2 restart, if the node still passes its URL test |

- If nothing works inside the pin, it is dropped and the incident walks again as usual, unless it
  was set to `hold`: then the router stays down until the pin works again, expires or is cleared.
- The pin outlives a reboot. If the pinned WAN's route goes missing, the watchdog puts it back at
  the next healthy check, with one passwall2 restart.
- A `default_node` changed by hand ends the node pin. `revert` and `manual-clear` end the override.

### Why not mwan3

mwan3 marks packets within `mmx_mask`, which is `0x3F00` by default. passwall2 routes tproxied
packets with an exact-match rule, `fwmark 0x50535732 lookup 999`, and `0x50535732` has bits inside
`0x3F00`. Once mwan3 has touched a packet's mark, that rule no longer matches, and tproxy breaks in
ways that are hard to see. Moving the default route sidesteps the whole mark space.

## Requirements

- OpenWrt with busybox `ash`, `curl`, `jsonfilter`, `ip-full`, `flock`, `setsid`, and `timeout`
  (busybox or `coreutils-timeout`).
- passwall2 with xray, and its global node set to a node or a shunt. With a shunt, the shunt's
  `default_node` is the one switched.
- Tested on OpenWrt 25.12.6 with `luci-app-passwall2` 26.10.20-r1 and `xray-core` 26.10.21-r1, and
  earlier on OpenWrt 24.10 with passwall2 26.10.1 and xray 26.9.30.

## Files

| File | Install as |
|---|---|
| `pw-failover.sh` | `/root/scripts/pw-failover.sh`, mode 700 |
| `pw-failover.conf.example` | `/root/scripts/pw-failover.conf`. Edit it first, or move it into uci for the LuCI Settings tab (below) |
| `pw-failover.init` | `/etc/init.d/pw-failover`, mode 755 |
| `pw-failover-drill.sh` | not installed; run over SSH (see [Drills](#drills)) |
| `luci/menu.json` | `/usr/share/luci/menu.d/luci-app-pw-failover.json` (optional LuCI pages) |
| `luci/acl.json` | `/usr/share/rpcd/acl.d/luci-app-pw-failover.json` |
| `luci/status.js` | `/www/luci-static/resources/view/pw-failover/status.js` |
| `luci/settings.js` | `/www/luci-static/resources/view/pw-failover/settings.js` |
| `luci/overview.js` | `/www/luci-static/resources/view/status/include/35_pw_failover.js` (Status ▸ Overview card) |
| `/etc/pw-failover/telegram.env` | yours, mode 600: `TELEGRAM_BOT_TOKEN='…'` and `TELEGRAM_CHAT_ID='…'` |

## Install

Dropbear ships no `sftp-server`, so `scp` fails. Pipe through `cat` instead, from this directory:

```bash
R=root@192.168.1.1   # your router
ssh $R 'mkdir -p /root/scripts /etc/pw-failover && chmod 700 /etc/pw-failover'
ssh $R 'cat > /root/scripts/pw-failover.sh && chmod 700 /root/scripts/pw-failover.sh' < pw-failover.sh
ssh $R 'cat > /root/scripts/pw-failover.conf' < pw-failover.conf.example
ssh $R 'cat > /etc/init.d/pw-failover && chmod 755 /etc/init.d/pw-failover' < pw-failover.init
printf "TELEGRAM_BOT_TOKEN='%s'\nTELEGRAM_CHAT_ID='%s'\n" "$TOKEN" "$CHAT" \
  | ssh $R 'umask 077; cat > /etc/pw-failover/telegram.env'
ssh $R '/etc/init.d/pw-failover enable && /etc/init.d/pw-failover start'
```

Find the node ids and groups for the config:

```bash
ssh $R "uci show passwall2 | grep -E '=nodes$|\.(remarks|group|port)='"
```

Keep it in the sysupgrade backup, since `/etc/init.d` and `/etc/pw-failover` are not backed up by
default:

```bash
ssh $R 'for f in /root/scripts /etc/init.d/pw-failover /etc/rc.d/S99pw-failover /etc/pw-failover/telegram.env; do
  grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf; done'
```

Start with `MODE=observe`. It runs every probe and test, and logs and reports what it would do,
but changes nothing. Then run `test-nodes` and `test-telegram`, and switch to `MODE=act`. The
config is re-read every loop.

To update the script later, write a new file and rename it (`cat > pw-failover.sh.new && mv -f …`)
rather than rewriting it under the running daemon.

### LuCI pages (optional)

*Network ▸ Failover* has two tabs. *Status* shows the live state: the WAN links with their direct
health, the tunnel node and probe, an outage's cause and timeline while it is open, the last
reports and the last URL-test run. It also has buttons for *Retest now*, *Run URL tests*, *Return to
primary*, *Manual override…*, *Pause/Resume* and *Send test message*. *Settings* edits every setting,
with help on each field, pickers for passwall2's nodes and groups, and a preview of the failover
chain. The ACL file allows the pages only those command lines, uci reads, and uci writes to
`pw-failover`.

```bash
ssh $R 'mkdir -p /www/luci-static/resources/view/pw-failover /www/luci-static/resources/view/status/include'
ssh $R 'cat > /usr/share/luci/menu.d/luci-app-pw-failover.json' < luci/menu.json
ssh $R 'cat > /usr/share/rpcd/acl.d/luci-app-pw-failover.json' < luci/acl.json
ssh $R 'cat > /www/luci-static/resources/view/pw-failover/status.js' < luci/status.js
ssh $R 'cat > /www/luci-static/resources/view/pw-failover/settings.js' < luci/settings.js
ssh $R 'cat > /www/luci-static/resources/view/status/include/35_pw_failover.js' < luci/overview.js
ssh $R 'rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache; /etc/init.d/rpcd reload'
```

Add the five paths to `/etc/sysupgrade.conf` too.

The *Settings* tab edits uci, not the `.conf` file. Move the settings there once:

```bash
ssh $R '/root/scripts/pw-failover.sh conf-to-uci && /etc/init.d/pw-failover restart'
```

From then on the script reads only `/etc/config/pw-failover` and ignores `pw-failover.conf`.
*Save & Apply* takes effect at once: the init script's reload trigger signals the daemon, which
re-reads its settings without a restart and logs each one that changed. Over SSH, the option is the
variable's name in lower case, and the lists take one `uci add_list` per value:

```bash
uci set pw-failover.main.probe_interval=30 && uci commit pw-failover && /etc/init.d/pw-failover reload
```

A value of the wrong shape, such as a word in a number field, is ignored with a log line and its
default is used.

## Use

```bash
/root/scripts/pw-failover.sh status [lines]   # mode, last probe, egress WAN, node, log tail
/root/scripts/pw-failover.sh test-nodes       # URL-test the whole chain, change nothing
/root/scripts/pw-failover.sh test-telegram
/root/scripts/pw-failover.sh pause [min]      # before hand edits to passwall2 or the WANs; default 30, 0 = until resumed
/root/scripts/pw-failover.sh resume
/root/scripts/pw-failover.sh revert           # back to the primary WAN and node now; ends a manual override
/root/scripts/pw-failover.sh manual wan2 - 60 # pin the egress WAN for an hour, node stays automatic
/root/scripts/pw-failover.sh manual-clear
/root/scripts/pw-failover.sh retest           # wake the daemon: every pending check runs now
/root/scripts/pw-failover.sh json             # the status as JSON (what the LuCI page reads)
/root/scripts/pw-failover.sh conf             # the settings in effect, and where they come from
/root/scripts/pw-failover.sh reload           # re-read the settings now
```

The log is `/var/run/pw-failover/log`. Key events also reach syslog
(`logread -e pw-failover`).

## With pw-killswitch

The two run side by side. While the [killswitch](../killswitch/) is engaged, the watchdog's probes
still work, since they go through xray, whose sockets always pass. `DIRECT_CHECK_URL` must be on
the shunt's direct list anyway, and then it passes the gate too; the `WAN_TARGETS` pings always pass,
since the killswitch gates only TCP and UDP. Telegram reports wait in the queue until passwall2 is
back. The killswitch ignores `default_node` changes, so a node switch doesn't make it recompile its
lists.

## Drills

`pw-failover-drill.sh` breaks things on purpose. It refuses to run unless the watchdog is in `act`
mode, healthy, and on the primary WAN and node.

```bash
ssh $R sh -s -- node 12 < pw-failover-drill.sh   # drop the primary node's first hop (its pre-proxy, if any)
ssh $R sh -s -- wan 10  < pw-failover-drill.sh   # drop everything on the primary WAN's device
ssh $R sh -s -- clear   < pw-failover-drill.sh   # end it now
```

A drill really takes your internet down until the watchdog recovers it. Arm it, then wait without
other network calls. Three dead-mans lift the block, and none needs SSH:

1. The nft set elements carry a kernel timeout.
2. A `setsid` sleep deletes the table shortly after.
3. A reboot clears it.

While the drill marker is up, reports are tagged `[DRILL]` and the switch-back holds are short.
Measured on the author's router:

| Drill | Outage |
|---|---|
| Node drill: the primary node and both other tier-1 nodes timed out, and the first tier-2 node passed | about 2.5 min, before detection was tightened to about 45 s |
| WAN drill: an `auto 0` backup WAN was raised, and the node chain re-run over it | about 1.7 min |

## Things that bite

- **Background jobs under rpcd.** Under rpcd's `file exec`, which is how LuCI runs commands, a
  plain `cmd &` keeps the call open until rpcd times out, even with every descriptor redirected.
  Background jobs need the double fork `( setsid cmd … & )`.
- **No reload.** passwall2 has no reload, so every node switch is a full restart and a 5–15 s blip
  for the whole LAN. Without a restart after a route change, xray's open sockets keep the old
  source address and stall for minutes. `RESTART_ON_WAN_CHANGE=1` trades that for one restart.
- **passwall2's stop kills by pattern.** It kills anything whose command line contains `passwall2/`
  and any `sleep 6s|9s|58s`. Keep the script out of such paths, and don't use those sleeps.
- **Hotplug restarts.** passwall2's iface hotplug restarts it on `ifup` of the device that holds the
  default route. A backup raised while the primary still holds the route does not trigger it.
- **Run the restart detached.** The restart runs under `setsid`, so stopping the service mid-restart
  cannot leave the LAN without a proxy.
- **IPv4 only.** With an IPv6 default route, the override route does not cover it.
- **Link state lies.** If OpenWrt runs in a container, its veths keep carrier when the physical
  link dies. That is why WAN health is a ping, not link state.
- **The page looks unchanged after an update.** The browser caches the page's script under LuCI's
  own version, which an update doesn't change. Reload with DevTools' *Disable cache* ticked.
