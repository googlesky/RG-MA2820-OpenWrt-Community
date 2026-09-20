#!/usr/bin/env bash
# Verify that a new A/B trial is not accepted with a partial Wi-Fi/UI stack.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-boot-success-test.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
mock_bin=$work_dir/bin
mkdir -p "$mock_bin"

cat > "$mock_bin/hostapd_cli" <<'EOF'
#!/bin/sh
interface=
while [ "$#" -gt 0 ]; do
	[ "$1" != -i ] || interface=$2
	shift
done
if [ -n "${RG_TEST_DISABLED_INTERFACE:-}" ] &&
	[ "$interface" = "$RG_TEST_DISABLED_INTERFACE" ]; then
	echo state=DISABLED
else
	echo state=ENABLED
fi
EOF
cat > "$mock_bin/pidof" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$mock_bin/ubus" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -v ]; then
	echo "'luci.rg-ma2820' @00000000"
	echo '\t"overview":{}'
	[ -e "${RG_TEST_STATE_DIR:?}/stale-rpc" ] || {
		echo '\t"timezone_status":{}'
		echo '\t"configure_timezone":{}'
	}
elif [ "${1:-}" = call ] && [ "${2:-}" = luci.rg-ma2820 ] &&
	[ "${3:-}" = status ]; then
	[ ! -e "${RG_TEST_STATE_DIR:?}/failed-rpc-status" ] || exit 1
	if [ -e "$RG_TEST_STATE_DIR/wrong-rpc-status" ]; then
		echo '{"device_id":"unexpected","peer_status":{"available":true,"online":true,"device_id":"ap3"}}'
	elif [ -e "$RG_TEST_STATE_DIR/broken-rpc-schema" ]; then
		echo '{"device_id":"ap2","peer_status":{"device_id":"ap3"}}'
	else
		echo '{"device_id":"ap2","peer_status":{"available":true,"online":true,"device_id":"ap3"}}'
	fi
else
	echo luci.rg-ma2820
fi
EOF
cat > "$mock_bin/jsonfilter" <<'EOF'
#!/bin/sh
[ "${1:-}" = -e ] && [ "$#" -eq 2 ] || exit 2
expression=${2#@}
jq -r "$expression"
EOF
cat > "$mock_bin/wl" <<'EOF'
#!/bin/sh
case "$2" in
	wl0) qdbm=${RG_TEST_TXPOWER_2G_QDBM:-127} ;;
	wl1) qdbm=${RG_TEST_TXPOWER_5G_QDBM:-92} ;;
	*) exit 1 ;;
esac
echo "TxPower is $qdbm qdbm, 23.0 dbm, 200 mW  Override is Off"
EOF
cat > "$work_dir/status" <<'EOF'
#!/bin/sh
echo '{}'
EOF
cat > "$work_dir/roaming" <<'EOF'
#!/bin/sh
[ "${1:-}" = status ]
EOF
cat > "$work_dir/rpcd" <<'EOF'
#!/bin/sh
[ "${1:-}" = restart ] || exit 2
count=$(cat "${RG_TEST_STATE_DIR:?}/rpc-restart-count" 2>/dev/null || echo 0)
echo $((count + 1)) > "$RG_TEST_STATE_DIR/rpc-restart-count"
[ -e "$RG_TEST_STATE_DIR/keep-stale-rpc" ] || rm -f "$RG_TEST_STATE_DIR/stale-rpc"
EOF
cat > "$work_dir/bootstate" <<'EOF'
#!/bin/sh
cat "$RG_TEST_BOOTSTATE_FILE"
EOF
cp "$work_dir/status" "$work_dir/capabilities"
cp "$work_dir/status" "$work_dir/scan"
cp "$work_dir/status" "$work_dir/overview"
cp "$work_dir/status" "$work_dir/timezone"
printf '%s\n' test > "$work_dir/zoneinfo.uc"
chmod 0755 "$mock_bin"/* "$work_dir/status" "$work_dir/capabilities" \
	"$work_dir/scan" "$work_dir/overview" "$work_dir/timezone" \
	"$work_dir/roaming" "$work_dir/rpcd" "$work_dir/bootstate"

cat > "$work_dir/wifi.state" <<'EOF'
FORMAT=1
PROFILE=wired-mesh
EOF
cat > "$work_dir/wifi.env" <<'EOF'
WIFI_PROFILE='wired-mesh'
ENABLE_5G_LEGACY='1'
TXPOWER_5G_DBM='23'
EOF
cat > "$work_dir/device.env" <<'EOF'
DEVICE_ID='ap2'
PEER_ID='ap3'
EOF
cat > "$work_dir/hostapd-wl1.conf" <<'EOF'
wpa_key_mgmt=SAE FT-SAE
wpa_key_mgmt=WPA-PSK FT-PSK
EOF
for file in rpc.uc menu.json wireless.js overview.js base.vi.lmo rg-ma2820.vi.lmo; do
	printf '%s\n' test > "$work_dir/$file"
done

cat > "$work_dir/state-trial" <<'EOF'
active=b
pending=a
booting=a
EOF
cat > "$work_dir/state-accepted" <<'EOF'
active=a
pending=none
booting=a
EOF
cat > "$work_dir/state-invalid" <<'EOF'
active=b
pending=a
booting=b
EOF

run_trial_gate()
{
	PATH="$mock_bin:$PATH" \
	RG_MA2820_HOSTAPD_CLI="$mock_bin/hostapd_cli" \
	RG_MA2820_HOSTAPD_5G_CONFIG="$work_dir/hostapd-wl1.conf" \
	RG_MA2820_WIFI_STATE="$work_dir/wifi.state" \
	RG_MA2820_WIFI_ENV="$work_dir/wifi.env" \
	RG_MA2820_DEVICE_ENV="$work_dir/device.env" \
	RG_MA2820_STATUS_HELPER="$work_dir/status" \
	RG_MA2820_OVERVIEW_HELPER="$work_dir/overview" \
	RG_MA2820_CAPABILITY_HELPER="$work_dir/capabilities" \
	RG_MA2820_SCAN_HELPER="$work_dir/scan" \
	RG_MA2820_TIMEZONE_HELPER="$work_dir/timezone" \
	RG_MA2820_TIMEZONE_DATABASE="$work_dir/zoneinfo.uc" \
	RG_MA2820_RPC_UCODE="$work_dir/rpc.uc" \
	RG_MA2820_LUCI_MENU="$work_dir/menu.json" \
	RG_MA2820_LUCI_VIEW="$work_dir/wireless.js" \
	RG_MA2820_LUCI_OVERVIEW="$work_dir/overview.js" \
	RG_MA2820_LUCI_I18N_BASE="$work_dir/base.vi.lmo" \
	RG_MA2820_LUCI_I18N_APP="$work_dir/rg-ma2820.vi.lmo" \
	RG_MA2820_ROAMING_INIT="$work_dir/roaming" \
	RG_MA2820_RPC_INIT="$work_dir/rpcd" \
	RG_MA2820_RPC_RELOAD_MARKER="$work_dir/rpc-reloads" \
	RG_MA2820_RPC_RELOAD_DELAY=0 \
	RG_MA2820_WL="$mock_bin/wl" \
	RG_MA2820_JSONFILTER="$mock_bin/jsonfilter" \
	RG_TEST_STATE_DIR="$work_dir" \
	RG_TEST_DISABLED_INTERFACE="${RG_TEST_DISABLED_INTERFACE:-}" \
	RG_TEST_TXPOWER_2G_QDBM="${RG_TEST_TXPOWER_2G_QDBM:-127}" \
	RG_TEST_TXPOWER_5G_QDBM="${RG_TEST_TXPOWER_5G_QDBM:-92}" \
	BOOT_SUCCESS="$project_dir/persistent-overlay/etc/init.d/rg-ma2820-boot-success" \
		sh -c '. "$BOOT_SUCCESS"; trial_system_healthy'
}

run_trial_gate
[ ! -e "$work_dir/rpc-restart-count" ]

# An upgraded overlay may contain the previous RPC plugin when rpcd starts.
# The gate must reload it once and validate the new timezone methods before it
# can begin the 90-second acceptance window.
touch "$work_dir/stale-rpc"
run_trial_gate
[ "$(cat "$work_dir/rpc-restart-count")" = 1 ]
[ ! -e "$work_dir/stale-rpc" ]

touch "$work_dir/stale-rpc" "$work_dir/keep-stale-rpc"
rm -f "$work_dir/rpc-reloads"
if run_trial_gate; then
	echo 'trial gate accepted a stale RPC API after reload' >&2
	exit 1
fi
rm -f "$work_dir/stale-rpc" "$work_dir/keep-stale-rpc" "$work_dir/rpc-reloads"

touch "$work_dir/failed-rpc-status"
if run_trial_gate; then
	echo 'trial gate accepted an RPC status call failure' >&2
	exit 1
fi
rm -f "$work_dir/failed-rpc-status"

touch "$work_dir/wrong-rpc-status"
if run_trial_gate; then
	echo 'trial gate accepted the wrong local RPC identity' >&2
	exit 1
fi
rm -f "$work_dir/wrong-rpc-status"

touch "$work_dir/broken-rpc-schema"
if run_trial_gate; then
	echo 'trial gate accepted an incomplete peer-status schema' >&2
	exit 1
fi
rm -f "$work_dir/broken-rpc-schema"

run_boot_mode()
{
	RG_MA2820_BOOTSTATE="$work_dir/bootstate" \
	RG_MA2820_RECOVERY_ROOT="$work_dir/no-recovery-marker" \
	RG_TEST_BOOTSTATE_FILE="$1" \
	BOOT_SUCCESS="$project_dir/persistent-overlay/etc/init.d/rg-ma2820-boot-success" \
		sh -c '. "$BOOT_SUCCESS"; boot_health_mode'
}

[ "$(run_boot_mode "$work_dir/state-trial")" = trial ]
[ "$(run_boot_mode "$work_dir/state-accepted")" = accepted ]
if run_boot_mode "$work_dir/state-invalid" >/dev/null 2>&1; then
	echo 'boot gate accepted an inconsistent A/B state' >&2
	exit 1
fi

mv "$work_dir/wifi.state" "$work_dir/wifi.state.absent"
if run_trial_gate; then
	echo 'trial gate accepted a missing radio state' >&2
	exit 1
fi
mv "$work_dir/wifi.state.absent" "$work_dir/wifi.state"

RG_TEST_DISABLED_INTERFACE=wl1.1
if run_trial_gate; then
	echo 'trial gate accepted a disabled legacy BSS' >&2
	exit 1
fi
unset RG_TEST_DISABLED_INTERFACE

RG_TEST_TXPOWER_5G_QDBM=127
if run_trial_gate; then
	echo 'trial gate accepted the wrong 5 GHz TX power' >&2
	exit 1
fi
unset RG_TEST_TXPOWER_5G_QDBM

RG_TEST_TXPOWER_2G_QDBM=-64
if run_trial_gate; then
	echo 'trial gate accepted the broken automatic 2.4 GHz TX power sentinel' >&2
	exit 1
fi
unset RG_TEST_TXPOWER_2G_QDBM

echo 'A/B trial full-stack health-gate tests: PASS'
