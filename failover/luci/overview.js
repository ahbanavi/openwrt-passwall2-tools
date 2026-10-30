'use strict';
'require baseclass';
'require fs';

/*
 * Status ▸ Overview widget for the pw-failover watchdog: one line of state, the egress WAN, the
 * tunnel node and the exit IP, linking to Network ▸ Failover.
 * Installs as /www/luci-static/resources/view/status/include/35_pw_failover.js.
 */

return baseclass.extend({
	title: _('Failover'),

	load: function() {
		return L.resolveDefault(fs.exec('/root/scripts/pw-failover.sh', [ 'json' ]), null);
	},

	render: function(res) {
		let d;
		try { d = JSON.parse(res.stdout); } catch (e) { return null; }

		let state, cls;
		const m = d.manual || {};
		if (!d.daemon) { state = _('Watchdog not running'); cls = 'danger'; }
		else if (d.incident_running || d.outage.open) { state = _('Outage — failover in progress'); cls = 'danger'; }
		else if (d.paused) { state = _('Paused'); cls = 'notice'; }
		else if (m.active) { state = _('Manual override'); cls = d.probe.result === 'fail' ? 'warning' : 'notice'; }
		else if (d.egress.override) { state = _('On backup WAN (%s is out)').format(d.egress.primary); cls = 'warning'; }
		else if (d.node.fallback) { state = _('On fallback node (%s is failing)').format(d.node.primary_label); cls = 'warning'; }
		else if (d.probe.result === 'fail') { state = _('Tunnel probe failing'); cls = 'warning'; }
		else { state = _('Healthy'); cls = 'success'; }

		const row = function(k, v) {
			return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left', 'width': '33%' }, k), E('td', { 'class': 'td left' }, v) ]);
		};

		return E('div', {}, [
			E('div', { 'class': 'alert-message ' + cls, 'style': 'margin-bottom:8px' }, [
				E('strong', state), ' — ', E('a', { 'href': L.url('admin/network/failover') }, _('details'))
			]),
			E('table', { 'class': 'table' }, [
				row(_('Egress WAN'), d.egress.wan + (m.wan
					? ' (' + (m.wan === d.egress.wan ? _('pinned') : _('pinned to %s, not up yet').format(m.wan)) + ')'
					: (d.egress.override ? ' (' + _('backup') + ')' : ''))),
				row(_('Tunnel node'), d.node.label + (m.node ? ' (' + _('pinned') + ')' : (d.node.fallback ? ' (' + _('fallback') + ')' : ''))),
				row(_('Exit IP'), d.probe.ip ? d.probe.ip + (d.probe.loc ? ' (' + d.probe.loc + ')' : '') : '—')
			])
		]);
	}
});
