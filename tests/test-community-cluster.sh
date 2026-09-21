#!/usr/bin/env bash
# Exercise N-node hostapd generation and, when available, target ucode.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-cluster-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

cat > "$temporary/wifi.env" <<'EOF'
WIFI_CONFIG_VERSION='3'
WIFI_PROFILE='wired-mesh'
RADIO_2G_ENABLED='1'
RADIO_5G_ENABLED='1'
SSID_2G='Cluster-IoT'
SSID_5G='Cluster-5G'
SSID_5G_LEGACY='Cluster-Compat'
ENABLE_5G_LEGACY='1'
SECURITY_2G='wpa2'
SECURITY_5G='wpa3'
SECURITY_5G_LEGACY='wpa2'
WPA_PSK_2G='cluster-password'
WPA_PSK_5G='cluster-password'
WPA_PSK_5G_LEGACY='cluster-password'
FT_2G='1'
FT_5G='1'
FT_5G_LEGACY='1'
COUNTRY_CODE='US'
CHANNEL_2G='auto'
CHANNEL_5G='auto'
WIDTH_5G='80'
EOF
cat > "$temporary/device.env" <<'EOF'
DEVICE_ID='node-a1b2c3'
HOSTNAME='rg-ma2820-a1b2c3'
LOCAL_BSSID_2G='02:00:00:a1:b2:40'
LOCAL_BSSID_5G='02:00:00:a1:b2:50'
LOCAL_BSSID_5G_LEGACY='02:00:00:a1:b2:51'
PEER_BSSID_2G='00:00:00:00:00:00'
PEER_BSSID_5G='00:00:00:00:00:00'
PEER_BSSID_5G_LEGACY='00:00:00:00:00:00'
EOF
cat > "$temporary/cluster.env" <<'EOF'
CLUSTER_ENABLED='1'
CLUSTER_MOBILITY_DOMAIN='cafe'
CLUSTER_RRB_KEY='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
EOF

config=$temporary/hostapd-wl1.conf
RG_MA2820_WIFI_ENV=$temporary/wifi.env \
RG_MA2820_DEVICE_ENV=$temporary/device.env \
RG_MA2820_CLUSTER_ENV=$temporary/cluster.env \
CONFIG=$config WIFI_INIT=$project_dir/hybrid-overlay/etc/init.d/rg-ma2820-wifi \
	sh -c '. "$WIFI_INIT"; SELECTED_CHANNEL_5G=149; SELECTED_CENTER_CHANNEL_5G=155; write_wired_mesh_config wl1 a "$CONFIG"'

[ "$(grep -c '^r0kh=ff:ff:ff:ff:ff:ff \* 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef$' "$config")" -eq 2 ]
[ "$(grep -c '^r1kh=00:00:00:00:00:00 00:00:00:00:00:00 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef$' "$config")" -eq 2 ]
[ "$(grep -c '^mobility_domain=cafe$' "$config")" -eq 2 ]
! grep -q '^r0kh=00:00:00:00:00:00' "$config"
grep -q '^export function discover_members' \
	"$project_dir/community-overlay/usr/share/ucode/rg-ma2820/cluster.uc"
grep -q 'return discover_members(browse, config, device);' \
	"$project_dir/community-overlay/usr/sbin/rg-ma2820-cluster"
python3 - "$project_dir/community-overlay/usr/sbin/rg-ma2820-cluster" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
for start, end in [('function apply_wifi(', 'function valid_mac('),
                   ('function apply_timezone(', 'function valid_mac(')]:
    body = source[source.index(start):source.index(end, source.index(start))]
    authenticate = body.index('authenticated_peers(')
    first_post = min(i for i in (body.find("'POST'", authenticate),) if i >= 0)
    assert authenticate < first_post, f'{start} posts before authenticating discovery'
PY

# Compile and execute against the actual target interpreter when a built root
# is supplied. Source-only CI still checks the generated hostapd contract.
target_root=${RG_TEST_OPENWRT_ROOT:-$project_dir/openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755}
if command -v qemu-arm >/dev/null && [ -x "$target_root/usr/bin/ucode" ] &&
	[ -f "$target_root/usr/lib/ucode/digest.so" ]; then
	ucode=(qemu-arm -L "$target_root" \
		-E LD_LIBRARY_PATH="$target_root/lib:$target_root/usr/lib" \
		"$target_root/usr/bin/ucode" -L "$target_root/usr/lib/ucode" \
		-L "$project_dir/community-overlay/usr/share/ucode")
	"${ucode[@]}" -cmodule -o "$temporary/cluster-lib.uc" \
		"$project_dir/community-overlay/usr/share/ucode/rg-ma2820/cluster.uc"
	"${ucode[@]}" -c -o "$temporary/cluster-cli.uc" \
		"$project_dir/community-overlay/usr/sbin/rg-ma2820-cluster"
	"${ucode[@]}" -c -o "$temporary/cluster-cgi.uc" \
		"$project_dir/community-overlay/www/cgi-bin/rg-ma2820-cluster"
	"${ucode[@]}" "$project_dir/community-overlay/usr/sbin/rg-ma2820-cluster" \
		selftest | grep -q '"hmac":"RFC4231"'

	cat > "$temporary/discovery.uc" <<'EOF'
import { discover_members } from 'rg-ma2820.cluster';
let config = { CLUSTER_ENABLED: '1', CLUSTER_ID: '0123456789abcdef' };
let device = { DEVICE_ID: 'node-000001' };
let browse = {
	'_rg-ma2820._tcp': {
		'rg-ma2820-000001': { ipv4: [ '192.0.2.1' ], txt: [ 'api=1', 'model=RG-MA2820T', 'cluster=0123456789abcdef', 'node=node-000001' ] },
		'rg-ma2820-000002': { ipv4: [ '192.0.2.2' ], txt: [ 'api=1', 'model=RG-MA2820T', 'cluster=0123456789abcdef', 'node=node-000002', 'release=r34' ] },
		'rg-ma2820-000003': { ipv4: [ '192.0.2.3' ], txt: [ 'api=1', 'model=RG-MA2820T', 'cluster=0123456789abcdef', 'node=node-000003' ] },
		'rg-ma2820-000004': { ipv4: [ 'bad-address', '192.0.2.4' ], txt: [ 'api=1', 'model=RG-MA2820T', 'cluster=0123456789abcdef', 'node=node-000004' ] },
		'foreign-cluster': { ipv4: [ '192.0.2.5' ], txt: [ 'api=1', 'model=RG-MA2820T', 'cluster=ffffffffffffffff', 'node=node-000005' ] },
		'wrong-model': { ipv4: [ '192.0.2.6' ], txt: [ 'api=1', 'model=other', 'cluster=0123456789abcdef', 'node=node-000006' ] }
	}
};
print(sprintf('%J\n', discover_members(browse, config, device)));
EOF
	"${ucode[@]}" "$temporary/discovery.uc" > "$temporary/discovery.json"
	python3 - "$temporary/discovery.json" <<'PY'
import json, pathlib, sys
members = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert {m['device_id'] for m in members} == {
    'node-000002', 'node-000003', 'node-000004'
}
assert next(m for m in members if m['device_id'] == 'node-000004')['address'] == '192.0.2.4'
PY

	key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
	cat > "$temporary/rpc-cluster.env" <<EOF
CLUSTER_ENABLED='1'
CLUSTER_ID='0123456789abcdef'
CLUSTER_KEY='$key'
EOF
	cat > "$temporary/status" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device_id":"node-a1b2c3","radios":[]}'
EOF
	chmod 0755 "$temporary/status"
	nonce=00112233445566778899aabbccddeeff
	signature=$(python3 - "$key" "$nonce" <<'PY'
import hashlib, hmac, sys
key = bytes.fromhex(sys.argv[1])
nonce = sys.argv[2]
message = f"GET\nstatus\n{nonce}\n{hashlib.sha256(b'').hexdigest()}".encode()
print(hmac.new(key, message, hashlib.sha256).hexdigest())
PY
)
	REQUEST_METHOD=GET QUERY_STRING=action=status CONTENT_LENGTH=0 \
	HTTP_X_RG_NONCE=$nonce HTTP_X_RG_SIGNATURE=$signature \
	HTTP_X_RG_CLUSTER=0123456789abcdef \
	RG_MA2820_CLUSTER_ENV=$temporary/rpc-cluster.env \
	RG_MA2820_STATUS_HELPER=$temporary/status \
		"${ucode[@]}" "$project_dir/community-overlay/www/cgi-bin/rg-ma2820-cluster" \
		> "$temporary/cgi-response"
	python3 - "$temporary/cgi-response" "$key" "$nonce" <<'PY'
import base64, hashlib, hmac, json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_text()
headers, encoded = raw.replace("\r\n", "\n").split("\n\n", 1)
assert headers.startswith("Status: 200 OK\n")
envelope = json.loads(encoded)
assert envelope["nonce"] == sys.argv[3]
message = f"response\n{sys.argv[3]}\n{envelope['payload']}".encode()
expected = hmac.new(bytes.fromhex(sys.argv[2]), message, hashlib.sha256).hexdigest()
assert hmac.compare_digest(expected, envelope["signature"])
payload = json.loads(base64.b64decode(envelope["payload"]))
assert payload["api"] == 1
assert payload["status"]["device_id"] == "node-a1b2c3"
PY
	cat > "$temporary/timezone" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${RG_TEST_TIMEZONE_LOG:?}"
[ "$1" = --validate ] && [ "$2" = Asia/Ho_Chi_Minh ] && [ "$3" = 1 ]
EOF
	chmod 0755 "$temporary/timezone"
	body='{"zone":"Asia/Ho_Chi_Minh","automatic":true}'
	nonce=ffeeddccbbaa99887766554433221100
	signature=$(python3 - "$key" "$nonce" "$body" <<'PY'
import hashlib, hmac, sys
key = bytes.fromhex(sys.argv[1])
nonce, body = sys.argv[2], sys.argv[3]
message = f"POST\nvalidate_timezone\n{nonce}\n{hashlib.sha256(body.encode()).hexdigest()}".encode()
print(hmac.new(key, message, hashlib.sha256).hexdigest())
PY
)
	printf %s "$body" | env \
		REQUEST_METHOD=POST QUERY_STRING=action=validate_timezone CONTENT_LENGTH=${#body} \
		HTTP_X_RG_NONCE=$nonce HTTP_X_RG_SIGNATURE=$signature \
		HTTP_X_RG_CLUSTER=0123456789abcdef \
		RG_MA2820_CLUSTER_ENV=$temporary/rpc-cluster.env \
		RG_MA2820_NONCE_CACHE=$temporary/nonces \
		RG_MA2820_TIMEZONE=$temporary/timezone \
		RG_TEST_TIMEZONE_LOG=$temporary/timezone.log \
		"${ucode[@]}" "$project_dir/community-overlay/www/cgi-bin/rg-ma2820-cluster" \
		> "$temporary/timezone-response"
	grep -q '^Status: 200 OK' "$temporary/timezone-response"
	grep -qx -- '--validate Asia/Ho_Chi_Minh 1' "$temporary/timezone.log"

	echo 'target ucode compile, multi-member discovery, timezone RPC and RFC4231 HMAC test: PASS'
else
	echo 'target ucode compile and RFC4231 HMAC test: SKIP (no built target runtime)'
fi

echo 'N-node wildcard 802.11r cluster tests: PASS'
