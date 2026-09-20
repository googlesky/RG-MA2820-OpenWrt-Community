#!/usr/bin/env ucode

'use strict';

import { popen } from 'fs';

const STATUS = getenv('RG_MA2820_STATUS_HELPER') || '/usr/sbin/rg-ma2820-wifi-status';
const PEER_STATUS = getenv('RG_MA2820_PEER_STATUS_HELPER') ||
	'. /etc/rg-ma2820/device.env && ' +
	'ping -c 1 -W 1 "$PEER_LINK_LOCAL" >/dev/null 2>&1 && ' +
	'timeout 4 /usr/sbin/rg-ma2820-peer -- /usr/sbin/rg-ma2820-wifi-status </dev/null 2>/dev/null';
const OVERVIEW = '/usr/sbin/rg-ma2820-overview-status';
const CAPABILITIES = '/usr/sbin/rg-ma2820-wifi-capabilities';
const SCAN = '/usr/sbin/rg-ma2820-wifi-scan';
const SET_WIFI = '/usr/sbin/rg-ma2820-set-wifi';
const TIMEZONE = '/usr/sbin/rg-ma2820-timezone';
const STEERING = '/usr/libexec/rg-ma2820/roaming-steer';
const HOSTAPD_CLI = '/opt/bcm/sbin/hostapd_cli';

function read_json_helper(command) {
	let proc = popen(command, 'r');
	if (!proc)
		return { error: 'helper_start_failed' };
	let output = proc.read('all');
	let code = proc.close();
	if (code || !output)
		return { error: 'helper_failed', exit_code: code };
	try {
		return json(trim(output));
	}
	catch (e) {
		return { error: 'invalid_helper_response' };
	}
}

function attach_peer_status(status, peer) {
	let snapshot = {
		available: false,
		online: !!status?.peer_online,
		error: null,
		device_id: status?.peer_id || '',
		hostname: '',
		release: '',
		mesh_ready: false,
		radios: []
	};

	if (!status?.peer_online)
		snapshot.error = 'peer_offline';
	else if (!peer || peer.error)
		snapshot.error = 'peer_status_unavailable';
	else if (peer.device_id != status.peer_id || peer.peer_id != status.device_id)
		snapshot.error = 'peer_identity_mismatch';
	else {
		snapshot.available = true;
		snapshot.device_id = peer.device_id;
		snapshot.hostname = peer.hostname || peer.device_id;
		snapshot.release = peer.release || '';
		snapshot.mesh_ready = !!peer.mesh_ready;
		snapshot.radios = type(peer.radios) == 'array' ? peer.radios : [];
	}

	status.peer_status = snapshot;
	return status;
}

function valid_interface(value, include_virtual) {
	return value == 'wl0' || value == 'wl1' || (include_virtual && value == 'wl1.1');
}

function valid_mac(value) {
	return match(lc(value || ''), /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/);
}

const configure_args = {
	scope: 'pair',
	radio_2g_enabled: true,
	radio_5g_enabled: true,
	ssid_2g: '',
	ssid_5g: '',
	ssid_5g_legacy: '',
	enable_5g_legacy: true,
	security_2g: 'wpa2',
	security_5g: 'wpa3',
	security_5g_legacy: 'wpa2',
	password_2g: '',
	password_5g: '',
	password_5g_legacy: '',
	hidden_2g: false,
	hidden_5g: false,
	hidden_5g_legacy: false,
	isolate_2g: false,
	isolate_5g: false,
	isolate_5g_legacy: false,
	max_clients_2g: 128,
	max_clients_5g: 128,
	max_clients_5g_legacy: 128,
	mfp_2g: '0',
	mfp_5g: '2',
	mfp_5g_legacy: '0',
	ft_2g: false,
	ft_5g: true,
	ft_5g_legacy: true,
	country: 'US',
	channel_2g: 'auto',
	channel_5g: 'auto',
	width_5g: '80',
	txpower_2g: 'auto',
	txpower_5g: '23',
	beacon_interval: 100,
	dtim_period: 2,
	ieee80211k: true,
	ieee80211v: true,
	mobility_domain: '4d41',
	ft_over_ds: false,
	he_2g: true,
	he_5g: true,
	bss_color_2g: 'auto',
	bss_color_5g: 'auto',
	airtime_fairness: true,
	frameburst: true,
	beamforming: true,
	implicit_beamforming: true,
	mu_features: true,
	ampdu: true,
	amsdu: true,
	ldpc: true,
	stbc_tx: false,
	stbc_rx: false,
	sgi_tx: '-1',
	acl_mode: 'disabled',
	acl_macs: '',
	roam_steering: true,
	roam_band_2g: false,
	roam_band_5g: true,
	roam_interval: 4,
	roam_rssi: -72,
	hard_rssi: -82,
	roam_samples: 3,
	roam_cooldown: 60,
	roam_min_age: 15,
	hard_fallback: true,
	hard_delay: 12,
	hard_window: 45
};

const methods = {
	overview: {
		call: function() {
			return read_json_helper(OVERVIEW);
		}
	},

	status: {
		call: function() {
			/* rpcd integrates its ucode VM with a non-blocking event loop. Opening
			 * a second popen before draining the first can make read('all') observe
			 * an empty, still-running pipe. Drain the authoritative local snapshot
			 * first, then query the peer. */
			let status = read_json_helper(STATUS);
			if (status.error)
				return status;
			if (!status.peer_online)
				return attach_peer_status(status, null);
			let peer = read_json_helper(PEER_STATUS);
			return attach_peer_status(status, peer);
		}
	},

	capabilities: {
		call: function() {
			return read_json_helper(CAPABILITIES);
		}
	},

	timezone_status: {
		call: function() {
			return read_json_helper(`${TIMEZONE} status`);
		}
	},

	configure_timezone: {
		args: { zonename: '', automatic: true, scope: 'pair' },
		call: function(req) {
			let a = req.args || {};
			let code = system([
				TIMEZONE, '--configure', a.zonename || '',
				a.automatic ? '1' : '0', a.scope || 'pair'
			]);
			let status = read_json_helper(`${TIMEZONE} status`);
			status.success = code == 0;
			status.exit_code = code;
			if (code != 0)
				status.error = 'timezone_rejected';
			return status;
		}
	},

	configure: {
		args: configure_args,
		call: function(req) {
			let payload = sprintf('%J', req.args || {});
			let code = system([ SET_WIFI, '--configure-json', payload ]);
			return {
				success: code == 0,
				exit_code: code,
				error: code == 0 ? null : 'configuration_rejected'
			};
		}
	},

	scan: {
		args: { interface: 'wl0' },
		call: function(req) {
			let interface = req.args?.interface || '';
			if (!valid_interface(interface, false))
				return { error: 'invalid_interface' };
			return read_json_helper(`${SCAN} ${interface}`);
		}
	},

	action: {
		args: { action: '', interface: '', mac: '' },
		call: function(req) {
			let a = req.args || {};
			if (a.action == 'restart' || a.action == 'reselect') {
				system([ '/etc/init.d/rg-ma2820-roaming', 'stop' ]);
				let code = system([ '/etc/init.d/rg-ma2820-wifi', 'restart' ]);
				system([ '/etc/init.d/rg-ma2820-neighbor-sync', 'restart' ]);
				system([ '/etc/init.d/rg-ma2820-roaming', 'restart' ]);
				return { success: code == 0, exit_code: code };
			}
			if (a.action == 'refresh_neighbors') {
				let code = system([ '/etc/init.d/rg-ma2820-neighbor-sync', 'restart' ]);
				return { success: code == 0, exit_code: code };
			}
			if (a.action == 'steer' && valid_interface(a.interface, true) && valid_mac(a.mac)) {
				let code = system([ STEERING, '--steer', a.interface, lc(a.mac) ]);
				return { success: code == 0, exit_code: code };
			}
			if (a.action == 'disconnect' && valid_interface(a.interface, true) && valid_mac(a.mac)) {
				let code = system([
					HOSTAPD_CLI, '-p', '/var/run/hostapd', '-i', a.interface,
					'deauthenticate', lc(a.mac), 'reason=3'
				]);
				return { success: code == 0, exit_code: code };
			}
			return { success: false, error: 'invalid_action' };
		}
	}
};

return { 'luci.rg-ma2820': methods };
