'use strict';
'require view';
'require rpc';
'require poll';
'require dom';
'require ui';

const callOverview = rpc.declare({
	object: 'luci.rg-ma2820', method: 'overview', expect: { '': {} }
});

const callWireless = rpc.declare({
	object: 'luci.rg-ma2820', method: 'status', expect: { '': {} }
});

const callTimezoneStatus = rpc.declare({
	object: 'luci.rg-ma2820', method: 'timezone_status', expect: { '': {} }
});

const callConfigureTimezone = rpc.declare({
	object: 'luci.rg-ma2820', method: 'configure_timezone',
	params: [ 'zonename', 'automatic', 'scope' ], expect: { '': {} }, nobatch: true
});

const callTimezones = rpc.declare({
	object: 'luci', method: 'getTimezones', expect: { '': {} }
});

const timezoneAliases = {
	'Africa/Asmera': 'Africa/Asmara',
	'America/Buenos_Aires': 'America/Argentina/Buenos_Aires',
	'America/Godthab': 'America/Nuuk',
	'America/Indianapolis': 'America/Indiana/Indianapolis',
	'Asia/Calcutta': 'Asia/Kolkata',
	'Asia/Katmandu': 'Asia/Kathmandu',
	'Asia/Rangoon': 'Asia/Yangon',
	'Asia/Saigon': 'Asia/Ho_Chi_Minh',
	'Europe/Kiev': 'Europe/Kyiv',
	'Pacific/Ponape': 'Pacific/Pohnpei',
	'Pacific/Truk': 'Pacific/Chuuk',
	'US/Alaska': 'America/Anchorage',
	'US/Central': 'America/Chicago',
	'US/Eastern': 'America/New_York',
	'US/Hawaii': 'Pacific/Honolulu',
	'US/Mountain': 'America/Denver',
	'US/Pacific': 'America/Los_Angeles'
};

function browserTimezone(zones) {
	try {
		let detected = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
		if (!zones || detected === 'UTC' || zones[detected])
			return detected;
		let canonical = timezoneAliases[detected];
		return canonical && zones[canonical] ? canonical : detected;
	}
	catch (e) {
		return '';
	}
}

function valueOr(value, fallback) {
	return value == null || value === '' ? (fallback == null ? '—' : fallback) : String(value);
}

function formatBytes(bytes) {
	bytes = Number(bytes || 0);
	if (bytes >= 1073741824) return _('%s GiB').format((bytes / 1073741824).toFixed(1));
	if (bytes >= 1048576) return _('%s MiB').format((bytes / 1048576).toFixed(1));
	if (bytes >= 1024) return _('%s KiB').format((bytes / 1024).toFixed(1));
	return _('%s B').format(bytes);
}

function formatDuration(seconds) {
	seconds = Number(seconds || 0);
	let days = Math.floor(seconds / 86400);
	let hours = Math.floor((seconds % 86400) / 3600);
	let minutes = Math.floor((seconds % 3600) / 60);
	if (days) return _('%d d %d h').format(days, hours);
	if (hours) return _('%d h %d min').format(hours, minutes);
	return _('%d min').format(minutes);
}

function formatRate(kbps) {
	kbps = Number(kbps || 0);
	return kbps >= 1000 ? _('%s Mbit/s').format((kbps / 1000).toFixed(kbps >= 100000 ? 0 : 1)) : _('%s kbit/s').format(kbps);
}

function wirelessNodes(wireless) {
	if (wireless?.cluster_nodes?.length)
		return wireless.cluster_nodes.filter(node => node.available).map(node => ({
			device_id: node.device_id,
			hostname: node.hostname || node.device_id,
			local: !!node.local,
			radios: node.radios || []
		}));
	let nodes = [{
		device_id: wireless?.device_id || 'local',
		hostname: wireless?.hostname || _('This AP'),
		local: true,
		radios: wireless?.radios || []
	}];
	let peer = wireless?.peer_status;
	if (peer?.available)
		nodes.push({
			device_id: peer.device_id,
			hostname: peer.hostname || peer.device_id,
			local: false,
			radios: peer.radios || []
		});
	return nodes;
}

function collectWirelessClients(wireless) {
	let clients = [];
	for (const node of wirelessNodes(wireless))
		for (const radio of node.radios)
			for (const client of (radio.clients || []))
				clients.push({ node, radio, client });
	return clients;
}

function percent(used, total) {
	total = Number(total || 0);
	return total > 0 ? Math.max(0, Math.min(100, Math.round(Number(used || 0) * 100 / total))) : 0;
}

function badge(text, state) {
	return E('span', { class: `rg-badge rg-${state || 'neutral'}` }, text);
}

function indicatorLabel(status) {
	return ({
		normal: _('Normal operation'), online: _('Online'), ready: _('Ready'),
		probing: _('Checking'), degraded: _('Degraded'), offline: _('Offline'),
		addressing: _('Waiting for DHCP'), disabled: _('Disabled'), disconnected: _('No cable'),
		trial: _('Trial boot'), recovery: _('Recovery'), fault: _('Fault'),
		syncing: _('Synchronizing'), unknown: _('Unknown')
	})[status] || status || _('Unknown');
}

function indicatorSeverity(status) {
	if ([ 'normal', 'online', 'ready' ].includes(status)) return 'good';
	if ([ 'probing', 'addressing', 'trial', 'recovery', 'syncing' ].includes(status)) return 'warning';
	if ([ 'degraded', 'offline', 'fault' ].includes(status)) return 'error';
	return 'neutral';
}

function indicatorRow(label, status, detail) {
	return E('div', { class: 'rg-led-row' }, [
		E('div', {}, [ E('strong', {}, label), E('small', {}, detail) ]),
		badge(indicatorLabel(status), indicatorSeverity(status))
	]);
}

function wanIndicatorDetail(mode) {
	return mode === 'direction'
		? _('WAN socket only: steady green means linked; green flashes show received traffic and red flashes show transmitted traffic; red does not mean an error; off means no cable.')
		: _('WAN socket only: green means linked with a reachable gateway; activity flashes show WAN traffic; red means uplink failure; off means no cable.');
}

function keyValue(label, value, detail) {
	return E('div', { class: 'rg-kv' }, [
		E('span', { class: 'rg-kv-label' }, label),
		E('span', { class: 'rg-kv-value' }, valueOr(value)),
		detail ? E('small', {}, detail) : ''
	]);
}

function meter(label, used, total, formatter) {
	let pc = percent(used, total);
	return E('div', { class: 'rg-meter-block' }, [
		E('div', { class: 'rg-meter-label' }, [
			E('span', {}, label),
			E('strong', {}, _('%s of %s · %d%%').format(formatter(used), formatter(total), pc))
		]),
		E('div', { class: 'rg-meter' }, E('span', { style: `width:${pc}%` }))
	]);
}

function card(title, subtitle, content, span) {
	return E('section', { class: `rg-card rg-span-${span || 6}` }, [
		E('div', { class: 'rg-card-head' }, [
			E('h3', {}, title),
			subtitle ? E('small', {}, subtitle) : ''
		]),
		E('div', { class: 'rg-card-body' }, content)
	]);
}

function serviceLabel(id) {
	return ({
		ssh: _('SSH management'), web: _('Web interface'), rpc: _('LuCI RPC'),
		time: _('Time synchronization'), leds: _('LED controller'),
		neighbor_sync: _('Mesh neighbor sync'), roaming: _('Roaming controller')
	})[id] || id;
}

function warningText(code) {
	return ({
		recovery_mode: _('Immutable recovery is active. Wi-Fi settings are read-only and vendor radios are intentionally unavailable.'),
		peer_offline: _('The wired peer is offline.'),
		config_drift: _('The two APs do not have the same mesh configuration.'),
		channel_overlap: _('The AP channel plan overlaps or has not converged yet.'),
		radio_offline: _('A configured radio or BSS is offline.'),
		txpower_mismatch: _('A radio did not apply the configured transmit-power policy.'),
		dfs_channel: _('The selected 5 GHz channel requires DFS/radar handling.'),
		legacy_schema: _('The saved settings use the legacy schema and will be upgraded on the next apply.'),
		cluster_node_offline: _('One or more cluster nodes failed authenticated status collection.')
	})[code] || code;
}

function collectWarnings(system, wireless) {
	let warnings = [];
	let thermalTrip = Number(system?.system?.thermal_trip_mc || 110000);
	let thermalWarning = Math.max(82000, thermalTrip - 15000);
	let thermalCritical = Math.max(90000, thermalTrip - 5000);
	if (!system || system.error)
		warnings.push({ level: 'error', text: _('Unable to read the system dashboard data.') });
	if (!wireless || wireless.error)
		warnings.push({ level: 'error', text: _('Unable to read wireless and mesh status.') });
	if (!system || system.error)
		return warnings;
	if (system.boot?.recovery)
		warnings.push({ level: 'notice', text: _('The AP is running immutable recovery instead of a normal A/B system slot.') });
	if (Number(system.boot?.bad_peb_count) > 0)
		warnings.push({ level: 'error', text: _('NAND reports %d bad erase blocks.').format(system.boot.bad_peb_count) });
	if (!system.network?.management_cidr)
		warnings.push({ level: 'error', text: _('The management bridge does not have a DHCP address.') });
	if (!system.network?.gateway)
		warnings.push({ level: 'warning', text: _('No default gateway is installed; Internet access may be unavailable.') });
	if (system.leds?.power === 'fault')
		warnings.push({ level: 'error', text: _('The front-panel controller detected a core service, NAND, or thermal fault.') });
	if ([ 'degraded', 'offline' ].includes(system.leds?.uplink) && system.network?.gateway)
		warnings.push({ level: 'warning', text: _('The uplink gateway health check is failing.') });
	if (!wireless?.cluster && wireless?.peer_online && wireless?.peer_status && !wireless.peer_status.available)
		warnings.push({ level: 'warning', text: _('The peer AP is online, but its live radio and client snapshot is unavailable.') });
	if (Number(system.system?.temperature_mc) >= thermalCritical)
		warnings.push({ level: 'error', text: _('Device temperature is critical: %s °C.').format((system.system.temperature_mc / 1000).toFixed(1)) });
	else if (Number(system.system?.temperature_mc) >= thermalWarning)
		warnings.push({ level: 'warning', text: _('Device temperature is elevated: %s °C.').format((system.system.temperature_mc / 1000).toFixed(1)) });
	for (const service of (system.services || []))
		if (!service.running)
			warnings.push({ level: 'error', text: _('%s is not running.').format(serviceLabel(service.id)) });
	for (const code of (wireless?.warnings || []))
		warnings.push({ level: [ 'legacy_schema', 'dfs_channel', 'recovery_mode' ].includes(code) ? 'notice' : 'warning', text: warningText(code) });
	return warnings;
}

function dashboardStyle() {
	return E('style', {}, `
		h2[name="content"] { display:none }
		.rg-dashboard-root { --rg-blue:#1769d2; --rg-green:#1b8f55; --rg-amber:#b86b00; --rg-red:#c43d3d; color:inherit }
		.rg-hero { border-radius:14px; padding:22px 24px; margin:0 0 16px; color:#fff; background:linear-gradient(125deg,#17355f 0%,#1769d2 62%,#2585da 100%); box-shadow:0 8px 28px rgba(16,48,88,.22) }
		.rg-hero-top { display:flex; gap:20px; justify-content:space-between; align-items:flex-start }
		.rg-hero h2 { color:#fff; margin:0 0 4px; font-size:1.75rem }
		.rg-hero p { margin:0; color:rgba(255,255,255,.82) }
		.rg-health { border:1px solid rgba(255,255,255,.42); border-radius:999px; padding:7px 13px; font-weight:700; white-space:nowrap; background:rgba(255,255,255,.12) }
		.rg-hero-badges,.rg-actions,.rg-service-list { display:flex; flex-wrap:wrap; gap:8px }
		.rg-hero-badges { margin-top:18px }
		.rg-actions { margin-top:15px }
		.rg-actions a { color:#fff; border:1px solid rgba(255,255,255,.45); border-radius:7px; padding:6px 11px; text-decoration:none; background:rgba(255,255,255,.08) }
		.rg-actions a:hover { background:rgba(255,255,255,.18) }
		.rg-badge { display:inline-flex; align-items:center; border-radius:999px; padding:4px 9px; font-size:.82rem; font-weight:650; background:rgba(127,127,127,.14) }
		.rg-badge::before { content:""; width:7px; height:7px; border-radius:50%; margin-right:6px; background:#888 }
		.rg-badge.rg-good::before { background:#28c276 }.rg-badge.rg-warning::before { background:#ffad32 }.rg-badge.rg-error::before { background:#ff6262 }.rg-badge.rg-info::before { background:#70c5ff }
		.rg-hero .rg-badge { background:rgba(255,255,255,.12) }
		.rg-alerts { display:grid; gap:7px; margin:0 0 16px }
		.rg-alert { border-left:4px solid var(--rg-amber); padding:9px 12px; border-radius:5px; background:rgba(184,107,0,.11) }
		.rg-alert.rg-error { border-color:var(--rg-red); background:rgba(196,61,61,.11) }.rg-alert.rg-notice { border-color:var(--rg-blue); background:rgba(23,105,210,.09) }
		.rg-grid { display:grid; grid-template-columns:repeat(12,minmax(0,1fr)); gap:14px }
		.rg-span-4 { grid-column:span 4 }.rg-span-6 { grid-column:span 6 }.rg-span-8 { grid-column:span 8 }.rg-span-12 { grid-column:span 12 }
		.rg-card { border:1px solid rgba(127,127,127,.22); border-radius:11px; overflow:hidden; background:rgba(127,127,127,.035); box-shadow:0 2px 10px rgba(0,0,0,.045) }
		.rg-card-head { padding:14px 16px 10px; border-bottom:1px solid rgba(127,127,127,.16) }.rg-card-head h3 { margin:0 0 2px; font-size:1.08rem }.rg-card-head small { opacity:.66 }
		.rg-card-body { padding:14px 16px }.rg-kv-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:13px 18px }
		.rg-kv { min-width:0 }.rg-kv-label { display:block; font-size:.78rem; opacity:.62; text-transform:uppercase; letter-spacing:.035em }.rg-kv-value { display:block; font-size:1.02rem; font-weight:650; overflow-wrap:anywhere }.rg-kv small { display:block; opacity:.6; margin-top:1px }
		.rg-timezone { margin-top:15px; padding-top:13px; border-top:1px solid rgba(127,127,127,.16) }.rg-timezone-row { display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:10px }.rg-timezone-controls { display:flex; flex-wrap:wrap; align-items:center; gap:8px }.rg-timezone-controls label { display:inline-flex; align-items:center; gap:6px; font-weight:650 }.rg-timezone-controls button { margin:0 }.rg-timezone-note { display:block; margin-top:7px; opacity:.65 }
		.rg-meter-block + .rg-meter-block { margin-top:15px }.rg-meter-label { display:flex; justify-content:space-between; gap:10px; margin-bottom:6px }.rg-meter-label strong { font-size:.84rem }
		.rg-meter { height:8px; border-radius:99px; overflow:hidden; background:rgba(127,127,127,.18) }.rg-meter span { display:block; height:100%; border-radius:inherit; background:linear-gradient(90deg,#1769d2,#35a3e3) }
		.rg-slot-row { display:grid; grid-template-columns:1fr 1fr 1.4fr; gap:8px; margin-bottom:14px }.rg-slot { border:1px solid rgba(127,127,127,.25); border-radius:8px; padding:10px; text-align:center }.rg-slot strong { display:block; font-size:1.15rem }.rg-slot.rg-current { border-color:var(--rg-blue); box-shadow:inset 0 0 0 1px var(--rg-blue) }.rg-slot.rg-accepted { background:rgba(27,143,85,.1) }
		.rg-port-grid { display:grid; grid-template-columns:repeat(5,minmax(0,1fr)); gap:9px }.rg-port { border:1px solid rgba(127,127,127,.22); border-radius:9px; padding:11px; min-width:0 }.rg-port-up { border-color:rgba(27,143,85,.6); background:rgba(27,143,85,.07) }.rg-port-name { display:flex; justify-content:space-between; gap:5px; align-items:center; margin-bottom:8px }.rg-port-name strong { font-size:1rem }.rg-port small { display:block; opacity:.65; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
		.rg-radio-list { display:grid; gap:9px }.rg-radio { display:grid; grid-template-columns:minmax(9rem,1.3fr) repeat(3,minmax(5rem,1fr)); gap:10px; align-items:center; padding:10px 0; border-bottom:1px solid rgba(127,127,127,.14) }.rg-radio:last-child { border:0 }.rg-radio strong,.rg-radio span { min-width:0; overflow-wrap:anywhere }
		.rg-service { border:1px solid rgba(127,127,127,.22); border-radius:7px; padding:6px 9px }.rg-service-down { border-color:rgba(196,61,61,.65); color:var(--rg-red) }
		.rg-led-list { display:grid; gap:8px; margin-bottom:15px }.rg-led-row { display:flex; justify-content:space-between; gap:10px; align-items:center; border-bottom:1px solid rgba(127,127,127,.14); padding:0 0 8px }.rg-led-row:last-child { border-bottom:0 }.rg-led-row strong,.rg-led-row small { display:block }.rg-led-row small { opacity:.62; margin-top:2px }
		.rg-service-title { margin:13px 0 8px; padding-top:12px; border-top:1px solid rgba(127,127,127,.16); font-size:.9rem }
		.rg-table-wrap { overflow-x:auto }.rg-dashboard-root table { width:100% }.rg-dashboard-root .table td,.rg-dashboard-root .table th { vertical-align:middle }
		.rg-muted { opacity:.64 }.rg-footer { display:flex; justify-content:space-between; gap:10px; margin:14px 2px 2px; font-size:.82rem; opacity:.62 }
		@media (max-width:980px) { .rg-span-4,.rg-span-8 { grid-column:span 6 }.rg-port-grid { grid-template-columns:repeat(3,minmax(0,1fr)) } }
		@media (max-width:680px) { .rg-hero { padding:18px }.rg-hero-top { display:block }.rg-health { display:inline-block; margin-top:12px }.rg-span-4,.rg-span-6,.rg-span-8,.rg-span-12 { grid-column:span 12 }.rg-port-grid { grid-template-columns:repeat(2,minmax(0,1fr)) }.rg-radio { grid-template-columns:1fr 1fr }.rg-kv-grid { grid-template-columns:1fr 1fr }.rg-footer { display:block } }
	`);
}

return view.extend({
	load() {
		return Promise.all([ callOverview(), callWireless(), callTimezoneStatus(), callTimezones() ]).then(data => {
			let status = data[2] || {};
			let zones = data[3] || {};
			let detected = browserTimezone(zones);
			this.timezones = zones;
			status.browser_zone = detected;
			status.browser_supported = detected === 'UTC' || !!zones[detected];
			if (!status.automatic || status.initialized || !status.browser_supported)
				return data;
			return callConfigureTimezone(detected, true, data[1]?.cluster?.enabled ? 'cluster' : 'pair').then(result => {
				if (!result?.success) {
					status.sync_error = result?.error || 'timezone_rejected';
					return data;
				}
				data[2] = Object.assign({}, result || {}, {
					browser_zone: detected, browser_supported: true
				});
				return callOverview().then(system => { data[0] = system; return data; });
			}).catch(error => {
				status.sync_error = String(error);
				return data;
			});
		});
	},

	handleTimezoneSync(status, automatic) {
		let zones = this.timezones || {};
		let detected = browserTimezone(zones);
		if (automatic && (!detected || (detected !== 'UTC' && !zones[detected]))) {
			ui.addNotification(null, E('p', {}, _('The browser timezone is unavailable or is not supported by this firmware.')), 'error');
			return Promise.resolve();
		}
		let zonename = automatic ? detected : valueOr(status?.zonename, 'UTC');
		poll.stop();
		return callConfigureTimezone(zonename, automatic, this.communityCluster ? 'cluster' : 'pair').then(result => {
			if (!result?.success)
				throw new Error(result?.error || _('Timezone update failed'));
			ui.addNotification(null, E('p', {}, automatic ?
				_('Timezone synchronized to %s.').format(zonename) :
				_('Automatic timezone detection is disabled.')));
		}).catch(error => {
			ui.addNotification(null, E('p', {}, _('Unable to update timezone: %s').format(error.message || error)), 'error');
		}).finally(() => poll.start());
	},

	renderHero(system, wireless, warnings) {
		let identity = system.identity || {};
		let boot = system.boot || {};
		let state = warnings.some(w => w.level === 'error') ? 'error' : warnings.length ? 'warning' : 'good';
		let stateText = state === 'good' ? _('All systems operational') : state === 'error' ? _('Action required') : _('Attention recommended');
		return E('div', { class: 'rg-hero' }, [
			E('div', { class: 'rg-hero-top' }, [
				E('div', {}, [ E('h2', {}, _('RG-MA2820 operations dashboard')), E('p', {}, _('%s · %s · live operational view').format(valueOr(identity.hostname), valueOr(identity.model))) ]),
				E('div', { class: 'rg-health' }, stateText)
			]),
			E('div', { class: 'rg-hero-badges' }, [
				badge(_('Firmware %s').format(valueOr(identity.release)), 'info'),
				badge(_('Slot %s').format(valueOr(boot.running_slot).toUpperCase()), boot.running_slot === boot.accepted_slot ? 'good' : 'warning'),
				badge(wireless.mesh_ready ? _('Wired roaming ready') : _('Wired roaming degraded'), wireless.mesh_ready ? 'good' : 'warning'),
				wireless.cluster ? badge(_('%d/%d cluster nodes').format(Number(wireless.cluster.online_count || 0), Number(wireless.cluster.node_count || 0)), wireless.cluster.online_count === wireless.cluster.node_count) :
					badge(wireless.peer_online ? _('Peer online') : _('Peer offline'), wireless.peer_online ? 'good' : 'error')
			]),
			E('div', { class: 'rg-actions' }, [
				E('a', { href: L.url('admin/network/rg-ma2820') }, _('Manage Wi-Fi & mesh')),
				E('a', { href: L.url('admin/status/logs/syslog') }, _('Open system log')),
				E('a', { href: L.url('admin/system/flash') }, _('Backup / flash firmware'))
			])
		]);
	},

	renderTimezone(status) {
		status ||= {};
		let detected = status.browser_zone || browserTimezone(this.timezones || {});
		let supported = status.browser_supported !== false && !!detected;
		return E('div', { class: 'rg-timezone' }, [
			E('div', { class: 'rg-timezone-row' }, [
				E('div', {}, [
					E('strong', {}, _('Geographic timezone')),
					E('br'),
					E('small', {}, _('%s configured · browser reports %s').format(valueOr(status.zonename, 'UTC'), valueOr(detected)))
				]),
				E('div', { class: 'rg-timezone-controls' }, [
					E('label', {}, [
						E('input', {
							type: 'checkbox', checked: status.automatic ? '' : null,
							change: ev => this.handleTimezoneSync(status, ev.target.checked)
						}),
						_('Automatic')
					]),
					E('button', {
						class: 'btn cbi-button cbi-button-apply', disabled: supported ? null : '',
						click: () => this.handleTimezoneSync(status, true)
					}, _('Synchronize now'))
				])
			]),
			E('small', { class: 'rg-timezone-note' }, status.sync_error ?
				_('Automatic timezone synchronization failed: %s').format(status.sync_error) :
				_('Detection uses the browser IANA timezone once, validates it against the local database, then synchronizes both wired APs without contacting an external geolocation service.'))
		]);
	},

	renderSystem(system, timezone) {
		let identity = system.identity || {}, stats = system.system || {};
		return card(_('Device & runtime'), _('Hardware identity and current process environment'), [
			E('div', { class: 'rg-kv-grid' }, [
				keyValue(_('Model'), identity.model, `${valueOr(identity.project)} · ${valueOr(identity.board)}`),
				keyValue(_('Base MAC address'), identity.base_mac, _('Unit %s').format(valueOr(identity.device_id).toUpperCase())),
				keyValue(_('Firmware'), identity.release, _('OpenWrt kernel %s').format(valueOr(identity.kernel))),
				keyValue(_('Uptime'), formatDuration(stats.uptime)),
				keyValue(_('Temperature'), Number(stats.temperature_mc) ? `${(stats.temperature_mc / 1000).toFixed(1)} °C` : '—',
					Number(stats.thermal_trip_mc) ? _('Kernel thermal action at %s °C').format((stats.thermal_trip_mc / 1000).toFixed(1)) : ''),
				keyValue(_('Load average'), `${valueOr(stats.load_1)} / ${valueOr(stats.load_5)} / ${valueOr(stats.load_15)}`, _('1 / 5 / 15 minutes'))
			]),
			this.renderTimezone(timezone)
		], 6);
	},

	renderResources(system) {
		let stats = system.system || {};
		let memoryTotal = Number(stats.memory_total_kb || 0) * 1024;
		let memoryUsed = Math.max(0, memoryTotal - Number(stats.memory_available_kb || 0) * 1024);
		let overlayTotal = Number(stats.overlay_total_kb || 0) * 1024;
		let overlayUsed = Number(stats.overlay_used_kb || 0) * 1024;
		return card(_('Memory & persistent storage'), _('Live capacity; the immutable system image is intentionally read-only'), [
			meter(_('Memory'), memoryUsed, memoryTotal, formatBytes),
			meter(_('Writable overlay'), overlayUsed, overlayTotal, formatBytes)
		], 6);
	},

	renderBoot(system) {
		let boot = system.boot || {};
		let slot = name => E('div', { class: `rg-slot ${boot.running_slot === name ? 'rg-current' : ''} ${boot.accepted_slot === name ? 'rg-accepted' : ''}` }, [
			E('strong', {}, name === 'recovery' ? _('Recovery') : name.toUpperCase()),
			E('small', {}, boot.running_slot === name ? _('Running now') : boot.accepted_slot === name ? _('Accepted fallback') : _('Standby'))
		]);
		return card(_('A/B boot safety'), _('Inactive-slot updates retain a known-good fallback'), [
			E('div', { class: 'rg-slot-row' }, [ slot('a'), slot('b'), slot('recovery') ]),
			E('div', { class: 'rg-kv-grid' }, [
				keyValue(_('Pending slot'), boot.pending_slot), keyValue(_('Trial slot'), boot.trial_slot),
				keyValue(_('Last boot result'), boot.last_result), keyValue(_('Boot retry counter'), boot.boot_counter),
				keyValue(_('NAND bad blocks'), boot.bad_peb_count), keyValue(_('Root volume'), boot.rom_device)
			])
		], 6);
	},

	renderNetwork(system) {
		let net = system.network || {};
		return card(_('Management & uplink'), _('Every WAN/LAN socket is bridged; DHCP selects the management address'), E('div', { class: 'rg-kv-grid' }, [
			keyValue(_('DHCP address'), net.management_cidr),
			keyValue(_('Rescue address'), net.rescue_cidr),
			keyValue(_('Default gateway'), net.gateway),
			keyValue(_('Uplink health'), indicatorLabel(system.leds?.uplink), _('Any WAN/LAN socket can carry the uplink.')),
			keyValue(_('DNS server'), net.dns_server),
			keyValue(_('Bridge MAC address'), net.bridge_mac),
			keyValue(_('Bridge traffic'), _('RX %s · TX %s').format(formatBytes(net.rx_bytes), formatBytes(net.tx_bytes)), _('%d RX / %d TX errors').format(Number(net.rx_errors || 0), Number(net.tx_errors || 0)))
		]), 6);
	},

	renderPorts(system) {
		let ports = (system.ports || []).map(port => E('div', { class: `rg-port ${port.link ? 'rg-port-up' : ''}` }, [
			E('div', { class: 'rg-port-name' }, [ E('strong', {}, port.label), badge(port.link ? _('Linked') : _('No link'), port.link ? 'good' : 'neutral') ]),
			E('small', {}, `${port.interface} · ${port.link ? _('%d Mbit/s %s duplex').format(port.speed_mbps, valueOr(port.duplex)) : _('cable disconnected')}`),
			E('small', {}, _('RX %s · TX %s').format(formatBytes(port.rx_bytes), formatBytes(port.tx_bytes))),
			E('small', {}, _('%d errors · %d drops').format(Number(port.rx_errors || 0) + Number(port.tx_errors || 0), Number(port.rx_dropped || 0) + Number(port.tx_dropped || 0)))
		]));
		return card(_('Ethernet switch ports'), _('Panel labels are shown for orientation; all five ports are equivalent in AP mode'), E('div', { class: 'rg-port-grid' }, ports), 12);
	},

	renderWireless(wireless) {
		let radios = [];
		for (const node of wirelessNodes(wireless))
			for (const radio of node.radios)
				radios.push(E('div', { class: 'rg-radio' }, [
			E('strong', {}, [ radio.ssid, E('br'), E('small', { class: 'rg-muted' }, `${node.hostname} · ${radio.interface} · ${radio.bssid}`) ]),
			E('span', {}, [ badge(radio.online ? _('Online') : _('Offline'), radio.online ? 'good' : 'error'), E('br'), E('small', { class: 'rg-muted' }, radio.band === '2g' ? '2.4 GHz' : '5 GHz') ]),
			E('span', {}, [ _('%s / %s MHz').format(valueOr(radio.channel), valueOr(radio.width)), E('br'), E('small', { class: 'rg-muted' }, radio.security) ]),
			E('span', {}, [ _('%d clients').format(Number(radio.client_count || 0)), E('br'), E('small', { class: 'rg-muted' }, _('TX %s dBm · noise %d dBm').format(valueOr(radio.txpower_dbm), Number(radio.noise_dbm || 0))) ])
		]));
		let peer = wireless.peer_status || {};
		let cluster = wireless.cluster;
		return card(_('Wi-Fi & wired roaming'), cluster ? _('Live radios on every authenticated Ethernet-backhauled cluster node') : _('Live radios on this AP and its Ethernet-backhauled peer'), [
			E('div', { class: 'rg-service-list', style: 'margin-bottom:10px' }, [
				badge(wireless.config_synced ? _('Configuration synchronized') : _('Configuration differs'), wireless.config_synced ? 'good' : 'warning'),
				cluster ? badge(_('%d nodes discovered').format(Number(cluster.node_count || 0)), cluster.ready) : badge(wireless.channel_plan_ok ? _('Channel plan healthy') : _('Channel plan needs attention'), wireless.channel_plan_ok ? 'good' : 'warning'),
				cluster ? badge(cluster.ready ? _('Cluster RPC healthy') : _('Cluster RPC degraded'), cluster.ready) : badge(wireless.neighbor_synced ? _('Neighbors synchronized') : _('Neighbors not synchronized'), wireless.neighbor_synced ? 'good' : 'warning'),
				badge(wireless.roaming_online ? _('Steering online') : _('Steering offline'), wireless.roaming_online ? 'good' : 'warning'),
				cluster ? badge(cluster.config_synced ? _('Cluster profile synchronized') : _('Cluster profile differs'), cluster.config_synced) : badge(peer.available ? _('Peer snapshot live') : (wireless.peer_online ? _('Peer snapshot unavailable') : _('Peer offline')), peer.available ? 'good' : (wireless.peer_online ? 'warning' : 'error'))
			]),
			E('div', { class: 'rg-radio-list' }, radios)
		], 12);
	},

	renderClients(wireless) {
		let clients = collectWirelessClients(wireless);
		clients.sort((a, b) => Number(b.client.rssi || -100) - Number(a.client.rssi || -100));
		let rows = clients.map(({ node, radio, client }) => E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, [ E('strong', {}, client.mac), E('br'), E('small', { class: 'rg-muted' }, client.ip_address || _('IP address unknown')) ]),
			E('td', { class: 'td' }, [ E('strong', {}, node.hostname), E('br'), E('small', { class: 'rg-muted' }, node.local ? _('This AP') : _('Peer AP')) ]),
			E('td', { class: 'td' }, [ radio.ssid, E('br'), E('small', { class: 'rg-muted' }, `${radio.interface} · ${radio.band === '2g' ? '2.4 GHz' : '5 GHz'}`) ]),
			E('td', { class: 'td' }, [ _('%d dBm').format(client.rssi), E('br'), E('small', { class: 'rg-muted' }, client.phy) ]),
			E('td', { class: 'td' }, [ _('TX %s').format(formatRate(client.tx_rate_kbps)), E('br'), E('small', { class: 'rg-muted' }, _('RX %s').format(formatRate(client.rx_rate_kbps))) ]),
			E('td', { class: 'td' }, [ formatDuration(client.connected_seconds), E('br'), E('small', { class: 'rg-muted' }, _('idle %s').format(formatDuration(client.idle_seconds))) ]),
			E('td', { class: 'td' }, [ client.rrm ? '802.11k ' : '', client.bss_transition ? '802.11v' : '' ])
		]));
		if (!rows.length)
			rows.push(E('tr', { class: 'tr' }, E('td', { class: 'td rg-muted', colspan: 7 }, _('No wireless clients are associated.'))));
		let subtitle = wireless.cluster_nodes?.length
			? _('%d clients across %d APs').format(clients.length, wirelessNodes(wireless).length)
			: wireless.peer_status?.available
			? _('%d clients across both APs').format(clients.length)
			: _('%d local clients · peer station list unavailable').format(clients.length);
		return card(_('Associated wireless clients'), subtitle, E('div', { class: 'rg-table-wrap' }, E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' }, [
				E('th', { class: 'th' }, _('Client')), E('th', { class: 'th' }, _('Connected AP')), E('th', { class: 'th' }, _('BSS')),
				E('th', { class: 'th' }, _('Signal / PHY')), E('th', { class: 'th' }, _('Current rate')),
				E('th', { class: 'th' }, _('Connection age')), E('th', { class: 'th' }, _('Roaming support'))
			]), ...rows
		])), 8);
	},

	renderServices(system) {
		let leds = system.leds || {};
		let services = (system.services || []).map(service => E('span', { class: `rg-service ${service.running ? '' : 'rg-service-down'}` }, [
			serviceLabel(service.id), ' · ', service.running ? _('running') : _('stopped')
		]));
		return card(_('Indicators & services'), _('Live front-panel meanings and required daemons'), [
			E('div', { class: 'rg-led-list' }, [
				indicatorRow(_('Power'), leds.power, _('Steady is normal; blinking indicates trial, recovery, or fault.')),
				indicatorRow(_('WAN'), leds.wan, wanIndicatorDetail(leds.wan_color_mode)),
				indicatorRow(_('LAN'), leds.lan, _('LAN sockets only: green means a LAN cable is linked; activity flashes show LAN traffic; off means no cable.')),
				indicatorRow(_('Wi-Fi'), leds.wifi, _('Steady green means every configured BSS is enabled; activity flashes show wireless traffic; slow blinking means partial service.')),
				indicatorRow(_('Mesh (WPS LED)'), leds.mesh, _('Steady green means the peer is ready; brief blinks show successful peer probes; slow blinking means synchronizing; off means no peer.'))
			]),
			E('div', { class: 'rg-service-title' }, _('Control-plane services')),
			E('div', { class: 'rg-service-list' }, services)
		], 4);
	},

	renderDashboard(system, wireless, timezone) {
		system ||= {};
		wireless ||= {};
		this.communityCluster = !!wireless.cluster?.enabled;
		let warnings = collectWarnings(system, wireless);
		let alerts = warnings.length ? E('div', { class: 'rg-alerts' }, warnings.map(item => E('div', { class: `rg-alert rg-${item.level}` }, item.text))) : '';
		return E('div', { class: 'rg-dashboard-root' }, [
			dashboardStyle(),
			this.renderHero(system, wireless, warnings),
			alerts,
			E('div', { class: 'rg-grid' }, [
				this.renderSystem(system, timezone), this.renderResources(system),
				this.renderBoot(system), this.renderNetwork(system),
				this.renderPorts(system), this.renderWireless(wireless),
				this.renderClients(wireless), this.renderServices(system)
			]),
			E('div', { class: 'rg-footer' }, [
				E('span', {}, _('Live data refreshes automatically; timezone changes apply to both APs.')),
				E('span', {}, _('Last snapshot: %s').format(system.timestamp ? new Date(system.timestamp * 1000).toLocaleString() : '—'))
			])
		]);
	},

	update(data) {
		let root = document.getElementById('rg-ma2820-dashboard');
		if (data?.[2]) {
			data[2].browser_zone = browserTimezone(this.timezones || {});
			data[2].browser_supported = data[2].browser_zone === 'UTC' || !!this.timezones?.[data[2].browser_zone];
		}
		if (root)
			dom.content(root, this.renderDashboard(data?.[0], data?.[1], data?.[2]));
	},

	render(data) {
		this.timezones = data?.[3] || this.timezones || {};
		poll.add(() => Promise.all([ callOverview(), callWireless(), callTimezoneStatus() ]).then(result => this.update(result)), 5);
		return E('div', { id: 'rg-ma2820-dashboard' }, this.renderDashboard(data?.[0], data?.[1], data?.[2]));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
