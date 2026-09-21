'use strict';
'require view';
'require form';
'require rpc';
'require poll';
'require ui';
'require dom';

const CONFIG_PARAMS = [
	'scope', 'radio_2g_enabled', 'radio_5g_enabled',
	'ssid_2g', 'ssid_5g', 'ssid_5g_legacy', 'enable_5g_legacy',
	'security_2g', 'security_5g', 'security_5g_legacy',
	'password_2g', 'password_5g', 'password_5g_legacy',
	'hidden_2g', 'hidden_5g', 'hidden_5g_legacy',
	'isolate_2g', 'isolate_5g', 'isolate_5g_legacy',
	'max_clients_2g', 'max_clients_5g', 'max_clients_5g_legacy',
	'mfp_2g', 'mfp_5g', 'mfp_5g_legacy', 'ft_2g', 'ft_5g', 'ft_5g_legacy',
	'country', 'channel_2g', 'channel_5g', 'width_5g',
	'txpower_2g', 'txpower_5g', 'beacon_interval', 'dtim_period',
	'ieee80211k', 'ieee80211v', 'mobility_domain', 'ft_over_ds',
	'he_2g', 'he_5g', 'bss_color_2g', 'bss_color_5g',
	'airtime_fairness', 'frameburst', 'beamforming', 'implicit_beamforming',
	'mu_features', 'ampdu', 'amsdu', 'ldpc', 'stbc_tx', 'stbc_rx', 'sgi_tx',
	'acl_mode', 'acl_macs', 'roam_steering', 'roam_band_2g', 'roam_band_5g',
	'roam_interval', 'roam_rssi', 'hard_rssi', 'roam_samples', 'roam_cooldown',
	'roam_min_age', 'hard_fallback', 'hard_delay', 'hard_window'
];

const BOOL_FIELDS = new Set([
	'radio_2g_enabled', 'radio_5g_enabled', 'enable_5g_legacy',
	'hidden_2g', 'hidden_5g', 'hidden_5g_legacy',
	'isolate_2g', 'isolate_5g', 'isolate_5g_legacy',
	'ft_2g', 'ft_5g', 'ft_5g_legacy', 'ieee80211k', 'ieee80211v', 'ft_over_ds',
	'he_2g', 'he_5g', 'airtime_fairness', 'frameburst', 'beamforming',
	'implicit_beamforming', 'mu_features', 'ampdu', 'amsdu', 'ldpc',
	'stbc_tx', 'stbc_rx', 'roam_steering', 'roam_band_2g', 'roam_band_5g',
	'hard_fallback'
]);

const INT_FIELDS = new Set([
	'max_clients_2g', 'max_clients_5g', 'max_clients_5g_legacy',
	'beacon_interval', 'dtim_period', 'roam_interval', 'roam_rssi', 'hard_rssi',
	'roam_samples', 'roam_cooldown', 'roam_min_age', 'hard_delay', 'hard_window'
]);

const callStatus = rpc.declare({
	object: 'luci.rg-ma2820', method: 'status', expect: { '': {} }
});

const callCapabilities = rpc.declare({
	object: 'luci.rg-ma2820', method: 'capabilities', expect: { '': {} }
});

const callConfigure = rpc.declare({
	object: 'luci.rg-ma2820', method: 'configure', params: CONFIG_PARAMS,
	expect: { '': {} }
});

const callAction = rpc.declare({
	object: 'luci.rg-ma2820', method: 'action', params: [ 'action', 'interface', 'mac' ],
	expect: { '': {} }
});

const callScan = rpc.declare({
	object: 'luci.rg-ma2820', method: 'scan', params: [ 'interface' ],
	expect: { '': {} }
});

function valueOr(value, fallback) {
	return value == null || value === '' ? (fallback == null ? '-' : fallback) : String(value);
}

function formatDuration(seconds) {
	seconds = Number(seconds || 0);
	if (seconds < 60)
		return _('%d s').format(seconds);
	if (seconds < 3600)
		return _('%d min').format(Math.floor(seconds / 60));
	return _('%d h %d min').format(Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60));
}

function formatRate(kbps) {
	kbps = Number(kbps || 0);
	return kbps >= 1000 ? _('%s Mbit/s').format((kbps / 1000).toFixed(kbps >= 100000 ? 0 : 1)) : _('%s kbit/s').format(kbps);
}

function formatBytes(bytes) {
	bytes = Number(bytes || 0);
	if (bytes >= 1073741824) return _('%s GiB').format((bytes / 1073741824).toFixed(1));
	if (bytes >= 1048576) return _('%s MiB').format((bytes / 1048576).toFixed(1));
	if (bytes >= 1024) return _('%s KiB').format((bytes / 1024).toFixed(1));
	return _('%s B').format(bytes);
}

function signalText(rssi) {
	if (rssi <= -90) return _('%d dBm (very weak)').format(rssi);
	if (rssi <= -80) return _('%d dBm (weak)').format(rssi);
	if (rssi <= -70) return _('%d dBm (fair)').format(rssi);
	return _('%d dBm (good)').format(rssi);
}

function securityLabel(mode, ft, mfp) {
	let label = ({
		open: _('Open'), wpa2: _('WPA2-PSK / CCMP'), wpa3: _('WPA3-SAE'),
		'wpa2-wpa3': _('WPA2/WPA3 transition')
	})[mode] || mode;
	if (ft) label += ' + 802.11r';
	if (Number(mfp) === 2) label += ' + ' + _('MFP required');
	else if (Number(mfp) === 1) label += ' + ' + _('MFP optional');
	return label;
}

function normalizeFormData(config) {
	let normalized = Object.assign({}, config || {});
	for (const field of BOOL_FIELDS)
		normalized[field] = normalized[field] ? '1' : '0';
	for (const field of CONFIG_PARAMS)
		if (normalized[field] == null)
			normalized[field] = '';
	normalized.scope = [ 'local', 'pair', 'cluster' ].includes(normalized.scope) ? normalized.scope : 'local';
	normalized.password_2g = '';
	normalized.password_5g = '';
	normalized.password_5g_legacy = '';
	return { settings: normalized };
}

function validateSSID(sectionId, value) {
	if (!/^[\x20-\x7e]+$/.test(value || '') || value.includes("'") || value.length > 32)
		return _('Use 1–32 printable ASCII characters; apostrophes are not supported.');
	return true;
}

function validatePassword(sectionId, value) {
	if (!value)
		return true;
	if (!/^[\x20-\x7e]{8,63}$/.test(value) || value.includes("'") || /^ | $/.test(value))
		return _('Use 8–63 printable ASCII characters without apostrophes or leading/trailing spaces.');
	return true;
}

function validateRequiredPassword(value, hasExisting, enabled, security) {
	let basic = validatePassword(null, value);
	if (basic !== true)
		return basic;
	if (enabled === '1' && security !== 'open' && !value && !hasExisting)
		return _('Enter a passphrase because this WLAN does not have an existing secret.');
	return true;
}

function valid5GHzCombination(channel, width) {
	if (channel === 'auto' || width === '20')
		return true;
	if (width === '40')
		return ![ '173' ].includes(channel);
	if (width === '80')
		return ![ '165', '169', '173' ].includes(channel);
	return false;
}

function validateTxPower(sectionId, value) {
	return value === 'auto' || (/^[0-9]+$/.test(value) && +value >= 1 && +value <= 31) ||
		_('Enter “auto” or a value from 1 to 31 dBm.');
}

function validateBssColor(sectionId, value) {
	return value === 'auto' || (/^[0-9]+$/.test(value) && +value >= 1 && +value <= 63) ||
		_('Enter “auto” or a BSS color from 1 to 63.');
}

function validateAcl(sectionId, value) {
	if (!value) return true;
	let entries = value.split(/[\s,]+/).filter(Boolean);
	return entries.every(v => /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(v)) ||
		_('Enter comma- or space-separated MAC addresses.');
}

return view.extend({
	load() {
		return Promise.all([ callStatus(), callCapabilities() ]);
	},

	notify(message, danger) {
		ui.addNotification(null, E('p', {}, message), danger ? 'danger' : 'info');
	},

	handleAction(action, iface, mac, ev) {
		if (action === 'disconnect' && !window.confirm(_('Disconnect this client from the current BSS?')))
			return Promise.resolve();
		let button = ev?.currentTarget;
		if (button) {
			button.disabled = true;
			button.classList.add('spinning');
		}
		return callAction(action, iface || '', mac || '').then(result => {
			if (!result?.success)
				throw new Error(_('The operation failed (exit code %s).').format(valueOr(result?.exit_code, '?')));
			let message = action === 'steer' ? _('A standards-based BSS transition request was sent.') :
				action === 'disconnect' ? _('The client was disconnected.') :
				action === 'refresh_neighbors' ? _('Wired peer neighbors are being refreshed.') :
				_('The radios restarted and clients will reconnect shortly.');
			this.notify(message);
			return callStatus().then(status => this.updateStatus(status));
		}).catch(error => this.notify(error.message, true)).finally(() => {
			if (button) {
				button.disabled = false;
				button.classList.remove('spinning');
			}
		});
	},

	handleScan(iface, ev) {
		let button = ev?.currentTarget;
		if (button) {
			button.disabled = true;
			button.classList.add('spinning');
		}
		return callScan(iface).then(result => {
			if (result?.error)
				throw new Error(_('Wireless scan failed: %s').format(result.error));
			this.scanResults ??= {};
			this.scanResults[iface] = result.networks || [];
			this.updateScanResults();
		}).catch(error => this.notify(error.message, true)).finally(() => {
			if (button) {
				button.disabled = false;
				button.classList.remove('spinning');
			}
		});
	},

	renderClients(radio, peerView) {
		let rows = (radio.clients || []).map(client => E('tr', { class: 'tr' }, [
			E('td', { class: 'td', 'data-title': _('Client') }, [
				E('strong', {}, client.mac), E('br'),
				E('small', {}, client.ip_address || _('IP address unknown'))
			]),
			E('td', { class: 'td', 'data-title': _('Signal') }, [
				signalText(client.rssi), E('br'),
				E('small', {}, _('Noise %d dBm · %d MHz').format(client.noise, client.bandwidth_mhz))
			]),
			E('td', { class: 'td', 'data-title': _('PHY / security') }, [
				client.phy || '-', E('br'), E('small', {}, client.security || '-')
			]),
			E('td', { class: 'td', 'data-title': _('Traffic') }, [
				_('TX %s / RX %s').format(formatRate(client.tx_rate_kbps), formatRate(client.rx_rate_kbps)),
				E('br'), E('small', {}, _('%s / %s · %d retries').format(formatBytes(client.tx_bytes), formatBytes(client.rx_bytes), client.tx_retries))
			]),
			E('td', { class: 'td', 'data-title': _('Roaming') }, [
				_('802.11k: %s · 802.11v: %s').format(client.rrm ? _('yes') : _('no'), client.bss_transition ? _('yes') : _('no')),
				E('br'), E('small', {}, _('Connected %s · idle %s').format(formatDuration(client.connected_seconds), formatDuration(client.idle_seconds)))
			]),
			E('td', { class: 'td', 'data-title': _('Actions') }, [
				peerView ? E('small', {}, _('Read-only peer snapshot')) : (radio.steering ? E('button', {
					class: 'btn cbi-button cbi-button-action',
					click: ev => this.handleAction('steer', radio.interface, client.mac, ev)
				}, _('Steer')) : ''),
				peerView ? '' : ' ',
				peerView ? '' : E('button', {
					class: 'btn cbi-button cbi-button-negative',
					click: ev => this.handleAction('disconnect', radio.interface, client.mac, ev)
				}, _('Disconnect'))
			])
		]));
		if (!rows.length)
			rows.push(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: 6 }, _('No clients are associated.'))));
		return E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' }, [
				E('th', { class: 'th' }, _('Client')), E('th', { class: 'th' }, _('Signal')),
				E('th', { class: 'th' }, _('PHY / security')), E('th', { class: 'th' }, _('Traffic')),
				E('th', { class: 'th' }, _('Roaming')), E('th', { class: 'th' }, _('Actions'))
			]), ...rows
		]);
	},

	renderRadioStatus(radio, nodeName, peerView) {
		return E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('%s · %s · %s GHz · %s').format(
				nodeName, radio.online ? _('ONLINE') : _('OFFLINE'), radio.band === '2g' ? '2.4' : '5', radio.ssid)),
			E('div', { class: 'cbi-section-descr' },
				_('Interface %s · BSSID %s · channel %s/%s MHz · TX %s dBm · noise %d dBm · color %d · %s · %d/%d clients').format(
					radio.interface, valueOr(radio.bssid), valueOr(radio.channel), valueOr(radio.width), valueOr(radio.txpower_dbm),
					radio.noise_dbm, radio.bss_color, securityLabel(radio.security, radio.fast_transition, radio.mfp),
					radio.client_count || 0, radio.max_clients || 0)),
			this.renderClients(radio, peerView)
		]);
	},

	renderStatus(data) {
		if (!data || data.error)
			return E('div', { class: 'alert-message error' }, _('Unable to read radio status: %s').format(valueOr(data?.error, _('unknown error'))));
		let warnings = {
			recovery_mode: _('Immutable recovery is active. Wi-Fi settings are read-only and vendor radios are intentionally unavailable.'),
			peer_offline: _('The wired peer is offline.'),
			config_drift: _('The two APs do not have the same mesh configuration.'),
			channel_overlap: _('The AP channel plan overlaps or has not converged yet.'),
			radio_offline: _('A configured radio or BSS is offline.'),
			txpower_mismatch: _('A radio did not apply the configured transmit-power policy.'),
			dfs_channel: _('The selected 5 GHz channel requires DFS/radar handling.'),
			legacy_schema: _('The saved settings use the legacy schema and will be upgraded on the next apply.'),
			cluster_node_offline: _('One or more discovered cluster nodes did not return an authenticated live snapshot.')
		};
		let slot = _('running %s · accepted %s').format(valueOr(data.running_slot), valueOr(data.accepted_slot));
		if (data.trial_slot && data.trial_slot !== 'none') slot += ' · ' + _('trial %s').format(data.trial_slot);
		if (data.pending_slot && data.pending_slot !== 'none') slot += ' · ' + _('pending %s').format(data.pending_slot);
		let summaryText = data.cluster?.enabled ?
			_('%s · firmware %s · %s · cluster %s · %d/%d nodes online · roaming %s').format(
				data.hostname, valueOr(data.release), slot, valueOr(data.cluster.name),
				Number(data.cluster.online_count || 0), Number(data.cluster.node_count || 0),
				data.mesh_ready ? _('READY') : _('DEGRADED')) :
			_('%s · firmware %s · %s · standalone roaming %s · local channels %s/%s').format(
				data.hostname, valueOr(data.release), slot, data.mesh_ready ? _('READY') : _('DEGRADED'),
				valueOr(data.radios?.[0]?.channel), valueOr(data.radios?.[1]?.channel));
		let summary = E('div', { class: `alert-message ${data.mesh_ready ? 'success' : 'warning'}` }, summaryText);
		let warningNodes = (data.warnings || []).map(code => E('div', {
			class: `alert-message ${[ 'recovery_mode', 'dfs_channel', 'legacy_schema' ].includes(code) ? 'notice' : 'warning'}`
		}, warnings[code] || code));
		let clusterNodes = data.cluster_nodes?.length ? data.cluster_nodes : [ {
			hostname: data.hostname, device_id: data.device_id, local: true,
			available: true, radios: data.radios || []
		} ];
		let radios = [];
		for (const node of clusterNodes) {
			if (!node.available) {
				radios.push(E('div', { class: 'alert-message warning' },
					_('Node %s is discovered but its authenticated status is unavailable.').format(node.hostname || node.device_id)));
				continue;
			}
			for (const radio of (node.radios || []))
				radios.push(this.renderRadioStatus(radio,
					node.local ? _('This AP: %s').format(node.hostname) : _('Cluster AP: %s').format(node.hostname || node.device_id),
					!node.local));
		}
		let events = data.events?.length ? data.events.join('\n') : _('No steering events have been recorded.');
		return E('div', {}, [ summary, ...warningNodes, ...radios,
			data.recovery ? '' : E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Recent roaming events')),
				E('pre', { style: 'white-space:pre-wrap;max-height:18em;overflow:auto' }, events)
			])
		]);
	},

	updateStatus(data) {
		let node = document.getElementById('rg-ma2820-live-status');
		if (node) dom.content(node, this.renderStatus(data));
	},

	renderScanResults() {
		let networks = [];
		for (const [ iface, entries ] of Object.entries(this.scanResults || {}))
			for (const entry of entries)
				networks.push(Object.assign({ interface: iface }, entry));
		networks.sort((a, b) => Number(b.rssi) - Number(a.rssi));
		if (!networks.length)
			return E('p', {}, _('Run a scan to inspect neighboring BSSs. Scanning briefly consumes radio airtime.'));
		return E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' }, [
				E('th', { class: 'th' }, _('Radio')), E('th', { class: 'th' }, _('SSID / BSSID')),
				E('th', { class: 'th' }, _('Channel')), E('th', { class: 'th' }, _('Signal')),
				E('th', { class: 'th' }, _('Security')), E('th', { class: 'th' }, _('Capabilities'))
			]),
			...networks.map(n => E('tr', { class: 'tr' }, [
				E('td', { class: 'td' }, n.interface),
				E('td', { class: 'td' }, [ E('strong', {}, n.ssid || _('<hidden>')), E('br'), E('small', {}, n.bssid) ]),
				E('td', { class: 'td' }, n.channel),
				E('td', { class: 'td' }, _('%d dBm / SNR %d dB').format(n.rssi, n.snr)),
				E('td', { class: 'td' }, n.security),
				E('td', { class: 'td' }, _('%s · k=%s · v=%s').format(n.phy, n.rrm ? _('yes') : _('no'), n.bss_transition ? _('yes') : _('no')))
			]))
		]);
	},

	updateScanResults() {
		let node = document.getElementById('rg-ma2820-scan-results');
		if (node) dom.content(node, this.renderScanResults());
	},

	renderCapabilities(capabilities) {
		if (!capabilities || capabilities.error)
			return E('div', { class: 'alert-message warning' }, _('Driver capability detection failed.'));
		return E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('Detected driver capabilities')),
			E('div', { class: 'cbi-section-descr' },
				_('%s · %s · 2×2 spatial streams · vendor nl80211 integration (not mac80211/netifd)').format(capabilities.driver, capabilities.hostapd)),
			E('table', { class: 'table' }, [
				E('tr', { class: 'tr table-titles' }, [
					E('th', { class: 'th' }, _('Radio')), E('th', { class: 'th' }, _('Hardware')),
					E('th', { class: 'th' }, _('Widths')), E('th', { class: 'th' }, _('Channels')),
					E('th', { class: 'th' }, _('Live acceleration'))
				]),
				...(capabilities.radios || []).map(radio => E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, `${radio.interface} · ${radio.band === '2g' ? '2.4' : '5'} GHz`),
					E('td', { class: 'td' }, _('%s / core %s / PHY %s').format(radio.device_id, radio.core_revision, radio.phy_revision)),
					E('td', { class: 'td' }, (radio.widths || []).map(w => `${w} MHz`).join(', ')),
					E('td', { class: 'td' }, (radio.channels || []).join(', ')),
					E('td', { class: 'td' }, [
						_('HE %s · AMPDU %s · AMSDU %s · BF %s · MU %s · TAF %s').format(
							radio.runtime?.wifi6 ? _('on') : _('off'), radio.runtime?.ampdu ? _('on') : _('off'),
							radio.runtime?.amsdu ? _('on') : _('off'), radio.runtime?.beamforming ? _('on') : _('off'),
							radio.runtime?.mu_features ? _('on') : _('off'), radio.runtime?.airtime_fairness ? _('on') : _('off'))
					])
				]))
			]),
			E('details', {}, [
				E('summary', {}, _('Raw driver feature flags')),
				...(capabilities.radios || []).map(radio => E('p', {}, [ E('strong', {}, `${radio.interface}: `), (radio.features || []).join(', ') ]))
			])
		]);
	},

	addSecurityValues(option) {
		option.value('open', _('Open (no encryption)'));
		option.value('wpa2', _('WPA2-PSK (CCMP)'));
		option.value('wpa3', _('WPA3-SAE'));
		option.value('wpa2-wpa3', _('WPA2/WPA3 transition'));
	},

	addMfpValues(option) {
		option.value('0', _('Disabled'));
		option.value('1', _('Optional'));
		option.value('2', _('Required'));
	},

	buildForm(status, capabilities) {
		this.formData = normalizeFormData(status.config);
		let m = this.map = new form.JSONMap(this.formData,
			_('Wi-Fi and wired roaming configuration'),
			_('This page drives the Broadcom vendor stack directly because these radios are not managed by mac80211/netifd. Save & Apply validates the complete profile before changing the selected AP scope.'));
		m.readonly = !!status.recovery || !L.hasViewPermission();
		let s = m.section(form.NamedSection, 'settings', 'settings');
		s.anonymous = true;
		s.tab('general', _('General'));
		s.tab('radio2', _('2.4 GHz'));
		s.tab('radio5', _('5 GHz'));
		s.tab('roaming', _('Roaming & mesh'));
		s.tab('advanced', _('Driver advanced'));
		let o;

		o = s.taboption('general', form.ListValue, 'scope', _('Apply target'),
			status.cluster?.enabled ? _('Cluster mode authenticates every discovered wired AP with the shared cluster key, validates all nodes, then applies the profile.') :
			_('Pair mode updates the peer first over pinned-key SSH, then this AP.'));
		if (status.cluster?.enabled) o.value('cluster', _('All authenticated cluster APs (recommended)'));
		else if (!status.cluster) o.value('pair', _('Both wired APs (recommended)'));
		o.value('local', _('This AP only'));
		o.rmempty = false;

		o = s.taboption('general', form.Value, 'country', _('Driver country profile'),
			_('Choose the profile that matches the installation location. This controls channel and power constraints; Broadcom pseudo-domains may not be lawful in your jurisdiction.'));
		o.rmempty = false;
		o.value('#a', _('#a — Broadcom all-channel profile'));
		for (const country of (capabilities.countries || []))
			if (country.code !== '#a') o.value(country.code, country.name ? `${country.code} — ${country.name}` : country.code);

		o = s.taboption('general', form.Value, 'beacon_interval', _('Beacon interval'), _('Time units; 100 is the compatibility default.'));
		o.datatype = 'range(50,1000)'; o.rmempty = false;
		o = s.taboption('general', form.Value, 'dtim_period', _('DTIM period'), _('Lower values wake power-saving clients more often.'));
		o.datatype = 'range(1,255)'; o.rmempty = false;

		o = s.taboption('radio2', form.Flag, 'radio_2g_enabled', _('Enable 2.4 GHz radio'));
		o.rmempty = false;
		o.validate = (sid, value) => value === '1' || s.formvalue(sid, 'radio_5g_enabled') === '1' ||
			_('At least one radio must remain enabled.');
		o = s.taboption('radio2', form.Value, 'ssid_2g', _('SSID'));
		o.validate = validateSSID; o.rmempty = false; o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.ListValue, 'security_2g', _('Security mode'));
		this.addSecurityValues(o); o.rmempty = false; o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Value, 'password_2g', _('New passphrase'), _('Leave empty to keep the current secret.'));
		o.password = true;
		o.validate = (sid, value) => validateRequiredPassword(value, !!status.config?.has_password_2g,
			s.formvalue(sid, 'radio_2g_enabled'), s.formvalue(sid, 'security_2g'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_2g_enabled: '1', security_2g: mode });
		o = s.taboption('radio2', form.ListValue, 'mfp_2g', _('Management frame protection'));
		this.addMfpValues(o); o.depends({ radio_2g_enabled: '1', security_2g: 'wpa2' });
		o = s.taboption('radio2', form.Flag, 'ft_2g', _('802.11r fast transition'), _('Disabled by default for IoT and camera compatibility.'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_2g_enabled: '1', security_2g: mode });
		o = s.taboption('radio2', form.Flag, 'hidden_2g', _('Hide SSID')); o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Flag, 'isolate_2g', _('Client isolation')); o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Value, 'max_clients_2g', _('Maximum clients'));
		o.datatype = 'range(1,128)'; o.rmempty = false; o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.ListValue, 'channel_2g', _('Channel'));
		o.value('auto', _('Automatic (peer-aware 1/6/11)'));
		for (const channel of (capabilities.radios?.find(r => r.band === '2g')?.channels || [1, 6, 11])) o.value(String(channel));
		o.validate = (sid, value) => s.formvalue(sid, 'scope') === 'local' || value === 'auto' ||
			_('Multi-AP mode requires automatic channels; use local mode for a manual channel plan.');
		o.rmempty = false; o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Value, 'txpower_2g', _('Transmit power (dBm)'));
		o.value('auto', _('Automatic')); o.validate = validateTxPower; o.rmempty = false; o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Flag, 'he_2g', _('Wi-Fi 6 (802.11ax)')); o.depends('radio_2g_enabled', '1');
		o = s.taboption('radio2', form.Value, 'bss_color_2g', _('HE BSS color'));
		o.value('auto', _('Driver selected')); o.validate = validateBssColor; o.rmempty = false; o.depends({ radio_2g_enabled: '1', he_2g: '1' });

		o = s.taboption('radio5', form.Flag, 'radio_5g_enabled', _('Enable 5 GHz radio')); o.rmempty = false;
		o.validate = (sid, value) => value === '1' || s.formvalue(sid, 'radio_2g_enabled') === '1' ||
			_('At least one radio must remain enabled.');
		o = s.taboption('radio5', form.Value, 'ssid_5g', _('Primary SSID'));
		o.validate = validateSSID; o.rmempty = false; o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.ListValue, 'security_5g', _('Primary security'));
		this.addSecurityValues(o); o.rmempty = false; o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Value, 'password_5g', _('New primary passphrase'), _('Leave empty to keep the current secret.'));
		o.password = true;
		o.validate = (sid, value) => validateRequiredPassword(value, !!status.config?.has_password_5g,
			s.formvalue(sid, 'radio_5g_enabled'), s.formvalue(sid, 'security_5g'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_5g_enabled: '1', security_5g: mode });
		o = s.taboption('radio5', form.ListValue, 'mfp_5g', _('Primary management frame protection'));
		this.addMfpValues(o); o.depends({ radio_5g_enabled: '1', security_5g: 'wpa2' });
		o = s.taboption('radio5', form.Flag, 'ft_5g', _('Primary 802.11r fast transition'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_5g_enabled: '1', security_5g: mode });
		o = s.taboption('radio5', form.Flag, 'hidden_5g', _('Hide primary SSID')); o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Flag, 'isolate_5g', _('Primary client isolation')); o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Value, 'max_clients_5g', _('Primary maximum clients'));
		o.datatype = 'range(1,128)'; o.rmempty = false; o.depends('radio_5g_enabled', '1');

		o = s.taboption('radio5', form.Flag, 'enable_5g_legacy', _('Enable compatibility BSS'), _('A second 5 GHz BSS for clients that need WPA2.'));
		o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Value, 'ssid_5g_legacy', _('Compatibility SSID'));
		o.validate = validateSSID; o.rmempty = false; o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1' });
		o = s.taboption('radio5', form.ListValue, 'security_5g_legacy', _('Compatibility security'));
		this.addSecurityValues(o); o.rmempty = false; o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1' });
		o = s.taboption('radio5', form.Value, 'password_5g_legacy', _('New compatibility passphrase'), _('Leave empty to keep the current secret.'));
		o.password = true;
		o.validate = (sid, value) => validateRequiredPassword(value, !!status.config?.has_password_5g_legacy,
			s.formvalue(sid, 'enable_5g_legacy'), s.formvalue(sid, 'security_5g_legacy'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1', security_5g_legacy: mode });
		o = s.taboption('radio5', form.ListValue, 'mfp_5g_legacy', _('Compatibility management frame protection'));
		this.addMfpValues(o); o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1', security_5g_legacy: 'wpa2' });
		o = s.taboption('radio5', form.Flag, 'ft_5g_legacy', _('Compatibility 802.11r fast transition'));
		for (const mode of [ 'wpa2', 'wpa3', 'wpa2-wpa3' ]) o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1', security_5g_legacy: mode });
		o = s.taboption('radio5', form.Flag, 'hidden_5g_legacy', _('Hide compatibility SSID')); o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1' });
		o = s.taboption('radio5', form.Flag, 'isolate_5g_legacy', _('Compatibility client isolation')); o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1' });
		o = s.taboption('radio5', form.Value, 'max_clients_5g_legacy', _('Compatibility maximum clients'));
		o.datatype = 'range(1,128)'; o.rmempty = false; o.depends({ radio_5g_enabled: '1', enable_5g_legacy: '1' });

		o = s.taboption('radio5', form.ListValue, 'channel_5g', _('Channel'));
		o.value('auto', _('Automatic (peer-aware non-DFS blocks)'));
		for (const channel of (capabilities.radios?.find(r => r.band === '5g')?.channels || [36, 149])) o.value(String(channel));
		o.validate = (sid, value) => {
			if (s.formvalue(sid, 'scope') !== 'local' && value !== 'auto')
				return _('Multi-AP mode requires automatic channels; use local mode for a manual channel plan.');
			return valid5GHzCombination(value, s.formvalue(sid, 'width_5g')) ||
				_('The selected channel is not valid at this 5 GHz width.');
		};
		o.rmempty = false; o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.ListValue, 'width_5g', _('Channel width'));
		for (const width of (capabilities.radios?.find(r => r.band === '5g')?.widths || [20, 40, 80])) o.value(String(width), _('%d MHz').format(width));
		o.validate = (sid, value) => valid5GHzCombination(s.formvalue(sid, 'channel_5g'), value) ||
			_('The selected channel is not valid at this 5 GHz width.');
		o.rmempty = false; o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Value, 'txpower_5g', _('Transmit power (dBm)'));
		o.value('auto', _('Automatic')); o.validate = validateTxPower; o.rmempty = false; o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Flag, 'he_5g', _('Wi-Fi 6 (802.11ax)')); o.depends('radio_5g_enabled', '1');
		o = s.taboption('radio5', form.Value, 'bss_color_5g', _('HE BSS color'));
		o.value('auto', _('Driver selected')); o.validate = validateBssColor; o.rmempty = false; o.depends({ radio_5g_enabled: '1', he_5g: '1' });

		o = s.taboption('roaming', form.Flag, 'ieee80211k', _('802.11k neighbor reports'));
		o = s.taboption('roaming', form.Flag, 'ieee80211v', _('802.11v BSS transition'));
		o = s.taboption('roaming', form.Value, 'mobility_domain', _('802.11r mobility domain'), _('Exactly four hexadecimal digits, shared by every AP. Cluster mode derives this automatically from the cluster key.'));
		o.validate = (sid, value) => /^[0-9a-f]{4}$/i.test(value) || _('Enter exactly four hexadecimal digits.'); o.rmempty = false;
		o = s.taboption('roaming', form.Flag, 'ft_over_ds', _('802.11r over the distribution system'), _('Disabled uses over-the-air FT, which has broader client interoperability.'));
		o = s.taboption('roaming', form.Flag, 'roam_steering', _('Active RSSI steering'), _('Clients still make the final roaming decision; this controller sends standards-based 802.11v requests.'));
		o = s.taboption('roaming', form.Flag, 'roam_band_2g', _('Steer 2.4 GHz clients'), _('Keep disabled for conservative IoT/camera behavior.')); o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Flag, 'roam_band_5g', _('Steer 5 GHz clients')); o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'roam_interval', _('Sampling interval (seconds)')); o.datatype = 'range(2,60)'; o.rmempty = false; o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'roam_rssi', _('Soft steering threshold (dBm)')); o.datatype = 'range(-90,-50)'; o.rmempty = false; o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'roam_samples', _('Consecutive weak samples')); o.datatype = 'range(1,20)'; o.rmempty = false; o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'roam_cooldown', _('Steering cooldown (seconds)')); o.datatype = 'range(15,3600)'; o.rmempty = false; o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'roam_min_age', _('Minimum association age (seconds)')); o.datatype = 'range(0,3600)'; o.rmempty = false; o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Flag, 'hard_fallback', _('Hard fallback for persistently weak clients')); o.depends('roam_steering', '1');
		o = s.taboption('roaming', form.Value, 'hard_rssi', _('Hard fallback threshold (dBm)'));
		o.datatype = 'range(-95,-51)'; o.rmempty = false; o.depends({ roam_steering: '1', hard_fallback: '1' });
		o.validate = (sid, value) => Number(value) < Number(s.formvalue(sid, 'roam_rssi')) ||
			_('The hard threshold must be lower than the soft steering threshold.');
		o = s.taboption('roaming', form.Value, 'hard_delay', _('Hard fallback delay (seconds)')); o.datatype = 'range(5,300)'; o.rmempty = false; o.depends({ roam_steering: '1', hard_fallback: '1' });
		o = s.taboption('roaming', form.Value, 'hard_window', _('Hard fallback window (seconds)'));
		o.datatype = 'range(6,600)'; o.rmempty = false; o.depends({ roam_steering: '1', hard_fallback: '1' });
		o.validate = (sid, value) => Number(value) > Number(s.formvalue(sid, 'hard_delay')) ||
			_('The hard fallback window must be longer than its delay.');

	for (const [ name, title, description ] of [
		[ 'airtime_fairness', _('Airtime fairness (TAF)'), _('Broadcom transmit airtime scheduler.') ],
		[ 'frameburst', _('Frame bursting'), _('Reduce contention overhead; may reduce fairness with neighboring networks.') ],
		[ 'beamforming', _('Explicit beamforming'), _('Use client feedback to steer transmitted energy.') ],
		[ 'implicit_beamforming', _('Implicit beamforming'), _('Estimate steering without explicit client feedback.') ],
		[ 'mu_features', _('Multi-user scheduling'), _('Enable driver MU-MIMO/OFDMA scheduling support.') ],
		[ 'ampdu', _('A-MPDU aggregation'), _('Aggregate MPDUs for higher throughput.') ],
		[ 'amsdu', _('A-MSDU aggregation'), _('Aggregate MSDUs for lower protocol overhead.') ],
		[ 'ldpc', _('LDPC coding'), _('Forward-error correction used by modern PHY modes.') ],
		[ 'stbc_tx', _('Transmit STBC'), _('Space-time block coding for transmit diversity.') ],
		[ 'stbc_rx', _('Receive STBC'), _('Advertise receive space-time block coding.') ]
	]) {
		o = s.taboption('advanced', form.Flag, name, title, description);
	}
		o = s.taboption('advanced', form.ListValue, 'sgi_tx', _('Guard interval policy'));
	for (const [ key, label ] of [
		[ '-1', _('Automatic') ], [ '0', _('Long / HE 1.6 µs') ], [ '1', _('Short / HE 0.8 µs') ],
		[ '2', _('Short, 1×LTF / HE 0.8 µs') ], [ '3', _('Short, 2×LTF / HE 0.8 µs') ],
		[ '4', _('Short, 2×LTF / HE 1.6 µs') ], [ '5', _('Short, 4×LTF / HE 3.2 µs') ]
	]) o.value(key, label);
		o.rmempty = false;
		o = s.taboption('advanced', form.ListValue, 'acl_mode', _('MAC access policy'));
		o.value('disabled', _('Disabled')); o.value('deny', _('Deny listed clients')); o.value('allow', _('Allow only listed clients')); o.rmempty = false;
		o = s.taboption('advanced', form.Value, 'acl_macs', _('MAC address list'), _('Comma- or space-separated; applies to every enabled BSS.'));
		o.validate = validateAcl; o.depends('acl_mode', 'deny'); o.depends('acl_mode', 'allow');
		// Hidden options are still part of the complete atomic profile. Keeping
		// them avoids silently erasing the inactive radio/BSS configuration.
		for (const option of s.children)
			option.retain = true;
		return m;
	},

	render([ status, capabilities ]) {
		this.capabilities = capabilities || {};
		this.scanResults = {};
		let map = this.buildForm(status || {}, this.capabilities);
		poll.add(() => callStatus().then(data => this.updateStatus(data)), 5);
		return map.render().then(formNode => E('div', {}, [
			E('h2', {}, _('RG-MA2820 Wi-Fi & wired roaming')),
			E('div', { class: 'cbi-map-descr' },
				_('Ethernet is the backhaul. 802.11k/v and optional 802.11r help compatible clients move among every cluster AP; the client always makes the final roaming decision.')),
			E('div', { id: 'rg-ma2820-live-status' }, this.renderStatus(status)),
			formNode,
			status.recovery ? '' : E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Channel scan')),
				E('div', { class: 'cbi-section-descr' }, _('An explicit scan is never run automatically from this page.')),
				E('div', { class: 'cbi-page-actions' }, [
					E('button', { class: 'btn cbi-button cbi-button-action', click: ev => this.handleScan('wl0', ev) }, _('Scan 2.4 GHz')),
					' ', E('button', { class: 'btn cbi-button cbi-button-action', click: ev => this.handleScan('wl1', ev) }, _('Scan 5 GHz')),
					' ', E('button', { class: 'btn cbi-button cbi-button-action', click: ev => this.handleAction('refresh_neighbors', '', '', ev) }, _('Refresh peer neighbors')),
					' ', E('button', { class: 'btn cbi-button cbi-button-negative', click: ev => this.handleAction('reselect', '', '', ev) }, _('Rescan channels & restart'))
				]),
				E('div', { id: 'rg-ma2820-scan-results' }, this.renderScanResults())
			]),
			this.renderCapabilities(this.capabilities)
		]));
	},

	handleSaveApply() {
		let mapNode = document.querySelector('.cbi-map');
		return dom.callClassMethod(mapNode, 'save').then(() => {
			let config = this.formData.settings;
			let args = CONFIG_PARAMS.map(field => {
				if (BOOL_FIELDS.has(field)) return config[field] === '1';
				if (INT_FIELDS.has(field)) return Number(config[field]);
				return config[field] == null ? '' : String(config[field]);
			});
			ui.showModal(_('Applying Wi-Fi configuration'), [
				E('p', { class: 'spinning' }, config.scope !== 'local' ?
					_('Validating and applying the profile to every selected wired AP…') :
					_('Validating and applying the profile to this AP…'))
			]);
			return callConfigure(...args).then(result => {
				ui.hideModal();
				if (!result?.success)
					throw new Error(_('Configuration was rejected (exit code %s). No unvalidated local profile was installed.').format(valueOr(result?.exit_code, '?')));
				this.formData.settings.password_2g = '';
				this.formData.settings.password_5g = '';
				this.formData.settings.password_5g_legacy = '';
				this.notify(_('Wi-Fi configuration applied successfully. Clients may need a few seconds to reconnect.'));
				return callStatus().then(data => this.updateStatus(data));
			}).catch(error => {
				ui.hideModal();
				this.notify(error.message, true);
			});
		});
	},

	handleSave: null,
	handleReset() {
		window.location.reload();
	}
});
