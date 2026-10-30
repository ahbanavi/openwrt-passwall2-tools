'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require dom';
'require uci';

/*
 * Network ▸ Failover — the pw-failover watchdog's status page.
 * Installs as /www/luci-static/resources/view/pw-failover/status.js.
 *
 * Everything shown comes from one `pw-failover.sh json` call, polled every 5 s. The buttons run
 * the only other verbs the ACL allows: retest, test-nodes-bg, revert-bg, pause, resume,
 * test-telegram, manual-bg and manual-clear-bg. Long jobs run detached on the router and show up
 * in the next poll. The manual override dialog reads the node list from uci (passwall2).
 */

const SCRIPT = '/root/scripts/pw-failover.sh';

const CSS = `
.pwf-banner { display: flex; gap: 14px; align-items: flex-start; }
.pwf-banner .pwf-icon { font-size: 26px; line-height: 1.2; }
.pwf-banner h3 { margin: 0 0 4px; border: 0; padding: 0; }
.pwf-banner p { margin: 2px 0; }
.pwf-actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 4px; }
.pwf-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; margin: 14px 0; }
.pwf-card { border: 1px solid rgba(128,128,128,.35); border-radius: 6px; padding: 10px 14px; }
.pwf-card h4 { margin: 0 0 6px; font-size: 85%; opacity: .7; text-transform: uppercase; letter-spacing: .05em; }
.pwf-big { font-size: 130%; font-weight: 600; word-break: break-word; }
.pwf-sub { opacity: .8; font-size: 90%; margin-top: 3px; }
.pwf-badge { display: inline-block; padding: 0 8px; border-radius: 10px; font-size: 80%; font-weight: 600;
  margin-left: 6px; border: 1px solid currentColor; vertical-align: middle; white-space: nowrap; }
.pwf-ok { color: #2e9d5b; }
.pwf-bad { color: #d9534f; }
.pwf-warn { color: #d58b00; }
.pwf-info { color: #3a87c8; }
.pwf-muted { opacity: .6; }
.pwf-pre { white-space: pre-wrap; font-family: monospace; font-size: 90%; max-height: 460px; overflow: auto;
  padding: 8px 10px; border: 1px solid rgba(128,128,128,.3); border-radius: 6px; margin: 6px 0 0; }
.pwf-cause { font-weight: 600; margin: 6px 0; }
tr.pwf-active td { font-weight: 600; }
.pwf-section { margin-top: 18px; }
.pwf-section > h3 { margin-bottom: 6px; }
.pwf-report { margin: 4px 0; }
.pwf-report > summary { cursor: pointer; padding: 3px 0; }
.pwf-form { display: grid; grid-template-columns: max-content 1fr; gap: 10px 14px; align-items: center; margin: 12px 0; }
.pwf-form select { width: 100%; max-width: 100%; }
.pwf-form .pwf-full { grid-column: 1 / -1; }
@media (max-width: 600px) { .pwf-form { grid-template-columns: 1fr; } }
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
	if (!t) return _('never');
	const s = Math.max(0, d.now - t);
	return s < 5 ? _('just now') : _('%s ago').format(dur(s));
}

function inSecs(d, t) {
	if (!t) return '';
	const s = t - d.now;
	return s <= 0 ? _('due now') : _('in %s').format(dur(s));
}

// node_allowed() in pw-failover.sh, before the deny lists: pseudo-nodes never run
function usable(n) {
	return !!n.protocol && n.protocol.charAt(0) !== '_';
}

// node_dial_addr() in pw-failover.sh: a node behind a pre-proxy (passwall2's chain_proxy 1) is
// dialled at the pre-proxy's address, so that is the one the deny list matches
function dialAddr(n) {
	const p = n.chain_proxy === '1' && n.preproxy_node ? uci.get('passwall2', n.preproxy_node) : null;
	return p && p['.type'] === 'nodes' ? p.address : n.address;
}

function leftReason(r) {
	return r === 'nodes' ? _('no tunnel node worked over it')
		: (r === 'manual' ? _('a manual override ended there') : _('no direct internet'));
}

function badge(text, cls) {
	return E('span', { 'class': 'pwf-badge ' + (cls || '') }, text);
}

function overall(d) {
	const p = d.probe, eg = d.egress, n = d.node;
	const exit = p.ip ? _('Exit IP %s%s').format(p.ip, p.loc ? ' (' + p.loc + ')' : '') : '';

	if (!d.daemon)
		return { cls: 'danger', icon: '⛔', title: _('The watchdog is not running'),
			lines: [ _('Nothing is being monitored. Start it with /etc/init.d/pw-failover start.') ] };

	if (d.incident_running || d.outage.open) {
		const lines = [ _('Tunnel down since %s (%s). The watchdog is working through the WANs and nodes; the timeline below updates live.')
			.format(clock(d.outage.since), ago(d, d.outage.since)) ];
		if (d.outage.cause) lines.push(d.outage.cause);
		return { cls: 'danger', icon: '🚨', title: d.incident_running ? _('Failover in progress') : _('Outage open'), lines: lines };
	}

	const m = d.manual || {};
	if (d.paused)
		return { cls: 'notice', icon: '⏸', title: d.paused_until
				? _('Paused until %s (%s)').format(stamp(d.paused_until), inSecs(d, d.paused_until)) : _('Paused until you resume'),
			lines: [ _('No probes, URL tests, failover, switch-back or reports, in act and observe mode alike. Traffic stays where it is: %s via %s.').format(eg.wan, n.label) ]
				.concat(m.active ? [ _('A manual override is set; it applies again when the pause ends.') ] : []) };

	if (m.active) {
		const lines = [
			_('WAN: %s. Node: %s.').format(
				m.wan ? _('%s (pinned)').format(m.wan) : _('%s (automatic)').format(eg.wan),
				m.node ? _('%s (pinned)').format(m.node_label || m.node) : _('%s (automatic)').format(n.label))
		];
		if (m.wan && eg.wan !== m.wan)
			lines.push(_('Traffic is on %s, not the pinned %s, which is down or still coming up. The watchdog moves it back once %s is up.').format(eg.wan, m.wan, m.wan));
		lines.push((m.until ? _('Ends at %s (%s); then automatic failover and switch-back resume.').format(clock(m.until), inSecs(d, m.until))
			: _('Holds until you clear it.')) + ' ' +
			(m.hold ? _('Kept even if nothing works inside it.') : _('If nothing works inside it, it is dropped and failover runs as usual.')));
		if (p.result === 'fail')
			lines.push(_('Tunnel probe failing (%d of %d): %s').format(p.fails, p.threshold, p.detail));
		else if (exit)
			lines.push(exit);
		return { cls: p.result === 'fail' ? 'warning' : 'notice', icon: '📌', title: _('Manual override'), lines: lines };
	}

	if (eg.override)
		return { cls: 'warning', icon: '🔀', title: _('On backup WAN %s').format(eg.wan),
			lines: [
				_('%s is out (%s) since %s. Back to %s at the first check where it answers directly and %s answers over it; next check %s.')
					.format(eg.primary, leftReason(eg.reason), clock(eg.since), eg.primary, n.primary_label, inSecs(d, eg.next_check)),
				_('Node %s. %s').format(n.label, exit)
			] };

	if (n.fallback)
		return { cls: 'warning', icon: '🔀', title: _('On fallback node %s').format(n.label),
			lines: [
				_('%s failed at %s. It is URL-tested again %s, and the watchdog switches back at its first pass.')
					.format(n.primary_label, clock(n.fallback_since), inSecs(d, n.next_test)),
				_('WAN %s. %s').format(eg.wan, exit)
			] };

	if (p.result === 'fail')
		return { cls: 'warning', icon: '⚠️', title: _('Tunnel probe failing (%d of %d)').format(p.fails, p.threshold),
			lines: [ _('An incident opens after %d failures in a row. Last: %s').format(p.threshold, p.detail) ] };

	if (p.result === 'skip')
		return { cls: 'notice', icon: '⏳', title: _('Waiting'),
			lines: [ _('Probes are paused: %s.').format(p.detail), _('Traffic: %s via %s.').format(eg.wan, n.label) ] };

	return { cls: 'success', icon: '✅', title: _('Healthy'),
		lines: [ _('Traffic leaves via %s through %s. %s. Last probe %s.').format(eg.wan, n.label, exit, ago(d, p.at)) ] };
}

return view.extend({
	logOpen: false,
	openReports: null,

	load: function() {
		return getStatus().catch(function(e) { return { error: e.message }; });
	},

	refresh: function() {
		return getStatus().then(L.bind(function(d) {
			dom.content(this.root, this.build(d));
		}, this)).catch(L.bind(function(e) {
			dom.content(this.root, this.build({ error: e.message }));
		}, this));
	},

	act: function(args, okText) {
		return run(args).then(L.bind(function(out) {
			ui.addTimeLimitedNotification(null, E('p', okText || out), 4000, 'info');
			window.setTimeout(L.bind(this.refresh, this), 1500);
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('Failed: %s').format(e.message)), 'danger');
		});
	},

	confirmRevert: function(d) {
		ui.showModal(_('Return to primary?'), [
			E('p', _('This removes the backup route, switches the node to %s and restarts passwall2. The whole LAN loses the proxy for 5–15 seconds.').format(d.node.primary_label)),
			d.manual && d.manual.active ? E('p', _('It also ends the manual override.')) : '',
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': L.bind(function() {
					ui.hideModal();
					return this.act([ 'revert-bg' ], _('Returning to %s and %s…').format(d.egress.primary, d.node.primary_label));
				}, this) }, _('Return now'))
			])
		]);
	},

	openPause: function() {
		const durSel = E('select', { 'class': 'cbi-input-select' }, [
			[ '30', _('30 minutes') ], [ '60', _('1 hour') ], [ '120', _('2 hours') ], [ '240', _('4 hours') ],
			[ '720', _('12 hours') ], [ '1440', _('24 hours') ], [ '0', _('Until I resume it') ], [ 'custom', _('Custom…') ]
		].map(function(o) { return E('option', { 'value': o[0] }, o[1]); }));
		const custom = E('input', { 'type': 'number', 'min': '1', 'step': '1', 'class': 'cbi-input-text', 'placeholder': _('minutes') });
		const customRow = E('div', { 'class': 'pwf-full', 'style': 'display:none' }, [ custom, ' ', _('minutes') ]);
		durSel.addEventListener('change', function() {
			customRow.style.display = durSel.value === 'custom' ? '' : 'none';
			if (durSel.value === 'custom') custom.focus();
		});

		ui.showModal(_('Pause the watchdog'), [
			E('p', _('A pause stops everything the watchdog does, in act and observe mode alike: no probes, URL tests, failover, switch-back, route repairs or reports. Traffic stays on the WAN and node it is on now, even if the tunnel fails. It outlives a reboot.')),
			E('div', { 'class': 'pwf-form' }, [ E('label', _('For')), durSel, customRow ]),
			E('p', { 'class': 'pwf-muted' }, _('Resume ends it at once. A manual override stays set and applies again when the pause ends.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': L.bind(function() {
					let min = durSel.value;
					if (min === 'custom') {
						min = String(parseInt(custom.value, 10));
						if (!/^[1-9][0-9]*$/.test(min)) {
							ui.addTimeLimitedNotification(null, E('p', _('Enter the pause in whole minutes, 1 or more.')), 5000, 'warning');
							return;
						}
					}
					ui.hideModal();
					return this.act([ 'pause', min ], min === '0' ? _('Paused until you resume it.')
						: _('Paused for %s.').format(dur(+min * 60)));
				}, this) }, _('Pause'))
			])
		]);
	},

	openManual: function(d) {
		const m = d.manual || {};
		uci.unload('passwall2');
		uci.unload('pw-failover');
		return Promise.all([ uci.load('passwall2'), L.resolveDefault(uci.load('pw-failover'), null) ]).then(L.bind(function() {
			const denyNodes = L.toArray(uci.get('pw-failover', 'main', 'deny_nodes'));
			const denyAddrs = L.toArray(uci.get('pw-failover', 'main', 'deny_addrs'));
			const groups = {}, order = [];
			uci.sections('passwall2', 'nodes').forEach(function(n) {
				if (!usable(n) || denyNodes.indexOf(n['.name']) >= 0 || denyAddrs.indexOf(dialAddr(n)) >= 0) return;
				const g = n.group || _('No group');
				if (!groups[g]) { groups[g] = []; order.push(g); }
				groups[g].push(n);
			});

			const wanSel = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('Automatic: failover picks the WAN')) ]
				.concat((d.wans || []).map(function(w) {
					const state = w.up ? (w.active ? _('up, carrying traffic') : _('up'))
						: (w.primary ? _('down, cannot be pinned now') : _('down, raised with ifup'));
					return E('option', { 'value': w.name, 'disabled': (!w.up && w.primary) ? '' : null,
						'selected': m.wan === w.name ? '' : null }, '%s (%s) — %s'.format(w.name, w.dev || '?', state));
				})));
			const nodeSel = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('Automatic: failover picks the node')) ]
				.concat(order.map(function(g) {
					return E('optgroup', { 'label': g }, groups[g].map(function(n) {
						const tags = [];
						if (n['.name'] === d.node.id) tags.push(_('current'));
						if (n['.name'] === d.node.primary_id) tags.push(_('primary'));
						return E('option', { 'value': n['.name'], 'selected': m.node === n['.name'] ? '' : null },
							'%s (%s:%s)%s'.format(n.remarks || n['.name'], n.address || '?', n.port || '?', tags.length ? ' — ' + tags.join(', ') : ''));
					}));
				})));
			const durSel = E('select', { 'class': 'cbi-input-select' }, [
				[ '0', _('Until I clear it') ], [ '30', _('30 minutes') ], [ '60', _('1 hour') ], [ '240', _('4 hours') ],
				[ '720', _('12 hours') ], [ '1440', _('24 hours') ]
			].map(function(o) { return E('option', { 'value': o[0] }, o[1]); }));
			const release = E('input', { 'type': 'checkbox', 'id': 'pwf-release', 'checked': m.active && m.hold ? null : '' });

			ui.showModal(m.active ? _('Change the manual override') : _('Manual override'), [
				E('p', _('Pin the egress WAN, the tunnel node, or both. Traffic moves there now, and the watchdog never switches a pinned part back. If the tunnel fails, it looks for a fix only inside the pin: a pinned WAN with any node of the chain, a pinned node over any WAN, or with both pinned, a passwall2 restart.')),
				E('div', { 'class': 'pwf-form' }, [
					E('label', _('Egress WAN')), wanSel,
					E('label', _('Tunnel node')), nodeSel,
					E('label', _('For')), durSel,
					E('div', { 'class': 'pwf-full' }, [ release, ' ', E('label', { 'for': 'pwf-release' },
						_('If nothing works inside the override, drop it and fail over as usual')) ])
				]),
				E('p', { 'class': 'pwf-muted' }, _('Moving the WAN or the node restarts passwall2: the whole LAN loses the proxy for 5–15 seconds. A backup WAN that is down is raised first and must get a lease within the WAN wait.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
					E('button', { 'class': 'cbi-button cbi-button-positive', 'click': L.bind(function() {
						const w = wanSel.value, id = nodeSel.value;
						if (!w && !id) {
							ui.addTimeLimitedNotification(null, E('p', _('Pick a WAN, a node, or both. To return to automatic, use Clear override.')), 5000, 'warning');
							return;
						}
						ui.hideModal();
						return this.act([ 'manual-bg', w || '-', id || '-', durSel.value, release.checked ? '0' : '1' ],
							_('Applying the manual override…'));
					}, this) }, _('Apply'))
				])
			]);
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', _('Cannot read the passwall2 nodes: %s').format(e.message)), 'danger');
		});
	},

	buildActions: function(d) {
		const busy = d.busy || '';
		const m = d.manual || {};
		const onPrimary = !d.egress.override && !d.node.fallback && !m.active;
		const paused = !!d.paused;
		const btn = L.bind(function(label, cls, title, fn, disabled) {
			return E('button', {
				'class': 'cbi-button ' + cls, 'title': title, 'disabled': disabled ? '' : null,
				'click': ui.createHandlerFn(this, fn)
			}, label);
		}, this);

		return E('div', { 'class': 'pwf-actions' }, [
			btn(_('Retest now'), 'cbi-button-action',
				_('Run every pending check now: the direct ping of each WAN, the switch-back to the primary WAN or node, and a stalled incident retry.'),
				function() { return this.act([ 'retest' ], _('Retest requested; results in a few seconds.')); }, !d.daemon),
			btn(busy.indexOf('nodetest') >= 0 ? _('Testing nodes…') : _('Run URL tests'), 'cbi-button-neutral',
				_('URL-test every node in the failover chain over the current WAN, without changing anything (about a minute).'),
				function() { return this.act([ 'test-nodes-bg' ], _('URL tests started; results appear below.')); }, busy.indexOf('nodetest') >= 0),
			btn(busy.indexOf('manual') >= 0 ? _('Applying…') : (m.active ? _('Change override…') : _('Manual override…')), 'cbi-button-action',
				_('Pin the egress WAN, the tunnel node, or both, so traffic goes through them.'),
				function() { return this.openManual(d); }, busy.indexOf('manual') >= 0),
			m.active ? btn(_('Clear override'), 'cbi-button-neutral',
				_('End the manual override and hand back to the watchdog. Nothing moves now; the usual switch-back brings the house home at its next check.'),
				function() { return this.act([ 'manual-clear-bg' ], _('Override cleared; automatic failover and switch-back resume.')); },
				busy.indexOf('manual') >= 0) : '',
			btn(busy.indexOf('revert') >= 0 ? _('Returning…') : _('Return to primary'), 'cbi-button-negative',
				_('Go back to the primary WAN and node now, without waiting for the next check.'),
				function() { this.confirmRevert(d); }, onPrimary || busy.indexOf('revert') >= 0),
			paused
				? btn(_('Resume'), 'cbi-button-positive', _('Resume probing and failover now.'),
					function() { return this.act([ 'resume' ], _('Resumed.')); })
				: btn(_('Pause…'), 'cbi-button-neutral', _('Stop the watchdog for a while or until you resume it, e.g. while editing passwall2 by hand.'),
					function() { this.openPause(); }),
			btn(_('Send test message'), 'cbi-button-neutral', _('Send a Telegram test message through the tunnel.'),
				function() { return this.act([ 'test-telegram' ], _('Telegram test message sent.')); })
		]);
	},

	buildCards: function(d) {
		const eg = d.egress, n = d.node, p = d.probe, m = d.manual || {};
		const egSub = m.wan
			? [ badge(_('pinned'), 'pwf-info'), E('div', { 'class': 'pwf-sub' }, eg.wan === m.wan
				? _('manual override since %s').format(clock(m.since))
				: _('pinned to %s, which is not up yet').format(m.wan)) ]
			: eg.override
			? [ badge(_('backup'), 'pwf-warn'), E('div', { 'class': 'pwf-sub' },
				_('since %s, %s is out (%s)').format(clock(eg.since), eg.primary,
					eg.reason === 'nodes' ? _('tunnel failed over it') : leftReason(eg.reason))) ]
			: [ badge(_('primary'), 'pwf-ok') ];
		const nodeSub = m.node
			? [ badge(_('pinned'), 'pwf-info'), E('div', { 'class': 'pwf-sub' }, _('manual override since %s').format(clock(m.since))) ]
			: n.fallback
			? [ badge(_('fallback'), 'pwf-warn'), E('div', { 'class': 'pwf-sub' },
				_('since %s; %s retested %s').format(clock(n.fallback_since), n.primary_label, inSecs(d, n.next_test) || _('after the WAN is back'))) ]
			: [ badge(_('primary'), 'pwf-ok') ];
		const probeCls = p.result === 'ok' ? 'pwf-ok' : (p.result === 'fail' ? 'pwf-bad' : 'pwf-info');

		return E('div', { 'class': 'pwf-grid' }, [
			E('div', { 'class': 'pwf-card' }, [
				E('h4', _('Egress WAN')),
				E('div', { 'class': 'pwf-big' }, [ eg.wan || '?', E('span', { 'class': 'pwf-muted' }, ' (' + (eg.dev || '?') + ')') ].concat(egSub))
			]),
			E('div', { 'class': 'pwf-card' }, [
				E('h4', _('Tunnel node')),
				E('div', { 'class': 'pwf-big' }, [ n.label || '?' ].concat(nodeSub)),
				E('div', { 'class': 'pwf-sub pwf-muted' }, n.addr)
			]),
			E('div', { 'class': 'pwf-card' }, [
				E('h4', _('Tunnel probe')),
				E('div', { 'class': 'pwf-big ' + probeCls }, p.result === 'ok' ? _('OK') : (p.result === 'fail' ? _('FAILING') : _('Waiting'))),
				E('div', { 'class': 'pwf-sub' }, p.result === 'ok'
					? _('exit %s%s, %s').format(p.ip || '?', p.loc ? ' (' + p.loc + ')' : '', ago(d, p.at))
					: (p.detail || '') + (p.fails ? ' — ' + _('%d of %d failures').format(p.fails, p.threshold) : ''))
			]),
			E('div', { 'class': 'pwf-card' }, [
				E('h4', _('Watchdog')),
				E('div', { 'class': 'pwf-big' }, [ d.mode === 'act' ? _('Active') : _('Observe only'),
					d.mode === 'act' ? badge('act', 'pwf-ok') : badge('observe', 'pwf-info') ]),
				E('div', { 'class': 'pwf-sub' }, [
					d.drill ? _('Drill running (%s). ').format(d.drill.split(' ')[0]) : '',
					d.grace_until > d.now ? _('Startup grace until %s. ').format(clock(d.grace_until)) : '',
					_('Probes every %ds.').format(p.interval)
				])
			])
		]);
	},

	buildWans: function(d) {
		const rows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '#'),
				E('th', { 'class': 'th' }, _('Interface')),
				E('th', { 'class': 'th' }, _('Link')),
				E('th', { 'class': 'th' }, _('Direct internet')),
				E('th', { 'class': 'th' }, _('Role in failover'))
			])
		];

		(d.wans || []).forEach(function(w) {
			let direct;
			if (!w.up)
				direct = E('span', { 'class': 'pwf-muted' }, '—');
			else if (w.direct === 'ok')
				direct = E('span', { 'class': 'pwf-ok' }, [ '● ', _('OK'), w.rtt ? ' · ' + w.rtt + ' ms' : '',
					w.public_ip ? E('span', {}, [ ' · ', E('code', {}, w.public_ip) ]) : '',
					E('span', { 'class': 'pwf-muted' }, ' · ' + (w.how === 'ping' ? _('ping only') : (w.how || '')) + ' · ' + ago(d, w.checked)) ]);
			else if (w.direct === 'down')
				direct = E('span', { 'class': 'pwf-bad' }, [ '● ', _('DOWN'), E('span', { 'class': 'pwf-muted' }, ' · ' + ago(d, w.checked)) ]);
			else
				direct = E('span', { 'class': 'pwf-muted' }, _('not checked yet'));

			const role = [];
			if (w.primary) role.push(_('Primary'));
			else if (w.last_resort) role.push(_('Last resort (ifup if all else fails)'));
			else role.push(_('Backup, try #%d').format(w.pos));
			if (w.pinned) role.push(badge(_('pinned'), 'pwf-info'));
			if (w.active) role.push(badge(_('carrying traffic'), 'pwf-ok'));
			if (w.raised) role.push(badge(_('raised by watchdog'), 'pwf-warn'));

			rows.push(E('tr', { 'class': 'tr' + (w.active ? ' pwf-active' : '') }, [
				E('td', { 'class': 'td' }, String(w.pos)),
				E('td', { 'class': 'td' }, [ w.name, E('span', { 'class': 'pwf-muted' }, ' (' + (w.dev || '?') + ')') ]),
				E('td', { 'class': 'td' }, w.up
					? E('span', { 'class': 'pwf-ok' }, _('up') + (w.gw ? ' · gw ' + w.gw : ''))
					: E('span', { 'class': 'pwf-muted' }, _('down'))),
				E('td', { 'class': 'td' }, direct),
				E('td', { 'class': 'td' }, role)
			]));
		});

		return E('div', { 'class': 'pwf-section' }, [
			E('h3', _('WAN links')),
			E('div', { 'class': 'cbi-section-descr' },
				_('Direct internet is checked on each interface outside passwall2: an IP-echo URL on the direct list, fetched bound to the interface (the reply is that line\'s public IP), with a ping as fallback. It runs only when the tunnel fails, while switching back, and on Retest now, so the values can be old while all is healthy. Failover order: %s.')
					.format((d.egress.order || '').split(' ').join(' → ') + (d.manual && d.manual.wan ? ' (' + _('manual pin') + ')' : ''))),
			E('table', { 'class': 'table' }, rows)
		]);
	},

	buildIncident: function(d) {
		const o = d.outage;
		if (o.open) {
			return E('div', { 'class': 'pwf-section' }, [
				E('h3', _('Outage in progress')),
				o.cause ? E('div', { 'class': 'pwf-cause' }, o.cause) : '',
				o.wancheck ? E('div', {}, [ E('strong', _('WAN checks (direct = ping outside passwall2)')), E('pre', { 'class': 'pwf-pre' }, o.wancheck) ]) : '',
				o.urltests ? E('div', {}, [ E('strong', _('URL tests')), E('pre', { 'class': 'pwf-pre' }, o.urltests) ]) : '',
				E('strong', _('Timeline')),
				E('pre', { 'class': 'pwf-pre' }, o.timeline || _('(starting)'))
			]);
		}
		const reports = d.reports || [];
		if (!reports.length) return '';
		// newest open by default; remember what the user opened or closed across refreshes
		if (!this.openReports) { this.openReports = {}; this.openReports[reports[0].at] = true; }
		const self = this;
		return E('div', { 'class': 'pwf-section' }, [
			E('h3', _('Recent reports')),
			E('div', { 'class': 'cbi-section-descr' }, _('What the Telegram chat received, newest first.')),
		].concat(reports.map(function(r) {
			const title = (r.text || '').split('\n')[0];
			const det = E('details', { 'class': 'pwf-report', 'open': self.openReports[r.at] ? '' : null }, [
				E('summary', [ E('strong', clock(r.at)), ' ', E('span', { 'class': 'pwf-muted' }, '(' + ago(d, r.at) + ')'), ' · ', title,
					r.pending ? badge(_('not sent yet'), 'pwf-warn') : '' ]),
				E('pre', { 'class': 'pwf-pre' }, (r.text || '').split('\n').slice(1).join('\n').replace(/^\n+/, ''))
			]);
			det.addEventListener('toggle', function() { self.openReports[r.at] = det.open; });
			return det;
		})));
	},

	buildNodeTest: function(d) {
		const t = d.nodetest || {};
		const rows = t.rows || [];
		if (!t.running && !rows.length) return '';
		const table = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Node')),
				E('th', { 'class': 'th' }, _('Tier')),
				E('th', { 'class': 'th' }, _('Address')),
				E('th', { 'class': 'th' }, _('URL test'))
			])
		];
		rows.forEach(function(r) {
			table.push(E('tr', { 'class': 'tr' + (r.pick ? ' pwf-active' : '') }, [
				E('td', { 'class': 'td' }, [ r.label, r.id === d.node.id ? badge(_('current'), 'pwf-info') : '', r.pick ? badge(_('would pick'), 'pwf-ok') : '' ]),
				E('td', { 'class': 'td pwf-muted' }, r.tier || ''),
				E('td', { 'class': 'td pwf-muted' }, r.addr),
				E('td', { 'class': 'td ' + (r.pass ? 'pwf-ok' : 'pwf-bad') }, r.result)
			]));
		});
		return E('div', { 'class': 'pwf-section' }, [
			E('h3', _('URL tests')),
			E('div', { 'class': 'cbi-section-descr' }, t.running
				? _('Testing the chain over %s now…').format(d.egress.wan)
				: _('Last run %s (%s), over the WAN that was active then. Chain order: primary, then tier 1, then tier 2, then tier 3.').format(clock(t.at), ago(d, t.at))),
			rows.length ? E('table', { 'class': 'table' }, table) : ''
		]);
	},

	buildLog: function(d) {
		const det = E('details', { 'open': this.logOpen ? '' : null }, [
			E('summary', _('Recent watchdog log')),
			E('pre', { 'class': 'pwf-pre' }, d.log || _('(empty)'))
		]);
		det.addEventListener('toggle', L.bind(function() { this.logOpen = det.open; }, this));
		return E('div', { 'class': 'pwf-section' }, det);
	},

	build: function(d) {
		if (d.error)
			return E('div', { 'class': 'alert-message danger' }, [
				E('h3', _('Cannot read the watchdog status')), E('p', d.error),
				E('p', _('Is /root/scripts/pw-failover.sh installed?'))
			]);

		const s = overall(d);
		const extra = [];
		if (d.mode !== 'act') extra.push(E('p', _('Observe mode: the watchdog logs and reports what it would do, and changes nothing.')));
		if (d.drill) extra.push(E('p', _('A drill is running; reports are tagged [DRILL].')));
		if (d.manual && d.manual.result && d.now - d.manual.result_at < 600 && (d.busy || '').indexOf('manual') < 0)
			extra.push(E('p', { 'class': 'pwf-muted' }, _('Last override change (%s): %s').format(ago(d, d.manual.result_at), d.manual.result)));

		return E('div', {}, [
			E('div', { 'class': 'alert-message ' + s.cls + ' pwf-banner' }, [
				E('div', { 'class': 'pwf-icon' }, s.icon),
				E('div', {}, [ E('h3', s.title) ].concat(s.lines.map(function(l) { return E('p', l); })).concat(extra))
			]),
			this.buildActions(d),
			this.buildCards(d),
			this.buildWans(d),
			this.buildIncident(d),
			this.buildNodeTest(d),
			this.buildLog(d)
		]);
	},

	render: function(d) {
		this.root = E('div');
		dom.content(this.root, this.build(d));
		poll.add(L.bind(this.refresh, this), 5);
		return E('div', { 'class': 'cbi-map' }, [
			E('style', CSS),
			E('h2', _('Failover')),
			E('div', { 'class': 'cbi-map-descr' },
				_('pw-failover watches the passwall2 tunnel and the WAN links. When the tunnel dies it moves to another node, chosen by a real URL test; when the primary WAN dies it moves all traffic to a backup WAN; then it switches back once the primary works again.')),
			this.root
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
