'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';
'require dom';
'require uci';
'require rpc';

/*
 * Network ▸ Killswitch — status and settings of pw-killswitch, the passwall2 killswitch.
 * Installs as /www/luci-static/resources/view/pw-killswitch/killswitch.js.
 *
 * The status part comes from one `pw-killswitch.sh json` call, polled every 3 s. The buttons run
 * the only other verbs the ACL allows: test, test-stop and compile-bg. The settings part is the uci
 * section pw-killswitch.main; Save & Apply reloads the service, which applies it at once. LuCI's
 * host hints, read once, put names to the sources in the log of refused connections.
 */

const SCRIPT = '/root/scripts/pw-killswitch.sh';

const callHostHints = rpc.declare({ object: 'luci-rpc', method: 'getHostHints', expect: { '': {} } });

const CSS = `
.pks-banner { display: flex; gap: 14px; align-items: flex-start; }
.pks-banner .pks-icon { font-size: 26px; line-height: 1.2; }
.pks-banner h3 { margin: 0 0 4px; border: 0; padding: 0; }
.pks-banner p { margin: 2px 0; }
.pks-actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 4px; }
.pks-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin: 14px 0; }
.pks-card { border: 1px solid rgba(128,128,128,.35); border-radius: 6px; padding: 10px 14px; }
.pks-card h4 { margin: 0 0 6px; font-size: 85%; opacity: .7; text-transform: uppercase; letter-spacing: .05em; }
.pks-big { font-size: 130%; font-weight: 600; word-break: break-word; }
.pks-sub { opacity: .8; font-size: 90%; margin-top: 3px; }
.pks-ok { color: #2e9d5b; }
.pks-bad { color: #d9534f; }
.pks-warn { color: #d58b00; }
.pks-muted { opacity: .6; }
.pks-section { margin-top: 18px; }
.pks-section > h3 { margin-bottom: 6px; }
.pks-scroll { max-height: 360px; overflow: auto; margin: 6px 0 0; }
.pks-pre { white-space: pre-wrap; font-family: monospace; font-size: 90%; max-height: 360px; overflow: auto;
  padding: 8px 10px; border: 1px solid rgba(128,128,128,.3); border-radius: 6px; margin: 6px 0 0; }
`;

function run(args) {
	return fs.exec(SCRIPT, args).then(function(res) {
		if (res.code !== 0)
			throw new Error((res.stderr || res.stdout || '').trim() || _('exit code %d').format(res.code));
		return (res.stdout || '').trim();
	});
}

function getStatus() {
	return run([ 'json' ]).then(function(out) { return JSON.parse(out); });
}

function clock(t) {
	return t ? new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—';
}

function stamp(t) {   // clock(), with the date when it is not today
	const x = new Date(t * 1000);
	return x.toDateString() === new Date().toDateString() ? clock(t)
		: x.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function dur(s) {
	s = Math.max(0, Math.round(s));
	const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
	return h ? '%dh %dm'.format(h, m) : (m ? '%dm %ds'.format(m, x) : '%ds'.format(x));
}

function ago(d, t) {
	return t ? _('%s ago').format(dur(d.now - t)) : '—';
}

function num(n) {
	return Number(n || 0).toLocaleString();
}

function overall(d) {
	if (d.state === 'off')
		return { cls: 'notice', icon: '⏻', title: _('Off'),
			lines: [ _('Traffic is not gated. When passwall2 stops, the LAN and the router itself go out directly over the ISP. Enable the killswitch below.') ] };

	if (d.state === 'armed') {
		const lines = [ _('passwall2 is healthy, and traffic flows exactly as passwall2 routes it. The moment passwall2 stops or restarts, or its proxy dies, only destinations in the direct lists stay reachable.') ];
		if (d.since)
			lines.push(_('Armed since %s (%s).').format(stamp(d.since), ago(d, d.since)));
		if (!d.daemon)
			lines.push(_('The watcher is not running. The gate still closes when passwall2 stops, but it will not reopen by itself.'));
		return { cls: d.daemon ? 'success' : 'warning', icon: '🛡', title: _('Armed'), lines: lines };
	}

	const testing = d.test_until > d.now;
	const lines = [
		_('Reason: %s.').format(d.reason || _('unknown')),
		_('Only destinations in the direct lists are reachable. Every other connection is refused, and DNS answers only names from the direct lists.')
	];
	if (d.since)
		lines.push(_('Engaged since %s (%s).').format(stamp(d.since), ago(d, d.since)));
	if (!d.daemon)
		lines.push(_('The watcher is not running, so the gate will not reopen by itself. Restart the pw-killswitch service.'));
	else if (!testing)
		lines.push(_('It reopens by itself once passwall2 has been healthy for two seconds.'));
	return { cls: 'danger', icon: '⛔',
		title: testing ? _('Engaged — test, %s left').format(dur(d.test_until - d.now)) : _('Engaged'), lines: lines };
}

function card(title, big, cls, sub) {
	return E('div', { 'class': 'pks-card' }, [
		E('h4', title),
		E('div', { 'class': 'pks-big ' + (cls || '') }, big),
		sub ? E('div', { 'class': 'pks-sub' }, sub) : ''
	]);
}

function yes(b, t, f) {
	return E('span', { 'class': b ? 'pks-ok' : 'pks-bad' }, b ? t : f);
}

return view.extend({
	load: function() {
		return Promise.all([
			getStatus().catch(function(e) { return { error: e.message }; }),
			uci.load('pw-killswitch'),
			callHostHints().catch(function() { return {}; })
		]);
	},

	refresh: function() {
		return getStatus().then(L.bind(function(d) {
			// keep where the scrolling lists were scrolled to across the re-render
			const sel = '.pks-scroll, .pks-pre';
			const tops = Array.prototype.map.call(this.root.querySelectorAll(sel), function(n) { return n.scrollTop; });
			dom.content(this.root, this.build(d));
			this.root.querySelectorAll(sel).forEach(function(n, i) { n.scrollTop = tops[i] || 0; });
		}, this)).catch(L.bind(function(e) {
			dom.content(this.root, this.build({ error: e.message }));
		}, this));
	},

	act: function(args, okText) {
		return run(args).then(L.bind(function(out) {
			ui.addTimeLimitedNotification(null, E('p', okText || out), 4000, 'info');
			window.setTimeout(L.bind(this.refresh, this), 1200);
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed: %s').format(e.message)), 'danger');
		});
	},

	confirmTest: function() {
		const sel = E('select', { 'class': 'cbi-input-select' }, [
			[ '30', _('30 seconds') ], [ '60', _('1 minute') ], [ '120', _('2 minutes') ], [ '300', _('5 minutes') ]
		].map(function(o) { return E('option', { 'value': o[0] }, o[1]); }));

		ui.showModal(_('Test the killswitch'), [
			E('p', _('A test engages the killswitch while passwall2 keeps running. Traffic passwall2 proxies still flows through the tunnel, but for the whole house:')),
			E('ul', {}, [
				E('li', _('DNS answers only names from the direct lists. Other names fail, except where a DNS cache in front of the router still has them.')),
				E('li', _('The few connections that passwall2 sends direct without them being in the direct lists are refused.'))
			]),
			E('p', _('It ends by itself. To see the real thing, restart passwall2 while it is armed: proxied sites then stop answering instead of going out over the ISP.')),
			E('p', [ _('Run for'), ' ', sel ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': L.bind(function() {
					ui.hideModal();
					return this.act([ 'test', sel.value ], _('Killswitch engaged for a test.'));
				}, this) }, _('Start test'))
			])
		]);
	},

	buildActions: function(d) {
		const on = d.state !== 'off';
		const testing = d.test_until > d.now;
		return E('div', { 'class': 'pks-actions' }, [
			testing
				? E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
					return this.act([ 'test-stop' ], _('Test stopped. The gate reopens within two seconds.'));
				}) }, _('Stop test'))
				: E('button', { 'class': 'cbi-button cbi-button-action', 'disabled': (on && d.state === 'armed') ? null : '',
					'click': L.bind(this.confirmTest, this) }, _('Test…')),
			E('button', { 'class': 'cbi-button', 'disabled': on ? null : '', 'click': ui.createHandlerFn(this, function() {
				return this.act([ 'compile-bg' ], _('Rebuilding the direct lists in the background…'));
			}) }, _('Rebuild lists'))
		]);
	},

	buildCards: function(d) {
		const p = d.pw2 || {}, dn = d.dns || {}, ls = d.lists || {}, c = d.counters || {};
		const ports = [];
		if (p.tcp_port) ports.push(E('span', {}, [ 'TCP :' + p.tcp_port + ' ', yes(p.tcp_listen, '✓', '✗') ]));
		if (p.udp_port) ports.push(E('span', {}, [ ' · UDP :' + p.udp_port + ' ', yes(p.udp_listen, '✓', '✗') ]));

		return E('div', { 'class': 'pks-grid' }, [
			card(_('passwall2'), p.healthy_reason ? _('Not healthy') : _('Healthy'), p.healthy_reason ? 'pks-bad' : 'pks-ok',
				E('span', {}, [ p.healthy_reason ? p.healthy_reason : _('rules loaded, proxy listening'), E('br'), _('Proxy ports: ') ].concat(ports.length ? ports : [ '—' ]))),
			card(_('Resolver'), dn.redirect ? _('Answering LAN DNS') : (dn.running ? _('Standing by') : _('Stopped')),
				dn.redirect ? 'pks-warn' : (dn.running ? 'pks-ok' : 'pks-bad'),
				_('Port %d · upstream %s').format(dn.port || 0, (dn.upstreams || []).join(', ') || '—')),
			card(_('Direct lists'), _('%s names').format(num(ls.names)), '',
				E('span', {}, [ _('%s IPv4 and %s IPv6 entries').format(num(ls.ipv4), num(ls.ipv6)), E('br'),
					_('learned: %s IPv4, %s IPv6').format(num(ls.dyn4), num(ls.dyn6)), E('br'),
					ls.compiled ? _('built %s').format(stamp(+ls.compiled)) : _('not built yet') ])),
			card(_('Counters'), _('%s refused').format(num((c.blocked || {}).packets)), (c.blocked || {}).packets > 0 ? 'pks-warn' : '',
				E('span', {}, [ _('%s packets let through by the direct lists').format(num((c.allowed || {}).packets)), E('br'),
					_('%s DNS queries answered by the resolver').format(num((c.dns || {}).packets)), E('br'),
					E('span', { 'class': 'pks-muted' }, _('since the table was last rebuilt')) ]))
		]);
	},

	buildRules: function(d) {
		const ls = d.lists || {};
		const rows = (ls.rules || []).map(function(r) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, r.name),
				E('td', { 'class': 'td' }, E('span', { 'class': r.verdict === 'direct' ? 'pks-ok' : 'pks-warn' },
					r.verdict === 'direct' ? _('direct: allowed') : _('proxied: refused'))),
				E('td', { 'class': 'td' }, r.network),
				E('td', { 'class': 'td' }, num(r.ipv4)),
				E('td', { 'class': 'td' }, num(r.ipv6)),
				E('td', { 'class': 'td' }, num(r.names)),
				E('td', { 'class': 'td pks-muted' }, r.note || '')
			]);
		});
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('em', _('anything else'))),
			E('td', { 'class': 'td' }, E('span', { 'class': ls['default'] === 'allow' ? 'pks-ok' : 'pks-warn' },
				ls['default'] === 'allow' ? _('direct: allowed') : _('proxied: refused'))),
			E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, ''), E('td', { 'class': 'td' }, ''),
			E('td', { 'class': 'td pks-muted' }, _('the shunt\'s default node'))
		]));

		return E('div', { 'class': 'pks-section' }, [
			E('h3', _('What stays reachable while engaged')),
			E('div', { 'class': 'cbi-section-descr' },
				_('The rules of the shunt node %s, in passwall2\'s order: the first rule that matches decides, as in passwall2. Private and LAN ranges always stay reachable. Names resolve only while their rule is direct, and their addresses are then let through.').format(ls.node || '—')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Rule')), E('th', { 'class': 'th' }, _('While engaged')),
					E('th', { 'class': 'th' }, _('Network')), E('th', { 'class': 'th' }, _('IPv4')),
					E('th', { 'class': 'th' }, _('IPv6')), E('th', { 'class': 'th' }, _('Names')), E('th', { 'class': 'th' }, _('Note'))
				])
			].concat(rows)),
			(ls.warnings || []).length ? E('div', { 'class': 'alert-message warning' }, [
				E('strong', _('Left out of the lists')),
				E('ul', {}, ls.warnings.map(function(w) { return E('li', w); }))
			]) : ''
		]);
	},

	buildRefused: function(d) {
		const names = this.names || {};
		const descr = E('div', { 'class': 'cbi-section-descr' },
			_('Connections the killswitch refused: from where, to where, and when. A connection refused again within 10 minutes stays on its row. Refused while engaged is the killswitch doing its job. Refused while armed is traffic that skipped passwall2\'s rules, and worth a look. The newest 100 of each are kept in the router\'s memory for up to 7 days.'));

		if (!d.log_refused)
			return E('div', { 'class': 'pks-section' }, [
				E('h3', _('Refused connections')),
				E('p', { 'class': 'pks-muted' }, _('Not logged. Turn on "Log refused connections" under Settings.'))
			]);

		const rows = (d.refused || []).map(function(l) {
			const r = l.split(' ');   // first last packets state src dst proto port
			const first = +r[0], last = +r[1];
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, first < last ? [ stamp(last), E('br'), E('span', { 'class': 'pks-muted' }, _('since %s').format(stamp(first))) ] : stamp(last)),
				E('td', { 'class': 'td' }, E('span', { 'class': r[3] === 'armed' ? 'pks-warn' : 'pks-muted' },
					r[3] === 'armed' ? _('while armed') : _('while engaged'))),
				E('td', { 'class': 'td' }, names[r[4]] ? [ names[r[4]], E('br'), E('span', { 'class': 'pks-muted' }, r[4]) ] : r[4]),
				E('td', { 'class': 'td' }, r[5]),
				E('td', { 'class': 'td' }, '%s/%s'.format(r[6], r[7])),
				E('td', { 'class': 'td' }, num(r[2]))
			]);
		});

		return E('div', { 'class': 'pks-section' }, [
			E('h3', _('Refused connections')),
			descr,
			rows.length ? E('div', { 'class': 'pks-scroll' }, E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Last refused')), E('th', { 'class': 'th' }, _('While')),
					E('th', { 'class': 'th' }, _('From')), E('th', { 'class': 'th' }, _('To')),
					E('th', { 'class': 'th' }, _('Port')), E('th', { 'class': 'th' }, _('Packets'))
				])
			].concat(rows))) : E('p', { 'class': 'pks-muted' }, _('None logged.'))
		]);
	},

	buildEvents: function(d) {
		const ev = d.events || [];
		return E('div', { 'class': 'pks-section' }, [
			E('h3', _('Recent events')),
			ev.length
				? E('div', { 'class': 'pks-pre' }, ev.map(function(e) { return E('div', '%s  %s'.format(stamp(e.t), e.msg)); }))
				: E('p', { 'class': 'pks-muted' }, _('None since the router started.'))
		]);
	},

	build: function(d) {
		if (d.error)
			return E('div', { 'class': 'alert-message danger' }, [
				E('h3', _('Cannot read the killswitch status')), E('p', d.error),
				E('p', _('Is %s installed?').format(SCRIPT))
			]);

		const s = overall(d);
		return E('div', {}, [
			E('div', { 'class': 'alert-message ' + s.cls + ' pks-banner' }, [
				E('div', { 'class': 'pks-icon' }, s.icon),
				E('div', {}, [ E('h3', s.title) ].concat(s.lines.map(function(l) { return E('p', l); })))
			]),
			this.buildActions(d),
			this.buildCards(d),
			this.buildRefused(d),
			this.buildRules(d),
			this.buildEvents(d)
		]);
	},

	render: function(data) {
		const d = data[0] || {};
		this.names = {};   // address -> host name
		Object.values(data[2] || {}).forEach(L.bind(function(h) {
			if (h.name)
				(h.ipaddrs || []).concat(h.ip6addrs || []).forEach(L.bind(function(a) { this.names[a] = h.name; }, this));
		}, this));
		this.root = E('div');
		dom.content(this.root, this.build(d));
		poll.add(L.bind(this.refresh, this), 3);

		const m = new form.Map('pw-killswitch');
		const s = m.section(form.NamedSection, 'main', 'main', _('Settings'));
		let o;

		o = s.option(form.Flag, 'enabled', _('Enable killswitch'),
			_('On: while passwall2 is down, restarting, or its proxy is not listening, TCP and UDP from the LAN and from the router itself may leave only for destinations in the direct lists; the router\'s DNS and xray\'s own connections to its nodes always pass. Off: the gate and its rules are removed, and nothing is checked. Stopping the service does not turn it off; this switch does.'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'dns_server', _('DNS server for direct names'),
			_('Where the resolver sends names from the direct lists while the killswitch is engaged. Empty: the same servers passwall2 uses for its direct DNS, the first WAN resolvers (%s). An IP address, optionally with #port. A change rebuilds the lists.')
				.format((d.dns && d.dns.wan_dns) || '—'));
		o.placeholder = (d.dns && d.dns.wan_dns) || '';
		o.validate = function(sid, v) {
			return (!v || /^[0-9a-fA-F.:]+(#[0-9]{1,5})?$/.test(v)) ? true : _('An IP address, optionally with #port');
		};

		o = s.option(form.Flag, 'log_refused', _('Log refused connections'),
			_('On: every refused connection is listed above with its source, destination, port and time, in the router\'s memory only: the newest 100 refused while armed and 100 while engaged, none older than 7 days, gone at reboot. Traffic that is let through is not touched. Off: nothing is recorded, and the list is cleared.'));
		o.default = '1';
		o.rmempty = false;

		return m.render().then(L.bind(function(mapEl) {
			return E('div', {}, [
				E('style', CSS),
				E('h2', _('Killswitch')),
				E('div', { 'class': 'cbi-map-descr' },
					_('pw-killswitch keeps traffic from leaving outside the tunnel. While passwall2 is healthy it changes nothing. The moment passwall2 stops, restarts or its proxy dies, it lets through only destinations that passwall2 itself would send direct, and refuses the rest until passwall2 is back.')),
				this.root,
				mapEl
			]);
		}, this));
	}
});
