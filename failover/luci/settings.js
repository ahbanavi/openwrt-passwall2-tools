'use strict';
'require view';
'require form';
'require fs';
'require uci';

/*
 * Network ▸ Failover ▸ Settings — every pw-failover setting, as the uci section pw-failover.main.
 * Installs as /www/luci-static/resources/view/pw-failover/settings.js.
 *
 * Save & Apply commits /etc/config/pw-failover, and the init script's reload trigger makes the
 * daemon re-read it at once (`pw-failover.sh reload`), without a restart. An empty field means the
 * script's own default, which `pw-failover.sh defaults` supplies: as the placeholder, and in each
 * field's help line with its uci option name.
 */

const SCRIPT = '/root/scripts/pw-failover.sh';
const CONF = 'pw-failover';

// node_allowed() in pw-failover.sh, before the deny lists: pseudo-nodes never run
function real(n) {
	return !!n.protocol && n.protocol.charAt(0) !== '_';
}

function nodeLabel(n) {
	return '%s (%s%s:%s)%s'.format(n.remarks || n['.name'], n.group ? n.group + ', ' : '',
		n.address || '?', n.port || '?', !real(n) ? ' — ' + _('never used: %s').format(n.protocol || '?') : '');
}

// node_dial_addr() in pw-failover.sh: the pre-proxy (passwall2's chain_proxy 1) a node rides, if
// it still exists; the router dials that node's address instead of the node's own
function preproxy(n) {
	const p = n.chain_proxy === '1' && n.preproxy_node ? uci.get('passwall2', n.preproxy_node) : null;
	return p && p['.type'] === 'nodes' ? p : null;
}

function dialAddr(n) {
	const p = preproxy(n);
	return p ? p.address : n.address;
}

// port_in() in pw-failover.sh: a tier's ports, comma-separated; none means any port
function ports(v) {
	return (v || '').split(/[\s,]+/).filter(function(p) { return p !== ''; });
}

// node_chain() in pw-failover.sh, over the saved settings: primary, then tier 1, then tier 2,
// then the last tier's named nodes
function chain(nodes) {
	const get = function(o) { return uci.get(CONF, 'main', o) || ''; };
	const deny = L.toArray(uci.get(CONF, 'main', 'deny_nodes')), denyAddr = L.toArray(uci.get(CONF, 'main', 'deny_addrs'));
	const tier3 = L.toArray(uci.get(CONF, 'main', 'tier3_nodes'));
	const out = [];
	const add = function(n, tier) {
		if (n && real(n) && deny.indexOf(n['.name']) < 0 && denyAddr.indexOf(dialAddr(n)) < 0 &&
		    !out.some(function(c) { return c.node === n; }))
			out.push({ node: n, tier: tier });
	};
	const byId = function(id) { return nodes.filter(function(n) { return n['.name'] === id; })[0]; };
	add(byId(get('primary_node')), _('primary'));
	[ 1, 2 ].forEach(function(t) {
		const g = get('tier%d_group'.format(t)), p = ports(get('tier%d_port'.format(t)));
		if (g) nodes.forEach(function(n) { if (n.group === g && (!p.length || p.indexOf(n.port) >= 0)) add(n, _('tier %d').format(t)); });
	});
	tier3.forEach(function(id) { add(byId(id), _('tier 3')); });
	return out;
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(SCRIPT, [ 'defaults' ]).then(function(r) { return JSON.parse(r.stdout).values; }), {}),
			L.resolveDefault(uci.load(CONF), null),
			uci.load('passwall2'),
			uci.load('network'),
			uci.load('system')
		]);
	},

	render: function(data) {
		const defs = data[0] || {};
		const host = uci.get('system', '@system[0]', 'hostname') || 'OpenWrt';
		const nodes = uci.sections('passwall2', 'nodes');
		const groups = nodes.map(function(n) { return n.group; })
			.filter(function(g, i, a) { return g && a.indexOf(g) === i; }).sort();
		const wans = uci.sections('network', 'interface').map(function(s) { return s['.name']; })
			.filter(function(n) { return n !== 'loopback' && n !== 'lan'; });

		if (!uci.get(CONF, 'main'))
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', _('Failover settings')),
				E('div', { 'class': 'alert-message warning' }, [
					E('p', _('The watchdog does not read its settings from uci yet: it uses pw-failover.conf beside the script.')),
					E('p', [ _('Move them here once with '), E('code', SCRIPT + ' conf-to-uci'), _(', then reload this page.') ])
				])
			]);

		const m = new form.Map(CONF, _('Failover settings'),
			_('Every setting of the pw-failover watchdog, kept in /etc/config/pw-failover. Save & Apply takes effect at once, without restarting the watchdog (so its startup grace does not start over), and the Status tab\'s log records each change as <em>settings changed: KEY old → new</em>. An empty field uses the default shown in grey and in its help line.'));
		const s = m.section(form.NamedSection, 'main', 'settings');
		s.addremove = false;
		s.tab('general', _('General'), _('Whether the watchdog acts or only watches, and how its reports are titled.'));
		s.tab('nodes', _('Nodes'), _('When the tunnel fails, the watchdog builds a chain of nodes: the primary, then tier 1, then tier 2, each in passwall2\'s node order and read fresh at every incident, so new nodes join on their own, then the last tier\'s named nodes. It URL-tests them one by one over the current WAN (passwall2\'s own URL Test, on a throwaway xray), makes the first that passes the active node, restarts passwall2 and checks the tunnel\'s exit again.'));
		s.tab('wans', _('WANs'), _('A failed probe could be the tunnel or the line. So the watchdog first checks each WAN\'s direct internet, outside passwall2, and runs the node chain only over a WAN that has it. Moving to a backup WAN is a single default route with metric 0, which beats the primary\'s; no marks and no ip rules, so nothing collides with passwall2. It disappears on switch-back or reboot.'));
		s.tab('probe', _('Detection'), _('Every probe fetches Cloudflare\'s trace page through the running xray\'s SOCKS port and checks the exit address it reports, with ifconfig.co as a second opinion; either one passing is enough. A dead tunnel is noticed after about one probe interval plus failures × (11 s + failed-probe interval): with 60 s, 5 s and 3, between 35 s and 95 s.'));
		s.tab('switchback', _('Switch-back'), _('While on a fallback node or a backup WAN, the watchdog keeps testing the primary and returns to it by itself, with a Telegram report. A switch-back is verified like a failover; one that fails verification is rolled back, and the next attempt waits twice as long, up to the longest wait.'));
		s.tab('limits', _('Limits'), _('Brakes for a tunnel that keeps failing, so the watchdog does not restart passwall2 over and over. Every restart drops the LAN\'s proxied traffic for 5–15 s.'));

		// Each help line ends with the script's default and the uci option, for edits over SSH.
		const opt = function(tab, cls, name, title, descr, defText) {
			const def = defs[name.toUpperCase()];
			const tail = [];
			if (defText) tail.push(_('Default: %s.').format(defText));
			else if (def != null && def !== '') tail.push(_('Default: %s.').format('<code>%h</code>'.format(def)));
			tail.push(_('uci option %s').format('<code>%h</code>'.format(name)));
			return s.taboption(tab, cls, name, title, (descr ? descr + '<br />' : '') + '<span style="opacity:.75">' + tail.join(' · ') + '</span>');
		};
		const num = function(tab, name, title, descr, min) {
			const o = opt(tab, form.Value, name, title, descr);
			o.datatype = min != null ? 'and(uinteger,min(%d))'.format(min) : 'uinteger';
			o.placeholder = defs[name.toUpperCase()] || '';
			return o;
		};
		const list = function(tab, name, title, descr, datatype, defText) {
			const o = opt(tab, form.DynamicList, name, title, descr, defText);
			if (datatype) o.datatype = datatype;
			o.placeholder = defs[name.toUpperCase()] || '';
			return o;
		};
		let o;

		// --- General
		o = opt('general', form.ListValue, 'mode', _('Mode'),
			_('<strong>Act</strong> switches routes and nodes and restarts passwall2. <strong>Observe only</strong> runs every probe, direct check and URL test, then logs and reports what it would have done, tagged [OBSERVE], and changes nothing. Start a new setup in observe, read the log and the URL tests on the Status tab, then switch to act. To stop the watchdog entirely instead, for a set time or until you resume it, use Pause… on the Status tab; a pause stops act and observe mode alike.'));
		o.value('act', _('Act'));
		o.value('observe', _('Observe only'));
		o.default = defs.MODE || 'observe';

		o = opt('general', form.Value, 'report_name', _('Report name'),
			_('In the title of every Telegram report and test message, so reports from more than one router can be told apart.'),
			_('the router\'s hostname'));
		o.placeholder = host;

		// --- Nodes
		o = opt('nodes', form.ListValue, 'primary_node', _('Primary node'),
			_('The node that normally carries the traffic: the first one an incident tries, and the target of every switch-back, URL-tested on the Switch-back tab\'s schedule while a fallback is active. Changing it moves no traffic by itself: the next failover, switch-back or Return to primary uses it. The watchdog sets it as passwall2\'s global node, or as the shunt\'s default node when the global node is a shunt.'),
			_('none; required'));
		o.rmempty = false;
		nodes.filter(real).forEach(function(n) { o.value(n['.name'], nodeLabel(n)); });
		const cur = uci.get(CONF, 'main', 'primary_node');
		if (cur && !nodes.some(function(n) { return n['.name'] === cur && real(n); }))
			o.value(cur, _('%s (not a usable passwall2 node)').format(cur));

		[ 1, 2 ].forEach(function(t) {
			o = opt('nodes', form.Value, 'tier%d_group'.format(t), _('Tier %d group').format(t), t === 1
				? _('First fallback tier: the nodes whose Group (in passwall2\'s node list) is this, in passwall2\'s order. A node added to the group later joins the tier at the next incident.')
				: _('Second fallback tier, tried only after every tier 1 node has failed, the same way.'),
				_('none (no tier %d)').format(t));
			o.value('', _('— none —'));
			groups.forEach(function(g) { o.value(g); });

			o = opt('nodes', form.Value, 'tier%d_port'.format(t), _('Tier %d ports').format(t),
				_('Only the group\'s nodes on one of these ports, comma-separated, e.g. 443 or 443,2083, to leave out nodes on ports a line blocks.'),
				_('any port'));
			o.validate = function(id, v) {
				return !v || (/^\d+( *, *\d+)*$/.test(v) && ports(v).every(function(p) { return +p >= 1 && +p <= 65535; }))
					|| _('Expecting ports from 1 to 65535, separated by commas');
			};
			o.placeholder = _('any');
		});

		o = opt('nodes', form.DynamicList, 'tier3_nodes', _('Last tier: these nodes'),
			_('Tried one by one, in this order, after every tier 2 node has failed. Name nodes here that are in no tier\'s group. Drag to reorder.'),
			_('none'));
		nodes.filter(real).forEach(function(n) { o.value(n['.name'], nodeLabel(n)); });
		L.toArray(uci.get(CONF, 'main', 'tier3_nodes')).forEach(function(id) {
			if (!nodes.some(function(n) { return n['.name'] === id; }))
				o.value(id, _('%s (no longer in passwall2)').format(id));
		});

		o = opt('nodes', form.MultiValue, 'deny_nodes', _('Never use these nodes'),
			_('Never picked in an incident, not even when it is the primary, whatever the tiers match: for nodes that must stay out of failover, such as one that exits somewhere else. Pseudo-nodes (shunt, balancing) are always skipped, so they need no entry here.'),
			_('none'));
		o.display_size = 6;
		nodes.forEach(function(n) { o.value(n['.name'], nodeLabel(n)); });
		// keep ids of deleted nodes visible, or the next Save would drop them without a word
		L.toArray(uci.get(CONF, 'main', 'deny_nodes')).forEach(function(id) {
			if (!nodes.some(function(n) { return n['.name'] === id; }))
				o.value(id, _('%s (no longer in passwall2)').format(id));
		});

		list('nodes', 'deny_addrs', _('Never use these addresses'),
			_('A node whose server address is exactly one of these, as written in the node (an IP or a host name), is never selected, whatever its group. For example the tunnel server\'s own IP, when a direct connection to it is blocked and only fronted nodes work. A node with a pre-proxy (passwall2\'s chain proxy) is matched on the pre-proxy\'s address instead, since that is the server the router connects to.'),
			'host', _('none'));

		o = s.taboption('nodes', form.DummyValue, '_chain', _('Failover chain'),
			_('The nodes an incident tries, in order, from the saved settings (Save to refresh it). Run URL tests on the Status tab tests them all without changing anything.'));
		o.renderWidget = function() {
			const c = chain(nodes);
			if (!c.length)
				return E('em', { 'style': 'color:#d9534f' }, _('Empty: no usable node matches these settings.'));
			return E('ol', { 'style': 'margin:0;padding-left:1.6em' }, c.map(function(x) {
				const p = preproxy(x.node);
				return E('li', [ x.node.remarks || x.node['.name'], E('span', { 'style': 'opacity:.6' },
					' · %s · %s:%s'.format(x.tier, x.node.address || '?', x.node.port || '?') +
					(p ? ' ' + _('via %s (%s)').format(p.remarks || p['.name'], p.address || '?') : '')) ]);
			}));
		};

		// --- WANs
		o = list('wans', 'wan_order', _('WAN order'),
			_('Network interfaces, by their name in Network ▸ Interfaces. The first is the primary: its default route belongs to netifd, and the watchdog never takes it down. The rest are backups. An incident tries the primary, then the backups that are already up, in this order, then the ones that are down, raised with ifup as a last resort and taken down again once they are no longer needed. Drag to reorder.'),
			'uciname');
		wans.forEach(function(w) { o.value(w); });

		o = list('wans', 'wan_targets', _('Ping targets'),
			_('The fallback of the direct check: a WAN has direct internet when any of these answers a ping bound to its device. Ping never enters passwall2, so any reliable host works, but it must answer ping on every line. <code>host=IP</code>: the host is resolved hourly while the tunnel is healthy and cached, and the IP is used until the first lookup, so a broken resolver during an outage cannot hurt.'));
		o.validate = function(id, v) { return !v || /^[A-Za-z0-9.:-]+(=[0-9.]+)?$/.test(v) || _('Expecting a host, an IP, or host=IP'); };

		num('wans', 'wan_up_wait', _('Lease wait (s)'),
			_('After raising a backup that was down, how long to wait for it to get a gateway (a DHCP lease, a modem dialling in). Without one in time it is taken down again and the incident moves on.'));

		o = opt('wans', form.Value, 'direct_check_url', _('Direct-check URL'),
			_('The first direct check: this URL is fetched bound to each WAN\'s device, and an IP address in the reply means the line works; it is also the line\'s public IP on the Status tab. passwall2 must route it direct (its address has to match a direct rule), or the router\'s own request rides the tunnel and proves nothing. Plain http keeps it to about 1 KB. If it fails, the ping targets decide.'),
			_('empty: ping only'));
		o.validate = function(id, v) { return !v || /^https?:\/\/\S+$/.test(v) || _('Expecting an http:// or https:// URL'); };

		o = opt('wans', form.Flag, 'restart_on_wan_change', _('Restart passwall2 on WAN change'),
			_('Restart passwall2 after each route move, to a backup and back again. Without it, xray\'s open connections keep the old source address and can stall for minutes; the restart is a 5–15 s blip instead. Off: restart only when the node changes too.'),
			_('on'));
		o.default = '1';
		o.rmempty = false;

		// --- Detection
		list('probe', 'expect_exit_ips', _('Expected exit IPs'),
			_('The tunnel\'s exit address. A probe passes only when the trace or ifconfig.co reports one of these. Any other address is a failure too: traffic that works but leaves outside the tunnel, through a direct rule or a node that exits elsewhere, is exactly what this catches. When two nodes in a row exit at the same wrong address, the fault is passwall2\'s routing, not the nodes, so the watchdog stops switching nodes and backs off.'),
			'ipaddr', _('empty: the bad exit country decides'));

		o = opt('probe', form.Value, 'probe_bad_loc', _('Bad exit country'),
			_('Used only while no exit IP is set: a probe fails when Cloudflare\'s trace reports this country, a two-letter code such as the one your lines exit in directly. Any other country passes.'),
			_('none'));
		o.datatype = 'and(maxlength(2),minlength(2))';

		num('probe', 'probe_interval', _('Probe interval (s)'),
			_('Between probes while all is healthy. Each probe is one small HTTPS request through the tunnel. Lower notices an outage sooner and spends more tunnel traffic.'), 5);
		num('probe', 'fail_interval', _('Failed-probe interval (s)'),
			_('Between probes once one has failed, until the threshold below, so an outage is confirmed quickly instead of at the healthy pace. A failing probe itself takes about 11 s of timeouts.'), 1);
		num('probe', 'fail_threshold', _('Failures before an incident'),
			_('Failed probes in a row that open an incident. 1 reacts to every blip, and every incident restarts passwall2 at least once; 3 rides out one lost probe.'), 1);
		num('probe', 'grace', _('Startup grace (s)'),
			_('No probes for this long after the watchdog starts: at boot, and after a restart of the service (not after Save & Apply here). It covers a modem that takes minutes to sync after a power cut.'));
		num('probe', 'xray_min_age', _('Minimum xray age (s)'),
			_('Skip probes while xray is younger than this: someone else (LuCI, a script) has just restarted passwall2, and a probe now would count that restart as an outage.'));
		o = list('probe', 'extra_locks', _('Lock files'),
			_('Skip probes while any of these files exists, and before restarting passwall2 wait up to 60 s for them to go. Give your own scripts that restart passwall2 a lock file and list it here, so the two never fight.'),
			null, _('none'));
		o.validate = function(id, v) { return !v || /^\/\S+$/.test(v) || _('Expecting an absolute path'); };

		// --- Switch-back
		num('switchback', 'node_sb_interval', _('Primary node retest (s)'),
			_('While on a fallback node, URL-test the primary node this often. The test runs on a throwaway xray, as passwall2\'s URL Test does, so the live traffic is not touched.'), 30);
		num('switchback', 'node_sb_passes', _('Passes before switching back'),
			_('Passing URL tests of the primary node in a row before switching back to it; a failing test resets the count. 1 returns at the first pass; more keeps a flapping node from pulling the house back and forth. After a switch-back that fails verification, twice as many passes are needed next time.'), 1);
		num('switchback', 'wan_sb_check', _('Primary WAN check (s)'),
			_('While on a backup WAN, check the primary WAN this often: its direct internet and, once that holds, a TLS handshake over it with the primary node, or with its pre-proxy when it has one. Both must pass to switch back, and the switch-back returns the node to the primary too if the incident had moved it.'), 10);
		num('switchback', 'wan_sb_hold_down', _('Hold after a line outage (s)'),
			_('When the primary WAN was left for having no direct internet: how long it must keep answering before the switch back. 0 = at the first good check. Raise it if the line tends to come back and drop again.'));
		num('switchback', 'wan_sb_hold_nodes', _('Hold after a tunnel outage (s)'),
			_('The same hold, when the primary WAN was left because no node worked over it while its direct internet was fine, i.e. the tunnel was blocked on that line.'));
		num('switchback', 'wan_stat_interval', _('Direct check while healthy (s)'),
			_('Check every WAN\'s direct internet this often while all is healthy, so the Status tab\'s WAN table stays fresh. Each check is a small request on every line, metered ones included. 0 = never: only during an incident, a switch-back and Retest now.'));
		num('switchback', 'sb_max_wait', _('Longest switch-back wait (s)'),
			_('A switch-back that fails verification is rolled back, and the next try waits twice as long each time: with a WAN hold of 0, 10 min, then 20, 40 and so on. Node switch-backs double the passes needed the same way. Neither ever waits longer than this.'), 60);

		// --- Limits
		num('limits', 'max_restarts', _('passwall2 restarts per incident'),
			_('Counted across every WAN and node one incident tries. When the cap is reached the incident stops where it is, and the back-off below applies.'), 1);
		num('limits', 'max_incidents_hour', _('Incidents per hour'),
			_('Once this many incidents have opened within the last hour, the next one waits for the cool-down below. Probes go on meanwhile, and a passing one ends the outage as usual.'), 1);
		num('limits', 'incident_cooldown', _('Cool-down (s)'),
			_('How long the next incident waits after the hourly limit is hit.'));
		list('limits', 'backoff', _('Back-off between incidents (s)'),
			_('After an incident that fixed nothing, the next one waits the first value; after another such incident, the second; and so on, the last value repeating. A passing probe starts the list over. Drag to reorder.'),
			'uinteger');

		return m.render();
	}
});
