#!/usr/bin/env bash
# Exercise the complete LuCI JSON profile, secret preservation and pair guard.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-wifi-json-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

jsonfilter=$temporary/jsonfilter
cat > "$jsonfilter" <<'EOF'
#!/bin/sh
source_json=
expression=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-s) source_json=$2; shift 2 ;;
		-e) expression=$2; shift 2 ;;
		*) exit 2 ;;
	esac
done
field=${expression#@.}
printf '%s' "$source_json" | jq -r --arg field "$field" \
	'.[$field] | if . == null then "" else tostring end'
EOF
chmod 0755 "$jsonfilter"

wifi_env=$temporary/wifi.env
device_env=$temporary/device.env
cat > "$wifi_env" <<'EOF'
WIFI_CONFIG_VERSION='2'
WIFI_PROFILE='wired-mesh'
SSID_2G='Community-IoT'
SSID_5G='Community-5G'
SSID_5G_LEGACY='Community-5G-Legacy'
ENABLE_5G_LEGACY='1'
WPA_PSK='old-shared-secret'
COUNTRY_CODE='#a'
CHANNEL_2G='auto'
CHANNEL_5G='auto'
WIDTH_5G='80'
EOF
cat > "$device_env" <<'EOF'
DEVICE_ID='ap2'
EOF

payload=$(jq -nc '{
	scope: "local",
	radio_2g_enabled: true, radio_5g_enabled: true,
	ssid_2g: "IoT Network", ssid_5g: "Primary 5G", ssid_5g_legacy: "Compat 5G",
	enable_5g_legacy: false,
	security_2g: "wpa2", security_5g: "wpa2-wpa3", security_5g_legacy: "wpa2",
	password_2g: "", password_5g: "", password_5g_legacy: "",
	hidden_2g: false, hidden_5g: true, hidden_5g_legacy: false,
	isolate_2g: true, isolate_5g: false, isolate_5g_legacy: true,
	max_clients_2g: 64, max_clients_5g: 96, max_clients_5g_legacy: 32,
	mfp_2g: "0", mfp_5g: "1", mfp_5g_legacy: "0",
	ft_2g: false, ft_5g: true, ft_5g_legacy: true,
	country: "#a", channel_2g: "6", channel_5g: "149", width_5g: "80",
	txpower_2g: "auto", txpower_5g: "27", beacon_interval: 101, dtim_period: 3,
	ieee80211k: true, ieee80211v: true, mobility_domain: "a1b2", ft_over_ds: true,
	he_2g: true, he_5g: true, bss_color_2g: "7", bss_color_5g: "42",
	airtime_fairness: true, frameburst: false, beamforming: true,
	implicit_beamforming: false, mu_features: true, ampdu: true, amsdu: false,
	ldpc: true, stbc_tx: true, stbc_rx: false, sgi_tx: "2",
	acl_mode: "deny", acl_macs: "AA:BB:CC:DD:EE:FF\t02:11:22:33:44:55",
	roam_steering: true, roam_band_2g: true, roam_band_5g: true,
	roam_interval: 5, roam_rssi: -69, hard_rssi: -83, roam_samples: 4,
	roam_cooldown: 75, roam_min_age: 20, hard_fallback: true,
	hard_delay: 14, hard_window: 50
}')

setter=$project_dir/persistent-overlay/usr/sbin/rg-ma2820-set-wifi
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_JSONFILTER=$jsonfilter RG_MA2820_NO_RESTART=1 \
	sh "$setter" --configure-json "$payload" >/dev/null

for expected in \
	"WIFI_CONFIG_VERSION='3'" \
	"SSID_2G='IoT Network'" \
	"SECURITY_5G='wpa2-wpa3'" \
	"WPA_PSK_2G='old-shared-secret'" \
	"WPA_PSK_5G='old-shared-secret'" \
	"WPA_PSK_5G_LEGACY='old-shared-secret'" \
	"CHANNEL_2G='6'" \
	"CHANNEL_5G='149'" \
	"TXPOWER_5G_DBM='27'" \
	"MOBILITY_DOMAIN='a1b2'" \
	"BSS_COLOR_5G='42'" \
	"FRAMEBURST='0'" \
	"STBC_TX='1'" \
	"SGI_TX='2'" \
	"ACL_MODE='deny'" \
	"ACL_MACS='aa:bb:cc:dd:ee:ff,02:11:22:33:44:55'" \
	"ROAM_BAND_2G='1'" \
	"ROAM_RSSI_TRIGGER='-69'"; do
	grep -Fqx "$expected" "$wifi_env"
done

# A pair-wide manual channel would put both APs on the same primary channel.
# Reject it before invoking the peer or changing the local profile.
before=$(sha256sum "$wifi_env")
pair_manual=$(printf '%s' "$payload" | jq -c '.scope="pair"')
if RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_JSONFILTER=$jsonfilter RG_MA2820_NO_RESTART=1 \
	sh "$setter" --configure-json "$pair_manual" >/dev/null 2>&1; then
	echo 'JSON setter accepted pair-wide manual channels' >&2
	exit 1
fi
[ "$(sha256sum "$wifi_env")" = "$before" ]

# Pair mode sends the fully materialized candidate (including preserved
# secrets) to the peer first, then installs the exact same logical profile.
peer=$temporary/peer
peer_candidate=$temporary/peer-candidate
cat > "$peer" <<'EOF'
#!/bin/sh
[ "$1" = wifi-config ] && [ -f "$2" ] || exit 2
cp "$2" "$RG_TEST_PEER_CANDIDATE"
EOF
chmod 0755 "$peer"
pair_auto=$(printf '%s' "$payload" | jq -c '.scope="pair" | .channel_2g="auto" | .channel_5g="auto"')
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_JSONFILTER=$jsonfilter RG_MA2820_PEER=$peer \
	RG_TEST_PEER_CANDIDATE=$peer_candidate RG_MA2820_NO_RESTART=1 \
	sh "$setter" --configure-json "$pair_auto" >/dev/null
grep -Fqx "CHANNEL_2G='auto'" "$wifi_env"
grep -Fqx "CHANNEL_5G='auto'" "$wifi_env"
cmp "$peer_candidate" "$wifi_env"

# The open onboarding profile has no secret to preserve. Saving it must not be
# blocked by stale SAE/FT defaults hidden by the form; security normalization
# records the effective hostapd values instead.
cat > "$wifi_env" <<'EOF'
WIFI_CONFIG_VERSION='3'
WIFI_PROFILE='factory'
SSID_BASE='RG-MA2820-Mesh'
WIFI_SECURITY='open'
WPA_PSK=''
COUNTRY_CODE='#a'
CHANNEL_2G='1'
CHANNEL_5G='36'
EOF
open_payload=$(printf '%s' "$payload" | jq -c '
	.scope="local" |
	.security_2g="open" | .security_5g="open" |
	.ft_2g=true | .ft_5g=true |
	.mfp_2g="2" | .mfp_5g="2" |
	.channel_2g="auto" | .channel_5g="auto"')
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_JSONFILTER=$jsonfilter RG_MA2820_NO_RESTART=1 \
	sh "$setter" --configure-json "$open_payload" >/dev/null
grep -Fqx "SECURITY_2G='open'" "$wifi_env"
grep -Fqx "SECURITY_5G='open'" "$wifi_env"
grep -Fqx "MFP_2G='0'" "$wifi_env"
grep -Fqx "MFP_5G='0'" "$wifi_env"
grep -Fqx "FT_2G='0'" "$wifi_env"
grep -Fqx "FT_5G='0'" "$wifi_env"

# If hostapd/the driver rejects a valid candidate at restart time, put the
# previous profile back and make one bounded attempt to restore its radios.
init_dir=$temporary/init.d
restart_count=$temporary/restart-count
mkdir -p "$init_dir"
cat > "$init_dir/rg-ma2820-wifi" <<'EOF'
#!/bin/sh
count=$(cat "$RG_TEST_RESTART_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$RG_TEST_RESTART_COUNT"
[ "$count" -ge 2 ]
EOF
for service in rg-ma2820-roaming rg-ma2820-neighbor-sync; do
	cat > "$init_dir/$service" <<'EOF'
#!/bin/sh
exit 0
EOF
done
chmod 0755 "$init_dir"/*
before=$(sha256sum "$wifi_env")
rollback_payload=$(printf '%s' "$open_payload" | jq -c '.ssid_2g="Rollback Test"')
if RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_JSONFILTER=$jsonfilter RG_MA2820_INIT_DIR=$init_dir \
	RG_TEST_RESTART_COUNT=$restart_count \
	sh "$setter" --configure-json "$rollback_payload" >/dev/null 2>&1; then
	echo 'JSON setter accepted a failed radio restart' >&2
	exit 1
fi
[ "$(sha256sum "$wifi_env")" = "$before" ]
[ "$(cat "$restart_count")" = 2 ]

echo 'LuCI JSON Wi-Fi profile tests: PASS'
