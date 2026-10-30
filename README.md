# openwrt-passwall2-tools

Tools for an OpenWrt router that runs [passwall2](https://github.com/xiaorouji/openwrt-passwall2)
with xray. Each one stands alone; together they cover a tunnel that is healthy, one that is down,
and the switch between them.

| Tool | What it does |
|---|---|
| [`failover/`](failover/) | **pw-failover**, a watchdog: when the tunnel dies it moves passwall2 to another node by real URL test, when the WAN dies it moves egress to a backup WAN, sends one Telegram report, and switches back by itself. LuCI pages included |
| [`killswitch/`](killswitch/) | **pw-killswitch**: while passwall2 is stopped, restarting or its proxy is down, TCP and UDP from the LAN and the router reach only the shunt's direct lists, and LAN DNS answers only direct names. No gap during a restart. LuCI page included |
| [`patches/`](patches/) | **five local patches** to passwall2's own files: non-A DNS and reused-UDP-socket leak fixes, `force_proxy_lan_ip` brought back, MASQUE XMUX, and resolving subscription hostnames to IPs. Plus a probe for the UDP leak |

How they fit:

- The **patches** close leaks that a *healthy* passwall2 still has: DNS types, UDP sockets, node
  addresses and node hostnames that leave over the ISP.
- The **killswitch** covers the time passwall2 is *not* healthy, so nothing leaves outside the
  tunnel while it restarts or its proxy is dead.
- **pw-failover** keeps that time short, by finding a node and a WAN that work.

## Tested on

OpenWrt 25.12.6 (x86_64, apk), `luci-app-passwall2` 26.10.20-r1, `xray-core` 26.10.21-r1, the
nftables backend (`use_nft=1`). pw-failover also ran on OpenWrt 24.10 with passwall2 26.10.1.

Every script lives in `/root/scripts/` on the router. Each tool's README has its install steps,
settings, and the things that bite. A passwall2 upgrade overwrites the patches; re-run them after
every upgrade ([patches/README.md](patches/README.md#after-every-passwall2-upgrade)).

## License

[MIT](LICENSE). Use at your own risk. Not part of passwall2, and not affiliated with it.
