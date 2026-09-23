// SPDX-License-Identifier: GPL-2.0-only
'use strict';

import { sha256 } from 'digest';
import { readfile } from 'fs';

const SERVICE = '_rg-ma2820._tcp';

export function parse_env(path) {
	let result = {};
	let content = readfile(path);
	if (!content)
		return result;
	for (let line in split(content, '\n')) {
		let m = match(line, /^([A-Z][A-Z0-9_]*)='([^']*)'$/);
		if (m)
			result[m[1]] = m[2];
	}
	return result;
}

function valid_ipv4(address) {
	if (!match(address || '', /^([0-9]{1,3}\.){3}[0-9]{1,3}$/))
		return false;
	for (let part in split(address, '.'))
		if (+part > 255)
			return false;
	return true;
}

function txt_map(values) {
	let result = {};
	for (let item in values || []) {
		let m = match(item, /^([a-z0-9_]+)=(.*)$/);
		if (m)
			result[m[1]] = m[2];
	}
	return result;
}

export function discover_members(browse, config, device) {
	if (config.CLUSTER_ENABLED != '1')
		return [];
	let services = browse?.[SERVICE] || {};
	let unique = {};
	for (let instance, service in services) {
		let txt = txt_map(service.txt);
		if (txt.api != '1' || txt.model != 'RG-MA2820T' ||
		    txt.cluster != config.CLUSTER_ID || txt.node == device.DEVICE_ID ||
		    !match(txt.node || '', /^node-[0-9a-f]{6}([0-9a-f]{6})?$/))
			continue;
		let address = null;
		for (let candidate in service.ipv4 || [])
			if (valid_ipv4(candidate)) { address = candidate; break; }
		if (!address)
			continue;
		unique[txt.node] = {
			device_id: txt.node,
			hostname: instance,
			address,
			release: txt.release || 'unknown'
		};
	}
	return values(unique);
}

export function hmac_sha256_hex(hexkey, message) {
	if (!match(hexkey || '', /^[0-9a-f]{64}$/) || type(message) != 'string')
		return null;
	let key = hexdec(hexkey);
	const blocksize = 64;
	while (length(key) < blocksize)
		key += chr(0);
	let outer = '';
	let inner = '';
	for (let i = 0; i < blocksize; i++) {
		let byte = ord(key, i);
		outer += chr(byte ^ 0x5c);
		inner += chr(byte ^ 0x36);
	}
	return sha256(outer + hexdec(sha256(inner + message)));
}

export function constant_equal(left, right) {
	if (type(left) != 'string' || type(right) != 'string' || length(left) != length(right))
		return false;
	let difference = 0;
	for (let i = 0; i < length(left); i++)
		difference |= ord(left, i) ^ ord(right, i);
	return difference == 0;
}

export function signed_response(key, nonce, object) {
	let payload = b64enc(sprintf('%J', object));
	return {
		nonce,
		payload,
		signature: hmac_sha256_hex(key, `response\n${nonce}\n${payload}`)
	};
}

export function verify_response(key, nonce, envelope) {
	if (type(envelope) != 'object' || envelope.nonce != nonce ||
	    !match(envelope.payload || '', /^[A-Za-z0-9+\/=]+$/))
		return null;
	let expected = hmac_sha256_hex(key, `response\n${nonce}\n${envelope.payload}`);
	if (!constant_equal(expected, envelope.signature))
		return null;
	try {
		return json(b64dec(envelope.payload));
	}
	catch (e) {
		return null;
	}
}
