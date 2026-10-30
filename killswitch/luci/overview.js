'use strict';
'require baseclass';
'require fs';

/*
 * Status ▸ Overview widget for pw-killswitch: the state with its reason, how long it has held, and
 * what the gate has refused, linking to Network ▸ Killswitch.
 * Installs as /www/luci-static/resources/view/status/include/36_pw_killswitch.js.
 */

function dur(s) {
	s = Math.max(0, Math.round(s));
	const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
	return d ? '%dd %dh'.format(d, h) : (h ? '%dh %dm'.format(h, m) : (m ? '%dm'.format(m) : '%ds'.format(s)));
}

return baseclass.extend({
	title: _('Killswitch'),

	load: function() {
		return L.resolveDefault(fs.exec('/root/scripts/pw-killswitch.sh', [ 'json' ]), null);
	},

	render: function(res) {
		let d;
		try { d = JSON.parse(res.stdout); } catch (e) { return null; }

		let state, cls;
		const testing = d.test_until > d.now;
		if (d.state === 'off') { state = _('Off — traffic is not gated'); cls = 'notice'; }
		else if (d.state === 'armed') {
			state = d.daemon ? _('Armed') : _('Armed, but the watcher is not running');
			cls = d.daemon ? 'success' : 'warning';
		}
		else {
			state = (testing ? _('Engaged (test)') : _('Engaged')) + (d.reason ? ' — ' + d.reason : '');
			cls = 'danger';
		}

		const row = function(k, v) {
			return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, k), E('td', { 'class': 'td left' }, v) ]);
		};
		const p = d.pw2 || {}, c = d.counters || {}, ls = d.lists || {};

		return E('div', {}, [
			E('div', { 'class': 'alert-message ' + cls, 'style': 'margin-bottom:8px' }, [
				E('strong', state), ' — ', E('a', { 'href': L.url('admin/network/killswitch') }, _('details'))
			]),
			d.state === 'off' ? '' : E('table', { 'class': 'table' }, [
				row(_('Since'), d.since ? _('%s ago').format(dur(d.now - d.since)) : '—'),
				row(_('passwall2'), p.healthy_reason ? p.healthy_reason : _('healthy')),
				row(_('Refused'), _('%d packets').format((c.blocked || {}).packets || 0)),
				row(_('Direct lists'), _('%s names, %s IPv4 and %s IPv6 entries').format(
					Number(ls.names || 0).toLocaleString(), Number(ls.ipv4 || 0).toLocaleString(), Number(ls.ipv6 || 0).toLocaleString()))
			])
		]);
	}
});
