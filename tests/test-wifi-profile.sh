#!/usr/bin/env bash
# Unit-test channel scoring and generated hostapd security/BSS topology.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-wifi-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

scan=$temporary/scan.txt
cat > "$scan" <<'EOF'
SSID: "strong-low"
Mode: Managed RSSI: -40 dBm SNR: 40 dB noise: -80 dBm Channel: 1
SSID: "weak-middle"
Mode: Managed RSSI: -90 dBm SNR: 1 dB noise: -91 dBm Channel: 6
SSID: "strong-5g-low"
Mode: Managed RSSI: -40 dBm SNR: 40 dB noise: -80 dBm Channel: 36/80
SSID: "weak-5g-high"
Mode: Managed RSSI: -90 dBm SNR: 1 dB noise: -91 dBm Channel: 149/80
EOF

selector=$project_dir/persistent-overlay/usr/libexec/rg-ma2820/channel-select
[ "$(RG_MA2820_SCAN_RESULTS=$scan sh "$selector" wl0 2g 1)" = 11 ]
[ "$(RG_MA2820_SCAN_RESULTS=$scan sh "$selector" wl0 2g 1 11)" = 6 ]
[ "$(RG_MA2820_SCAN_RESULTS=$scan sh "$selector" wl1 5g 36)" = 149 ]
[ "$(RG_MA2820_SCAN_RESULTS=$scan sh "$selector" wl1 5g 36 149)" = 36 ]

empty=$temporary/empty.txt
: > "$empty"
[ "$(RG_MA2820_SCAN_RESULTS=$empty sh "$selector" wl0 2g 6)" = 6 ]
[ "$(RG_MA2820_SCAN_RESULTS=$empty sh "$selector" wl1 5g 149)" = 149 ]

wifi_env=$temporary/wifi.env
device_env=$temporary/device.env
cat > "$wifi_env" <<'EOF'
WIFI_CONFIG_VERSION='2'
WIFI_PROFILE='wired-mesh'
SSID_2G='Community-IoT'
SSID_5G='Community-5G'
SSID_5G_LEGACY='Community-5G-Legacy'
ENABLE_5G_LEGACY='1'
WPA_PSK='communitypass123'
COUNTRY_CODE='#a'
MOBILITY_DOMAIN='4d41'
CHANNEL_2G='auto'
CHANNEL_5G='auto'
FALLBACK_CHANNEL_2G='1'
FALLBACK_CHANNEL_5G='36'
WIDTH_5G='80'
EOF
cat > "$device_env" <<'EOF'
DEVICE_ID='ap2'
HOSTNAME='rg-ma2820-ap2'
LOCAL_BSSID_2G='02:00:00:00:02:20'
LOCAL_BSSID_5G='02:00:00:00:02:50'
LOCAL_BSSID_5G_LEGACY='02:00:00:00:02:51'
PEER_BSSID_2G='02:00:00:00:03:20'
PEER_BSSID_5G='02:00:00:00:03:50'
PEER_BSSID_5G_LEGACY='02:00:00:00:03:51'
PEER_HOSTNAME='rg-ma2820-ap3'
PEER_ID='ap3'
RESCUE_LINK_LOCAL='169.254.20.2'
EOF

config_2g=$temporary/hostapd-wl0.conf
config_5g=$temporary/hostapd-wl1.conf
wifi_init=$project_dir/hybrid-overlay/etc/init.d/rg-ma2820-wifi
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	CONFIG_2G=$config_2g CONFIG_5G=$config_5g WIFI_INIT="$wifi_init" \
	sh -c '. "$WIFI_INIT"; SELECTED_CHANNEL_2G=11; SELECTED_CHANNEL_5G=149; SELECTED_CENTER_CHANNEL_5G=155; write_wired_mesh_config wl0 g "$CONFIG_2G"; write_wired_mesh_config wl1 a "$CONFIG_5G"'

grep -qx 'ssid2=436f6d6d756e6974792d496f54' "$config_2g"
grep -qx 'wpa_key_mgmt=WPA-PSK' "$config_2g"
grep -qx 'ieee80211w=0' "$config_2g"
! grep -q '^bss=' "$config_2g"
! grep -q 'FT-PSK' "$config_2g"

grep -qx 'ssid2=436f6d6d756e6974792d3547' "$config_5g"
grep -qx 'wpa_key_mgmt=SAE FT-SAE' "$config_5g"
grep -qx 'ieee80211w=2' "$config_5g"
grep -qx 'mobility_domain=4d41' "$config_5g"
grep -qx 'nas_identifier=rg-ma2820-ap2-5g' "$config_5g"
grep -Eq '^r0kh=02:00:00:00:03:50 rg-ma2820-ap3-5g [0-9a-f]{64}$' "$config_5g"
grep -Eq '^r1kh=02:00:00:00:03:50 02:00:00:00:03:50 [0-9a-f]{64}$' "$config_5g"
grep -qx 'bss=wl1.1' "$config_5g"
grep -qx 'ssid2=436f6d6d756e6974792d35472d4c6567616379' "$config_5g"
grep -qx 'wpa_key_mgmt=WPA-PSK FT-PSK' "$config_5g"
[ "$(grep -c '^rrm_neighbor_report=1$' "$config_5g")" = 2 ]

# Cold Broadcom radios reject qtxpower before hostapd starts. Keep that call
# out of prepare_radio, then retry it in the post-hostapd phase.
! sed -n '/^prepare_radio()/,/^enforce_post_hostapd_settings()/p' "$wifi_init" |
	grep -q 'set_radio_txpower'
sed -n '/^enforce_post_hostapd_settings()/,/^verify_legacy_bss()/p' "$wifi_init" |
	grep -q 'set_radio_txpower'
mock_wl=$temporary/mock-wl
txpower_count=$temporary/txpower-count
cat > "$mock_wl" <<'EOF'
#!/bin/sh
expected=${RG_TEST_EXPECTED_QDBM:-92}
case "$*" in
	*"txpwr1 -q $expected")
		count=$(cat "$RG_MA2820_TXPOWER_COUNT" 2>/dev/null || echo 0)
		count=$((count + 1))
		echo "$count" > "$RG_MA2820_TXPOWER_COUNT"
		[ "$count" -ge 3 ]
		;;
	*"txpwr1")
		echo "TxPower is $expected qdbm, 23.0 dbm, 200 mW  Override is Off"
		;;
	*) exit 1 ;;
esac
EOF
chmod 0755 "$mock_wl"
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_WL=$mock_wl RG_MA2820_TXPOWER_COUNT=$txpower_count \
	WIFI_INIT=$wifi_init \
	sh -c '. "$WIFI_INIT"; sleep() { :; }; set_radio_txpower wl1 a'
[ "$(cat "$txpower_count")" = 3 ]

# BCA 17.10 wraps the documented legacy `txpwr -1` reset to -64 qdBm.
# Automatic power must use and verify the driver's qtxpower 127 sentinel.
rm -f "$txpower_count"
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_WL=$mock_wl RG_MA2820_TXPOWER_COUNT=$txpower_count \
	RG_TEST_EXPECTED_QDBM=127 WIFI_INIT=$wifi_init \
	sh -c '. "$WIFI_INIT"; sleep() { :; }; set_radio_txpower wl0 g'
[ "$(cat "$txpower_count")" = 3 ]
! sed -n '/^set_radio_txpower()/,/^apply_driver_option()/p' "$wifi_init" |
	grep -q '\$WL .*txpwr -1'

# Wi-Fi starts before netifd has necessarily finished building br-lan. Wait
# for the deterministic rescue address, then retry peer state instead of
# silently choosing a colliding channel after one early connection failure.
mock_ip=$temporary/mock-ip
mock_peer=$temporary/mock-peer
ip_count=$temporary/ip-count
peer_count=$temporary/peer-count
cat > "$mock_ip" <<'EOF'
#!/bin/sh
count=$(cat "$RG_MA2820_IP_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$RG_MA2820_IP_COUNT"
[ "$count" -ge 3 ] || exit 1
echo '14: br-lan inet 169.254.20.2/16 scope global br-lan:rescue'
EOF
cat > "$mock_peer" <<'EOF'
#!/bin/sh
# A boot service may inherit an open console. The peer reader must explicitly
# close stdin or Dropbear can keep an otherwise completed SSH session alive.
if IFS= read -r unexpected; then
	exit 97
fi
count=$(cat "$RG_MA2820_PEER_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$RG_MA2820_PEER_COUNT"
[ "$count" -ge 3 ] || exit 1
cat <<'STATE'
FORMAT=1
DEVICE_ID=ap3
PROFILE=wired-mesh
CHANNEL_2G=11
CHANNEL_5G=36
CENTER_CHANNEL_5G=42
STATE
EOF
chmod 0755 "$mock_ip" "$mock_peer"
peer_channels=$(RG_MA2820_WIFI_ENV=$wifi_env \
	RG_MA2820_DEVICE_ENV=$device_env RG_MA2820_IP=$mock_ip \
	RG_MA2820_PEER=$mock_peer RG_MA2820_IP_COUNT=$ip_count \
	RG_MA2820_PEER_COUNT=$peer_count RG_MA2820_PEER_NETWORK_WAIT=4 \
	RG_MA2820_PEER_NETWORK_POLL=1 RG_MA2820_PEER_RETRY_DELAY=0 \
	RG_MA2820_PEER_ATTEMPTS_AP2=3 WIFI_INIT=$wifi_init \
	sh -c '. "$WIFI_INIT"; read_peer_channels; printf "%s %s\n" "$PEER_SELECTED_CHANNEL_2G" "$PEER_SELECTED_CHANNEL_5G"' \
	< <(yes inherited-stdin))
[ "$peer_channels" = '11 36' ]
[ "$(cat "$ip_count")" = 3 ]
[ "$(cat "$peer_count")" = 3 ]

# If a race still produces equal channels, neighbor sync deterministically
# restarts AP2 once. AP3 never counters by restarting itself, preventing loops.
local_state=$temporary/local-state
peer_state=$temporary/peer-state
peer_cache=$temporary/peer-cache
collision_marker=$temporary/collision-marker
restart_log=$temporary/restart-log
mock_wifi_init=$temporary/mock-wifi-init
cat > "$local_state" <<'EOF'
FORMAT=1
DEVICE_ID=ap2
PROFILE=wired-mesh
CONFIG_HASH=test-profile
RADIO_2G_ENABLED=1
RADIO_5G_ENABLED=1
ENABLE_5G_LEGACY=1
CHANNEL_2G=11
CHANNEL_5G=149
CENTER_CHANNEL_5G=155
NEIGHBOR_CHANNEL_5G=155
OP_CLASS_5G=128
WIDTH_5G=80
BSSID_2G=02:00:00:00:02:20
BSSID_5G=02:00:00:00:02:50
BSSID_5G_LEGACY=02:00:00:00:02:51
SSID_HEX_2G=436f6d6d756e6974792d496f54
SSID_HEX_5G=436f6d6d756e6974792d3547
SSID_HEX_5G_LEGACY=436f6d6d756e6974792d35472d4c6567616379
EOF
cat > "$peer_state" <<'EOF'
FORMAT=1
DEVICE_ID=ap3
PROFILE=wired-mesh
CONFIG_HASH=test-profile
RADIO_2G_ENABLED=1
RADIO_5G_ENABLED=1
ENABLE_5G_LEGACY=1
CHANNEL_2G=11
CHANNEL_5G=36
CENTER_CHANNEL_5G=42
NEIGHBOR_CHANNEL_5G=42
OP_CLASS_5G=128
WIDTH_5G=80
BSSID_2G=02:00:00:00:03:20
BSSID_5G=02:00:00:00:03:50
BSSID_5G_LEGACY=02:00:00:00:03:51
SSID_HEX_2G=436f6d6d756e6974792d496f54
SSID_HEX_5G=436f6d6d756e6974792d3547
SSID_HEX_5G_LEGACY=436f6d6d756e6974792d35472d4c6567616379
EOF
cat > "$mock_peer" <<EOF
#!/bin/sh
cat '$peer_state'
EOF
cat > "$mock_wifi_init" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$restart_log'
EOF
chmod 0755 "$mock_peer" "$mock_wifi_init"
printf '%s\n' stale-neighbor-cache > "$peer_cache"
neighbor_sync=$project_dir/persistent-overlay/usr/libexec/rg-ma2820/neighbor-sync
neighbor_env=(
	RG_MA2820_WIFI_ENV="$wifi_env"
	RG_MA2820_DEVICE_ENV="$device_env"
	RG_MA2820_PEER="$mock_peer"
	RG_MA2820_WIFI_INIT="$mock_wifi_init"
	RG_MA2820_WIFI_STATE="$local_state"
	RG_MA2820_PEER_WIFI_STATE="$peer_cache"
	RG_MA2820_COLLISION_MARKER="$collision_marker"
	RG_MA2820_HOSTAPD_CLI=/bin/false
	RG_MA2820_NEIGHBOR_ONESHOT=1
)
if env "${neighbor_env[@]}" sh "$neighbor_sync"; then
	echo 'neighbor sync accepted a channel collision' >&2
	exit 1
fi
[ "$(cat "$restart_log")" = restart ]
[ -e "$collision_marker" ]
[ ! -e "$peer_cache" ]
if env "${neighbor_env[@]}" sh "$neighbor_sync"; then
	echo 'neighbor sync accepted a repeated channel collision' >&2
	exit 1
fi
[ "$(wc -l < "$restart_log")" = 1 ]
sed -i 's/^CHANNEL_2G=11$/CHANNEL_2G=1/' "$local_state"
if env "${neighbor_env[@]}" sh "$neighbor_sync"; then
	echo 'mock neighbor install unexpectedly succeeded' >&2
	exit 1
fi
[ ! -e "$collision_marker" ]

grep -q 'channel_plan_ok=0' \
	"$project_dir/persistent-overlay/usr/sbin/rg-ma2820-wifi-status"
grep -q 'channel plan overlaps' \
	"$project_dir/persistent-overlay/www/luci-static/resources/view/rg-ma2820/wireless.js"

# hostapd creates wl1.1 asynchronously on cold boot. The verifier must wait
# for the correct allocated BSSID instead of failing on its first sysfs read.
net_class=$temporary/net-class
(
	sleep 0.2
	mkdir -p "$net_class/wl1.1"
	printf '%s\n' '02:00:00:00:02:51' > "$net_class/wl1.1/address"
) &
vif_creator=$!
RG_MA2820_WIFI_ENV=$wifi_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_NET_CLASS=$net_class WIFI_INIT=$wifi_init \
	sh -c '. "$WIFI_INIT"; verify_legacy_bss'
wait "$vif_creator"

# LuCI uses the advanced setter with --keep, so verify that tuning changes do
# not expose or accidentally replace the existing operational passphrase.
managed_env=$temporary/managed.env
cp "$wifi_env" "$managed_env"
RG_MA2820_WIFI_ENV=$managed_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_NO_RESTART=1 \
	sh "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-set-wifi" \
	--configure-owner Community-IoT Community-5G Community-5G-Legacy --keep auto 23 -70 -84 0 \
	>/dev/null
grep -qx "WPA_PSK='communitypass123'" "$managed_env"
grep -qx "TXPOWER_5G_DBM='23'" "$managed_env"
grep -qx "ROAM_RSSI_TRIGGER='-70'" "$managed_env"
grep -qx "ROAM_RSSI_HARD='-84'" "$managed_env"
grep -qx "ROAM_HARD_FALLBACK='0'" "$managed_env"
before=$(sha256sum "$managed_env")
if RG_MA2820_WIFI_ENV=$managed_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_NO_RESTART=1 \
	sh "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-set-wifi" \
	--configure-owner "bad'name" Community-5G Community-5G-Legacy --keep auto 23 -70 -84 0 \
	>/dev/null 2>&1; then
	echo 'advanced setter accepted an invalid SSID' >&2
	exit 1
fi
[ "$(sha256sum "$managed_env")" = "$before" ]

# LuCI must also be able to rebuild the owner profile after firstboot/factory
# reset. There is no key to keep in that state, so reject --keep without
# touching the file and accept an explicit new key.
factory_env=$temporary/factory.env
cat > "$factory_env" <<'EOF'
WIFI_CONFIG_VERSION='2'
WIFI_PROFILE='factory'
SSID_BASE='RG-MA2820-Mesh'
WIFI_SECURITY='open'
WPA_PSK=''
COUNTRY_CODE='#a'
CHANNEL_2G='1'
CHANNEL_5G='36'
EOF
factory_before=$(sha256sum "$factory_env")
if RG_MA2820_WIFI_ENV=$factory_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_NO_RESTART=1 \
	sh "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-set-wifi" \
	--configure-owner Community-IoT Community-5G Community-5G-Legacy --keep auto 23 -72 -82 1 \
	>/dev/null 2>&1; then
	echo 'factory profile unexpectedly preserved an empty password' >&2
	exit 1
fi
[ "$(sha256sum "$factory_env")" = "$factory_before" ]
RG_MA2820_WIFI_ENV=$factory_env RG_MA2820_DEVICE_ENV=$device_env \
	RG_MA2820_NO_RESTART=1 \
	sh "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-set-wifi" \
	--configure-owner Community-IoT Community-5G Community-5G-Legacy communitypass123 auto 23 -72 -82 1 \
	>/dev/null
grep -qx "WIFI_CONFIG_VERSION='3'" "$factory_env"
grep -qx "WIFI_PROFILE='wired-mesh'" "$factory_env"
grep -qx "WPA_PSK='communitypass123'" "$factory_env"

echo 'wired-mesh Wi-Fi profile tests: PASS'
