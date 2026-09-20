#!/usr/bin/env bash
# Verify that one RPC snapshot safely combines local and pinned peer stations.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-cluster-status-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

ucode=${UCODE:-$project_dir/openwrt/staging_dir/hostpkg/bin/ucode}
plugin=$project_dir/persistent-overlay/usr/share/rpcd/ucode/rg-ma2820.uc

cat > "$temporary/local" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device_id":"ap2","hostname":"rg-ma2820-ap2","peer_id":"ap3","peer_online":true,"radios":[{"interface":"wl0","client_count":1,"clients":[{"mac":"02:00:00:00:00:02"}]}]}'
EOF
cat > "$temporary/peer" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device_id":"ap3","hostname":"rg-ma2820-ap3","release":"r31","peer_id":"ap2","peer_online":true,"mesh_ready":true,"radios":[{"interface":"wl1","client_count":1,"clients":[{"mac":"02:00:00:00:00:03"}]}]}'
EOF
cat > "$temporary/wrong-peer" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device_id":"unexpected","hostname":"wrong","peer_id":"ap2","radios":[{"clients":[{"mac":"02:00:00:00:00:ff"}]}]}'
EOF
cat > "$temporary/failed-peer" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$temporary/local-offline" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device_id":"ap2","hostname":"rg-ma2820-ap2","peer_id":"ap3","peer_online":false,"radios":[]}'
EOF
chmod 0755 "$temporary"/*

run_status()
{
	RG_MA2820_STATUS_HELPER=$1 RG_MA2820_PEER_STATUS_HELPER=$2 \
		"$ucode" -e \
		'let p=loadfile(ARGV[0])(); print(sprintf("%J\n", p["luci.rg-ma2820"].status.call()));' \
		"$plugin"
}

if [ -x "$ucode" ]; then
	result=$(run_status "$temporary/local" "$temporary/peer")
	printf '%s\n' "$result" | jq -e '
		.device_id == "ap2" and
		(.radios[0].clients[0].mac == "02:00:00:00:00:02") and
		.peer_status.available == true and
		.peer_status.online == true and
		.peer_status.error == null and
		.peer_status.device_id == "ap3" and
		.peer_status.hostname == "rg-ma2820-ap3" and
		.peer_status.release == "r31" and
		.peer_status.mesh_ready == true and
		(.peer_status.radios[0].clients[0].mac == "02:00:00:00:00:03")
	' >/dev/null

	result=$(run_status "$temporary/local" "$temporary/wrong-peer")
	printf '%s\n' "$result" | jq -e '
		.device_id == "ap2" and
		.peer_status.available == false and
		.peer_status.error == "peer_identity_mismatch" and
		(.peer_status.radios | length) == 0
	' >/dev/null

	result=$(run_status "$temporary/local" "$temporary/failed-peer")
	printf '%s\n' "$result" | jq -e '
		.device_id == "ap2" and
		(.radios | length) == 1 and
		.peer_status.available == false and
		.peer_status.error == "peer_status_unavailable"
	' >/dev/null

	result=$(run_status "$temporary/local-offline" "$temporary/peer")
	printf '%s\n' "$result" | jq -e '
		.peer_status.online == false and
		.peer_status.available == false and
		.peer_status.error == "peer_offline" and
		(.peer_status.radios | length) == 0
	' >/dev/null
else
	node - "$plugin" <<'JS'
const fs = require('fs');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const body = source.slice(source.indexOf('function attach_peer_status('), source.indexOf('function valid_interface('));
const attach = new Function('type', `${body}\nreturn attach_peer_status;`)(value => Array.isArray(value) ? 'array' : typeof value);
const local = { device_id: 'ap2', peer_id: 'ap3', peer_online: true, radios: [{ interface: 'wl0' }] };
const peer = { device_id: 'ap3', peer_id: 'ap2', hostname: 'rg-ma2820-ap3', release: 'r31', mesh_ready: true, radios: [{ interface: 'wl1' }] };
let result = attach(structuredClone(local), peer);
assert.equal(result.peer_status.available, true);
assert.equal(result.peer_status.device_id, 'ap3');
assert.equal(result.peer_status.radios[0].interface, 'wl1');
result = attach(structuredClone(local), { ...peer, device_id: 'unexpected' });
assert.equal(result.peer_status.error, 'peer_identity_mismatch');
result = attach(structuredClone(local), { error: 'helper_failed' });
assert.equal(result.peer_status.error, 'peer_status_unavailable');
result = attach({ ...structuredClone(local), peer_online: false }, peer);
assert.equal(result.peer_status.error, 'peer_offline');
const statusMethod = source.slice(source.indexOf('\tstatus: {'), source.indexOf('\n\tcapabilities: {'));
assert.ok(statusMethod.indexOf('read_json_helper(STATUS)') < statusMethod.indexOf('read_json_helper(PEER_STATUS)'));
JS
fi

node - "$project_dir/persistent-overlay/www/luci-static/resources/view/status/index.js" <<'JS'
const fs = require('fs');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const helpers = source.slice(source.indexOf('function wirelessNodes('), source.indexOf('function percent('));
const api = new Function('_', `${helpers}\nreturn { wirelessNodes, collectWirelessClients };`)(s => s);
const wireless = {
    device_id: 'ap2', hostname: 'rg-ma2820-ap2',
    radios: [{ interface: 'wl0', clients: [{ mac: '02:00:00:00:00:02' }] }],
    peer_status: {
        available: true, device_id: 'ap3', hostname: 'rg-ma2820-ap3',
        radios: [{ interface: 'wl1', clients: [{ mac: '02:00:00:00:00:03' }] }]
    }
};
assert.deepEqual(api.wirelessNodes(wireless).map(n => n.device_id), ['ap2', 'ap3']);
assert.deepEqual(api.collectWirelessClients(wireless).map(c => [c.node.device_id, c.client.mac]), [
    ['ap2', '02:00:00:00:00:02'], ['ap3', '02:00:00:00:00:03']
]);
wireless.peer_status.available = false;
assert.deepEqual(api.collectWirelessClients(wireless).map(c => c.node.device_id), ['ap2']);
JS

grep -Fq "Read-only peer snapshot" \
	"$project_dir/persistent-overlay/www/luci-static/resources/view/rg-ma2820/wireless.js"

echo 'cluster radio/client status tests: PASS'
