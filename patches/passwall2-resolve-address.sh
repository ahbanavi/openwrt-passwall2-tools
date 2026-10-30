#!/bin/sh
# passwall2 local patch: a per-subscription checkbox, "Resolve server domains to IPs".
#
# A node whose address is a hostname makes helper_dnsmasq.lua pin that domain, and every name under it,
# to the direct DNS in the LAN dnsmasq (`server=/.example.com/<direct DNS>`), so LAN lookups of those
# names leave over the ISP in cleartext. CDN-fronted nodes often use a big third-party site's domain
# as their address, and then every lookup of that site in the house goes direct. A node whose
# address is an IP gets no pin.
#
# With the box ticked on a subscription, each update replaces such an address by its IPv4 address,
# resolved with the direct DNS passwall2 itself uses for node domains (the first WAN resolvers), so the
# router gets the address it would have used anyway, frozen at import. Before that, an empty SNI or
# transport Host is set to the hostname, so TLS and Host stay as they were, and the hostname is kept in
# the node option `resolved_from`. Left alone: domains a `_direct` rule of the active shunt matches
# (`geosite:` through geoview), protocols other than vless/vmess/trojan/shadowsocks/socks/http, and
# names that resolve to nothing or to a private address (a poisoned answer). After an update,
# passwall2 finds the nodes in use again by address; the patch makes it compare `resolved_from` there,
# so a node keeps its identity when its IP changes.
#
# The IP changes only at the next update that changes the subscription, or at a manual update.
# Why and how: README.md next to this script.
#
# Idempotent. Re-run after every luci-app-passwall2 upgrade, which overwrites both files:
#   ssh root@<router> 'sh -s' < passwall2-resolve-address.sh
# Optional arguments patch other copies (a dry run): sh -s /tmp/x/subscribe.lua /tmp/x/node_subscribe_config.lua
# Then tick the subscriptions in LuCI (or uci set passwall2.<sub>.resolve_address=1) and update them.
S=${1:-/usr/share/passwall2/subscribe.lua}
L=${2:-/usr/lib/lua/luci/model/cbi/passwall2/client/node_subscribe_config.lua}
TAG='local patch (passwall2-resolve-address.sh)'
patched() { grep -qF "$TAG" "$1"; }

if patched "$S" && patched "$L"; then
	echo "already patched"
	exit 0
fi
patched "$S" || cp -p "$S" "$S.pre-resolve-address"
patched "$L" || cp -p "$L" "$L.pre-resolve-address"

# --- subscribe.lua: the helpers, select_node's identity, and the hook in update_node -------------
cat > /tmp/ra-helpers.lua <<'LUA'
-- @TAG@
local _ra = {}
function _ra.id(n) -- a node's identity across updates: its hostname, even once the address is an IP
	return n and (n.resolved_from or n.address)
end
function _ra.bogon(ip)
	local a, b = ip:match("^(%d+)%.(%d+)%.%d+%.%d+$")
	a, b = tonumber(a), tonumber(b)
	if not a or a > 255 or b > 255 then return true end
	return a == 0 or a == 10 or a == 127 or a >= 224 or (a == 100 and b >= 64 and b <= 127)
		or (a == 169 and b == 254) or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
		or (a == 198 and (b == 18 or b == 19))
end
function _ra.servers() -- the direct DNS passwall2 uses for node domains: the first two WAN resolvers
	if _ra.dns then return _ra.dns end
	_ra.dns = {}
	local f = io.open("/tmp/resolv.conf.d/resolv.conf.auto", "r")
	if f then
		local seen = {}
		for ip in f:read("*a"):gmatch("nameserver%s+(%d+%.%d+%.%d+%.%d+)") do
			if not seen[ip] and ip ~= "127.0.0.1" and ip ~= "0.0.0.0" and #_ra.dns < 2 then
				seen[ip] = true
				_ra.dns[#_ra.dns + 1] = ip
			end
		end
		f:close()
	end
	if #_ra.dns == 0 then _ra.dns = { "" } end -- no WAN resolver known: the system resolver
	return _ra.dns
end
function _ra.resolve(host)
	for _, dns in ipairs(_ra.servers()) do
		local out = luci.sys.exec("nslookup -type=A '" .. host .. "' " .. dns .. " 2>/dev/null") or ""
		local named = false
		for line in out:gmatch("[^\r\n]+") do
			if line:match("^Name:") then
				named = true
			elseif named then
				local ip = line:match("^Address:%s*(%d+%.%d+%.%d+%.%d+)%s*$")
				if ip and not _ra.bogon(ip) then return ip end
			end
		end
	end
end
function _ra.direct(host) -- does a `_direct` rule of the active shunt match this name?
	if not _ra.rules then
		_ra.rules = { entries = {}, cats = {} }
		local gnode = uci_get("@global[0]", "node")
		if gnode and uci_get(gnode, "protocol") == "_shunt" then
			uci_foreach("shunt_rules", function(r)
				if uci_get(gnode, r[".name"]) == "_direct" then
					for line in (r.domain_list or ""):gmatch("[^\r\n]+") do
						line = line:gsub("^%s+", ""):gsub("%s+$", ""):lower()
						if line ~= "" and line:sub(1, 1) ~= "#" then
							if line:sub(1, 8) == "geosite:" then
								_ra.rules.cats[line:sub(9):upper()] = true
							else
								table.insert(_ra.rules.entries, line)
							end
						end
					end
				end
			end)
		end
	end
	for _, e in ipairs(_ra.rules.entries) do
		local kind, v = e:match("^(%a+):(.+)$")
		if not kind then kind, v = "keyword", e end
		if (kind == "full" and host == v) or (kind == "domain" and (host == v or host:sub(-#v - 1) == "." .. v))
			or (kind == "keyword" and host:find(v, 1, true)) then
			return true
		end
	end
	if next(_ra.rules.cats) then
		local dir = (uci_get("@global_rules[0]", "v2ray_location_asset") or "/usr/share/v2ray/"):gsub("/+$", "")
		local out = luci.sys.exec("geoview -type geosite -action lookup -input '" .. dir .. "/geosite.dat' -value '" .. host .. "' 2>/dev/null") or ""
		for cat in out:gmatch("%S+") do
			if _ra.rules.cats[cat:upper()] then return true end
		end
	end
	return false
end
local _ra_host_field = { ws = "ws_host", httpupgrade = "httpupgrade_host", xhttp = "xhttp_host", splithttp = "xhttp_host" }
local _ra_protocols = { vless = true, vmess = true, trojan = true, shadowsocks = true, socks = true, http = true }
function _ra.apply(node, group)
	local host = (node.address or ""):lower()
	if host == "" or host == "engage.cloudflareclient.com" or datatypes.ipaddr(host) or not datatypes.hostname(host) then return end
	if not _ra_protocols[node.protocol or ""] or _ra.direct(host) then return end
	local ip = _ra.resolve(host)
	if not ip then
		log(1, "[" .. group .. "] " .. (node.remarks or "") .. ": " .. host .. " does not resolve to a public IPv4, address kept")
		return
	end
	if (node.tls == "1" or node.reality == "1") and (node.tls_serverName or "") == "" and node.tls_disable_sni ~= "1" then
		node.tls_serverName = host
	end
	local hf = _ra_host_field[node.transport or ""]
	if hf and (node[hf] or "") == "" then node[hf] = host end
	if (node.transport == "h2" or node.transport == "http") and node.http_host == nil then node.http_host = { host } end
	if node.tcp_guise == "http" and node.tcp_guise_http_host == nil then node.tcp_guise_http_host = { host } end
	node.address = ip
	node.resolved_from = host
end

LUA
sed -i "s|@TAG@|$TAG: per-subscription \"Resolve server domains to IPs\"|" /tmp/ra-helpers.lua

awk -v helpers=/tmp/ra-helpers.lua -v q="'" '
	function rep(old, new,   i, n) {  # literal replace in $0, returns the count
		n = 0
		while ((i = index($0, old)) > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); n++ }
		return n
	}
	BEGIN {
		c = q ":" q
		o1 = "node.address .. " c " .. node.port == config.currentNode.address .. " c " .. config.currentNode.port"
		n1 = "_ra.id(node) .. " c " .. node.port == _ra.id(config.currentNode) .. " c " .. config.currentNode.port"
		o2 = "node.address == config.currentNode.address"
		n2 = "_ra.id(node) == _ra.id(config.currentNode)"
	}
	{ t = $0; sub(/^[ \t]+/, "", t) }
	t ~ /^local function select_node\(/ {
		while ((getline line < helpers) > 0) print line
		h++; insel = 1
	}
	insel && $0 ~ /^local function / && t !~ /^local function select_node\(/ { insel = 0 }   # next top-level function
	insel { ids += rep(o1, n1); ids += rep(o2, n2) }
	t ~ /^local function update_node\(/ { inupd = 1 }
	inupd && $0 ~ /^local function / && t !~ /^local function update_node\(/ { inupd = 0 }   # nested ones are indented
	inupd && t == "local cfgid = uci:section(c_config, \"nodes\", api.gen_random_char())" {
		ind = $0; sub(/[^ \t].*$/, "", ind)
		print ind "if sub_cfg and sub_cfg.resolve_address == \"1\" then _ra.apply(vv, remark or \"\") end -- local patch"
		hook++
	}
	{ print }
	END {
		if (h != 1 || ids != 4 || hook != 1) {
			printf "anchors: helpers %d, select_node comparisons %d (want 4), update_node hook %d\n", h, ids, hook > "/dev/stderr"
			exit 1
		}
	}
' "$S.pre-resolve-address" > "$S.new" || { rm -f "$S.new" /tmp/ra-helpers.lua; echo "subscribe.lua: anchors not found, passwall2 changed; nothing patched" >&2; exit 1; }
rm -f /tmp/ra-helpers.lua

# --- node_subscribe_config.lua: the checkbox, just above "Domain DNS Resolve" --------------------
awk -v tag="$TAG" '
	index($0, "o = s:option(ListValue, \"domain_resolver\", translate(\"Domain DNS Resolve\"))") == 1 {
		print "-- " tag
		print "o = s:option(Flag, \"resolve_address\", translate(\"Resolve server domains to IPs\"))"
		print "o.description = translate(\"On every update, a node address that is a domain name is replaced by its IPv4 address, resolved with the direct DNS. \" .."
		print "\t\"An empty SNI or transport Host is set to the domain first, and the domain is kept as resolved_from. \" .."
		print "\t\"Without this, passwall2 sends that domain and every name under it to the direct DNS for all LAN clients. \" .."
		print "\t\"Domains the active shunt sends direct are left as they are. The IP only changes at the next update.\")"
		print "o.default = \"0\""
		print ""
		n++
	}
	{ print }
	END { if (n != 1) { print "anchor \"Domain DNS Resolve\" not found" > "/dev/stderr"; exit 1 } }
' "$L.pre-resolve-address" > "$L.new" || { rm -f "$S.new" "$L.new"; echo "node_subscribe_config.lua: anchor not found; nothing patched" >&2; exit 1; }

if lua -e "assert(loadfile('$S.new'))" && lua -e "assert(loadfile('$L.new'))" 2>/dev/null; then
	chmod 644 "$S.new" "$L.new"
	mv "$S.new" "$S"
	mv "$L.new" "$L"
	rm -f /tmp/luci-indexcache* && rm -rf /tmp/luci-modulecache
	echo "patched (originals kept as *.pre-resolve-address)"
else
	rm -f "$S.new" "$L.new"
	echo "a patched file does not parse; nothing changed" >&2
	exit 1
fi
