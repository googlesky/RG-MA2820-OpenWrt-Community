'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

const callStatus = rpc.declare({
	object: 'luci.rg-ma2820', method: 'cluster_status', expect: { '': {} }
});

const callConfigure = rpc.declare({
	object: 'luci.rg-ma2820', method: 'configure_cluster',
	params: [ 'enabled', 'name', 'secret' ], expect: { '': {} }
});

function valueOr(value, fallback = '—') {
	return value == null || value === '' ? fallback : String(value);
}

function badge(text, good) {
	return E('span', {
		style: `display:inline-block;padding:2px 8px;border-radius:99px;font-weight:650;` +
			`background:${good ? 'rgba(27,143,85,.13)' : 'rgba(196,61,61,.13)'};` +
			`color:${good ? '#1b8f55' : '#c43d3d'}`
	}, text);
}

return view.extend({
	load() {
		return callStatus();
	},

	apply(enabled) {
		let name = document.getElementById('rg-cluster-name')?.value || '';
		let secret = document.getElementById('rg-cluster-secret')?.value || '';
		if (enabled && !/^[A-Za-z0-9._-]{1,32}$/.test(name)) {
			ui.addNotification(null, E('p', {}, _('Use 1–32 letters, digits, dots, dashes, or underscores for the cluster name.')), 'error');
			return;
		}
		if (enabled && (secret.length < 12 || secret.length > 128)) {
			ui.addNotification(null, E('p', {}, _('The shared cluster secret must contain 12–128 characters.')), 'error');
			return;
		}
		ui.showModal(enabled ? _('Joining wired AP cluster') : _('Leaving wired AP cluster'), [
			E('p', { class: 'spinning' }, _('Updating authenticated discovery and restarting the radios…'))
		]);
		return callConfigure(enabled, name, secret).then(result => {
			if (!result?.success)
				throw new Error(_('Cluster configuration was rejected (exit code %s).').format(valueOr(result?.exit_code, '?')));
			return callStatus();
		}).then(status => {
			ui.hideModal();
			let root = document.getElementById('rg-cluster-root');
			if (root) dom.content(root, this.renderStatus(status));
			ui.addNotification(null, E('p', {}, enabled ?
				_('This AP joined the cluster. Configure every additional AP with the same name and secret.') :
				_('This AP is now operating in standalone mode.')));
		}).catch(error => {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, error.message || String(error)), 'error');
		});
	},

	renderStatus(data) {
		data ||= {};
		let cluster = data.cluster || {};
		let nodes = data.nodes || [];
		let rows = nodes.map(node => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, [ E('strong', {}, valueOr(node.hostname, node.device_id)), E('br'), E('small', {}, valueOr(node.device_id)) ]),
			E('td', { class: 'td' }, node.local ? _('This AP') : valueOr(node.address)),
			E('td', { class: 'td' }, badge(node.available ? _('Online') : _('Unavailable'), node.available)),
			E('td', { class: 'td' }, valueOr(node.release)),
			E('td', { class: 'td' }, _('%d radios · %d clients').format(
				(node.radios || []).filter(r => r.online).length,
				(node.radios || []).reduce((sum, r) => sum + Number(r.client_count || 0), 0)))
		]));
		if (!rows.length)
			rows.push(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 5 }, _('No cluster nodes are visible.'))));
		return E('div', {}, [
			E('div', { class: `alert-message ${cluster.ready ? 'success' : 'notice'}` }, cluster.enabled ?
				_('%s · ID %s · %d/%d nodes online · %s').format(
					valueOr(cluster.name), valueOr(cluster.id), Number(cluster.online_count || 0),
					Number(cluster.node_count || 0), cluster.config_synced ? _('configuration synchronized') : _('configuration differs')) :
				_('Standalone mode. Create or join a cluster to enable authenticated N-node discovery.')),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Wired cluster members')),
				E('div', { class: 'cbi-section-descr' }, _('Members are discovered with mDNS across the Ethernet backhaul. Status RPCs are authenticated with HMAC; multicast discovery alone grants no access.')),
				E('div', { style: 'overflow-x:auto' }, E('table', { class: 'table' }, [
					E('tr', { class: 'tr table-titles' }, [
						E('th', { class: 'th' }, _('Node')), E('th', { class: 'th' }, _('Address')),
						E('th', { class: 'th' }, _('Status')), E('th', { class: 'th' }, _('Firmware')),
						E('th', { class: 'th' }, _('Wireless load'))
					]), ...rows
				]))
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, cluster.enabled ? _('Change cluster credentials') : _('Create or join a cluster')),
				E('div', { class: 'cbi-section-descr' }, _('Enter the exact same name and secret on every RG-MA2820(T). The secret is stored only as a SHA-256-derived key and is never returned by the API.')),
				E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title', for: 'rg-cluster-name' }, _('Cluster name')), E('div', { class: 'cbi-value-field' }, E('input', { id: 'rg-cluster-name', class: 'cbi-input-text', value: cluster.name || '', maxlength: 32 })) ]),
				E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title', for: 'rg-cluster-secret' }, _('Shared secret')), E('div', { class: 'cbi-value-field' }, E('input', { id: 'rg-cluster-secret', class: 'cbi-input-password', type: 'password', value: '', minlength: 12, maxlength: 128, autocomplete: 'new-password' })) ]),
				E('div', { class: 'cbi-page-actions' }, [
					E('button', { class: 'btn cbi-button cbi-button-apply', click: () => this.apply(true) }, cluster.enabled ? _('Rotate credentials / rejoin') : _('Create / join cluster')),
					cluster.enabled ? E('button', { class: 'btn cbi-button cbi-button-negative', click: () => this.apply(false) }, _('Leave cluster')) : ''
				])
			])
		]);
	},

	update() {
		return callStatus().then(status => {
			let root = document.getElementById('rg-cluster-root');
			if (root) dom.content(root, this.renderStatus(status));
		});
	},

	render(data) {
		poll.add(() => this.update(), 10);
		return E('div', {}, [
			E('h2', {}, _('RG-MA2820 wired AP cluster')),
			E('div', { class: 'cbi-map-descr' }, _('The cluster is controllerless and supports any practical number of APs on the same wired Layer-2 network. 802.11r uses a shared wildcard key-holder configuration; 802.11k/v neighbor data is refreshed from every authenticated member.')),
			E('div', { id: 'rg-cluster-root' }, this.renderStatus(data))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
