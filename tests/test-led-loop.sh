#!/usr/bin/env bash
# Verify the stock opcode map and the operational state-to-LED policy.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/thermal" "$tmp_dir/init"
for interface in eth0 eth1 eth2 eth3 eth4; do
	mkdir -p "$tmp_dir/net/$interface"
	printf '0\n' > "$tmp_dir/net/$interface/carrier"
done
printf '1\n' > "$tmp_dir/net/eth0/carrier"
set_carriers() {
	local index=0 value
	for value in "$@"; do
		printf '%s\n' "$value" > "$tmp_dir/net/eth$index/carrier"
		index=$((index + 1))
	done
}
printf '70000\n' > "$tmp_dir/thermal/temp"
printf '110000\n' > "$tmp_dir/thermal/trip_point_0_temp"
printf '0\n' > "$tmp_dir/bad_pebs"
cat > "$tmp_dir/wifi.env" <<'EOF'
WIFI_PROFILE='wired-mesh'
RADIO_2G_ENABLED='1'
RADIO_5G_ENABLED='1'
ENABLE_5G_LEGACY='1'
EOF
cat > "$tmp_dir/device.env" <<'EOF'
PEER_LINK_LOCAL='169.254.20.3'
EOF
cat > "$tmp_dir/wifi.state" <<'EOF'
PROFILE=wired-mesh
CONFIG_HASH=abc123
CHANNEL_2G=1
CENTER_CHANNEL_5G=155
RADIO_2G_ENABLED=1
RADIO_5G_ENABLED=1
EOF
cat > "$tmp_dir/peer.state" <<'EOF'
PROFILE=wired-mesh
CONFIG_HASH=abc123
CHANNEL_2G=11
CENTER_CHANNEL_5G=42
EOF

cat > "$tmp_dir/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  '-4 addr show dev br-lan') [ "${IP_ADDRESS:-1}" = 1 ] && echo 'inet 192.0.2.2/24 scope global br-lan' ;;
  '-4 route show default') [ "${DEFAULT_ROUTE:-1}" = 1 ] && echo 'default via 192.0.2.1 dev br-lan' ;;
  'neigh show 192.0.2.1 dev br-lan') [ "${NEIGHBOR_OK:-0}" = 1 ] && echo '192.0.2.1 lladdr 00:11:22:33:44:55 REACHABLE' ;;
esac
EOF
cat > "$tmp_dir/bin/ping" <<'EOF'
#!/bin/sh
eval "target=\${$#}"
case "$target" in
  192.0.2.1) [ "${GATEWAY_OK:-1}" = 1 ] ;;
  169.254.20.3) [ "${PEER_OK:-1}" = 1 ] ;;
  *) exit 1 ;;
esac
EOF
cat > "$tmp_dir/bin/hostapd_cli" <<'EOF'
#!/bin/sh
[ "${RADIOS_OK:-1}" = 1 ] && echo 'state=ENABLED'
EOF
cat > "$tmp_dir/bin/pidof" <<'EOF'
#!/bin/sh
[ "${CORE_OK:-1}" = 1 ]
EOF
cat > "$tmp_dir/bin/bootstate" <<'EOF'
#!/bin/sh
echo "pending=${PENDING_SLOT:-none}"
echo "booting=${BOOTING_SLOT:-none}"
EOF
for service in roaming neighbor; do
	cat > "$tmp_dir/init/$service" <<'EOF'
#!/bin/sh
[ "${MESH_SERVICES_OK:-1}" = 1 ]
EOF
done
chmod +x "$tmp_dir/bin/"* "$tmp_dir/init/"*

run_controller() {
	env \
		RG_MA2820_LED_PROC="$tmp_dir/factory_led" \
		RG_MA2820_ENET_CONTROL="$tmp_dir/enet-control" \
		RG_MA2820_LED_STATE="$tmp_dir/led.state" \
		RG_MA2820_NET_CLASS="$tmp_dir/net" \
		RG_MA2820_NET_DEV="$tmp_dir/net-dev" \
		RG_MA2820_THERMAL_ZONE="$tmp_dir/thermal" \
		RG_MA2820_BAD_PEB_FILE="$tmp_dir/bad_pebs" \
		RG_MA2820_WIFI_ENV="$tmp_dir/wifi.env" \
		RG_MA2820_DEVICE_ENV="$tmp_dir/device.env" \
		RG_MA2820_WIFI_STATE="$tmp_dir/wifi.state" \
		RG_MA2820_PEER_WIFI_STATE="$tmp_dir/peer.state" \
		RG_MA2820_BOOTSTATE="$tmp_dir/bin/bootstate" \
		RG_MA2820_RECOVERY_MARKER="$tmp_dir/recovery" \
		RG_MA2820_ROAMING_INIT="$tmp_dir/init/roaming" \
		RG_MA2820_NEIGHBOR_INIT="$tmp_dir/init/neighbor" \
		RG_MA2820_IP="$tmp_dir/bin/ip" \
		RG_MA2820_PING="$tmp_dir/bin/ping" \
		RG_MA2820_HOSTAPD_CLI="$tmp_dir/bin/hostapd_cli" \
		RG_MA2820_PIDOF="$tmp_dir/bin/pidof" \
		RG_MA2820_LED_WAN_FAILURE_LIMIT=1 \
		RG_MA2820_LED_ONESHOT=1 \
		"$@" sh "$project_dir/persistent-overlay/usr/libexec/rg-ma2820/led-loop"
}

run_case() {
	local name=$1 bytes=$2 expected=$3
	shift 3
	rm -f "$tmp_dir/factory_led" "$tmp_dir/capture" "$tmp_dir/led.state"
	: > "$tmp_dir/enet-control"
	mkfifo "$tmp_dir/factory_led"
	# Keep one read/write descriptor open across the controller's individual
	# proc-style writes so the collector does not treat each close as EOF.
	exec 9<>"$tmp_dir/factory_led"
	(
		timeout 5 dd if="$tmp_dir/factory_led" of="$tmp_dir/capture" bs=1 count=4 status=none
		# Check ownership when the first LED command arrives, not merely after
		# the controller exits: stock ENET work otherwise overwrites WAN/LAN.
		[ "$(cat "$tmp_dir/enet-control")" = 'factory_mode 1' ] || {
			echo "$name wrote an LED before claiming Ethernet LED ownership" >&2
			exit 1
		}
		timeout 5 dd if="$tmp_dir/factory_led" bs=1 count="$((bytes - 4))" status=none >> "$tmp_dir/capture"
	) &
	local reader=$!
	run_controller "$@"
	exec 9>&-
	wait "$reader"
	[ "$(cat "$tmp_dir/capture")" = "$expected" ] || {
		echo "$name LED sequence mismatch: $(cat "$tmp_dir/capture")" >&2
		exit 1
	}
}

# A WAN-only uplink must not illuminate LAN sockets with no cable attached.
run_case healthy 34 '1601150014001300120030014011201301'
grep -q '^POWER=normal$' "$tmp_dir/led.state"
grep -q '^UPLINK=online$' "$tmp_dir/led.state"
grep -q '^WAN=ready$' "$tmp_dir/led.state"
grep -q '^LAN=disconnected$' "$tmp_dir/led.state"
grep -q '^WAN_CARRIER=1$' "$tmp_dir/led.state"
grep -q '^LAN_CARRIER=0$' "$tmp_dir/led.state"
grep -q '^WIFI=ready$' "$tmp_dir/led.state"
grep -q '^MESH=ready$' "$tmp_dir/led.state"

# A real uplink failure lights only WAN red; missing radios and peer remain off.
run_case failed 27 '160115001400130012003001501' \
	GATEWAY_OK=0 NEIGHBOR_OK=0 RADIOS_OK=0 PEER_OK=0 RG_MA2820_LED_WAN_COLOR_MODE=green
grep -q '^WAN=degraded$' "$tmp_dir/led.state"
grep -q '^WIFI=offline$' "$tmp_dir/led.state"
grep -q '^MESH=offline$' "$tmp_dir/led.state"

# Direction mode reserves red for TX; uplink faults remain exported to UI.
run_case direction-uplink-failure 27 '160115001400130012003001401' \
	GATEWAY_OK=0 NEIGHBOR_OK=0 RADIOS_OK=0 PEER_OK=0
grep -q '^UPLINK=degraded$' "$tmp_dir/led.state"
grep -q '^WAN=ready$' "$tmp_dir/led.state"

# Trial boot uses a slow power blink. Phase 2 is the off half of that pattern.
run_case trial 38 '16011500140013001200300160014011201301' \
	PENDING_SLOT=b RG_MA2820_LED_PHASE=2
grep -q '^POWER=trial$' "$tmp_dir/led.state"

# Bridging works through LAN too, but an empty WAN socket stays off, not red.
set_carriers 0 0 0 1 0
run_case lan-uplink 34 '1601150014001300120030013011201301'
grep -q '^UPLINK=online$' "$tmp_dir/led.state"
grep -q '^WAN=disconnected$' "$tmp_dir/led.state"
grep -q '^LAN=ready$' "$tmp_dir/led.state"
grep -q '^WAN_CARRIER=0$' "$tmp_dir/led.state"
grep -q '^LAN_CARRIER=1$' "$tmp_dir/led.state"
run_case lan-before-dhcp 34 '1601150014001300120030013011201301' IP_ADDRESS=0
grep -q '^UPLINK=degraded$' "$tmp_dir/led.state"
grep -q '^WAN=disconnected$' "$tmp_dir/led.state"
grep -q '^LAN=ready$' "$tmp_dir/led.state"
set_carriers 1 0 0 1 0
run_case both-port-groups 38 '16011500140013001200300140113011201301'
set_carriers 0 0 0 0 0
run_case no-cables 30 '160115001400130012003001201301'
grep -q '^CARRIER=0$' "$tmp_dir/led.state"
grep -q '^WAN=disconnected$' "$tmp_dir/led.state"
grep -q '^LAN=disconnected$' "$tmp_dir/led.state"
set_carriers 1 0 0 0 0

# Refuse to drive LEDs when the competing kernel owner cannot be disabled.
# Use a regular LED sink so a broken implementation cannot block on a FIFO.
printf 'untouched\n' > "$tmp_dir/rejected-led"
if run_controller \
	RG_MA2820_ENET_CONTROL="$tmp_dir/missing-enet-control" \
	RG_MA2820_LED_PROC="$tmp_dir/rejected-led" > "$tmp_dir/rejected-log" 2>&1; then
	echo 'LED controller accepted a missing Ethernet ownership control' >&2
	exit 1
fi
[ "$(cat "$tmp_dir/rejected-led")" = untouched ] || {
	echo 'LED controller wrote an LED after failing to claim Ethernet ownership' >&2
	exit 1
}
[ ! -e "$tmp_dir/missing-enet-control" ] || {
	echo 'LED controller created a file instead of requiring the kernel control' >&2
	exit 1
}

# A writable directory passes -w but rejects the actual proc-style write.
# This covers write failure even when the tests run as root.
mkdir "$tmp_dir/reject-enet-write"
if run_controller \
	RG_MA2820_ENET_CONTROL="$tmp_dir/reject-enet-write" \
	RG_MA2820_LED_PROC="$tmp_dir/rejected-led" > "$tmp_dir/rejected-log" 2>&1; then
	echo 'LED controller ignored a rejected Ethernet ownership write' >&2
	exit 1
fi
[ "$(cat "$tmp_dir/rejected-led")" = untouched ] || {
	echo 'LED controller wrote an LED after the ownership write was rejected' >&2
	exit 1
}

# A FIFO checks bytes but cannot expose one proc command split across writes.
# Exercise the shipped ARM printf and musl, under the same unbuffered stdout
# preload that procd injects, and verify the actual write syscall boundaries.
target_root=${RG_MA2820_TEST_TARGET_ROOT:-$project_dir/openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755}
if command -v qemu-arm >/dev/null && command -v cc >/dev/null &&
	[ -x "$target_root/bin/busybox" ] && [ -f "$target_root/lib/libsetlbf.so" ]; then
	cat > "$tmp_dir/setlbf.c" <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void unbuffer_stdout(void)
{
	setbuf(stdout, NULL);
}
EOF
	cc -shared -fPIC -o "$tmp_dir/libsetlbf.so" "$tmp_dir/setlbf.c"
	cat > "$tmp_dir/bin/target-printf" <<'EOF'
#!/bin/sh
# Translate the native test preload to the target preload only if the caller
# has not cleared it. This reproduces procd inheritance inside target musl.
target_preload=
[ -z "${LD_PRELOAD:-}" ] || target_preload=/lib/libsetlbf.so
exec "$RG_MA2820_TEST_QEMU" -L "$RG_MA2820_TEST_TARGET_ROOT" \
	-E "LD_PRELOAD=$target_preload" -strace \
	"$RG_MA2820_TEST_TARGET_ROOT/bin/busybox" printf "$@" \
	2>> "$RG_MA2820_TEST_SYSCALL_LOG"
EOF
	chmod +x "$tmp_dir/bin/target-printf"
	run_case procd-unbuffered 34 '1601150014001300120030014011201301' \
		LD_PRELOAD="$tmp_dir/libsetlbf.so" \
		RG_MA2820_PROC_PRINTF="$tmp_dir/bin/target-printf" \
		RG_MA2820_TEST_QEMU="$(command -v qemu-arm)" \
		RG_MA2820_TEST_TARGET_ROOT="$target_root" \
		RG_MA2820_TEST_SYSCALL_LOG="$tmp_dir/syscalls.log"
	write_sizes=$(sed -nE 's/^[0-9]+ write(v)?\(1,.* = ([0-9]+)$/\2/p' "$tmp_dir/syscalls.log" | paste -sd, -)
	[ "$write_sizes" = '15,4,4,4,4,4,3,4,4,3' ] || {
		echo "Proc commands fragmented or missing under procd preload: $write_sizes" >&2
		exit 1
	}
	echo 'Target ARM proc-write syscall boundaries under procd preload: PASS'
else
	echo 'Target ARM proc-write syscall test: SKIP (requires qemu-arm, cc and built target root)'
fi

# Exercise Wi-Fi/peer activity independently of the Ethernet controller.
awk '/^\[ -r "\$WIFI_ENV" \] && \. "\$WIFI_ENV"$/ { exit } { print }' \
    "$project_dir/persistent-overlay/usr/libexec/rg-ma2820/led-loop" > "$tmp_dir/led-functions.sh"
cat > "$tmp_dir/bin/record-printf" <<'EOF'
#!/bin/sh
printf "$@" >> "$ACTIVITY_TRACE"
EOF
cat > "$tmp_dir/bin/traffic-child" <<'EOF'
#!/bin/sh
[ "$1" = direction ] || exit 1
exec sleep 5
EOF
chmod +x "$tmp_dir/bin/record-printf" "$tmp_dir/bin/traffic-child"
(
    . "$tmp_dir/led-functions.sh"
    LED_PROC="$tmp_dir/activity-led"
    NET_DEV="$tmp_dir/net-dev"
    NET_CLASS="$tmp_dir/net"
    PROC_PRINTF="$tmp_dir/bin/record-printf"
    TRAFFIC_HELPER="$tmp_dir/bin/traffic-child"
    WAN_COLOR_MODE=direction
    export ACTIVITY_TRACE="$tmp_dir/activity-trace"
    PULSE_SLEEP=record_pulse
    : > "$LED_PROC"
    : > "$ACTIVITY_TRACE"
    record_pulse() {
        [ "$*" = '-e sleep(100);' ]
        printf '<peer-pulse>' >> "$ACTIVITY_TRACE"
    }
    assert_activity() {
        local actual
        actual=$(cat "$ACTIVITY_TRACE")
        [ "$actual" = "$2" ] || {
            echo "$1: $actual (expected $2)" >&2; exit 1;
        }
        : > "$ACTIVITY_TRACE"
    }
    wifi_stats() {
        printf 'wl1.1: %s 0 0 0 0 0 0 0 50 0 0 0 0 0 0 0\n' "$1" > "$NET_DEV"
        printf 'eth0: 999999 999999 0 0 0 0 0 0 999999 999999 0 0 0 0 0 0\n' >> "$NET_DEV"
    }
    power_status=normal uplink_status=online wifi_status=ready mesh_status=ready phase=0
    set_carriers 1 0 0 0 0
    read_port_links; update_port_status; apply_pattern
    : > "$ACTIVITY_TRACE"
    # The child owns Ethernet: even forced shell-cache invalidation cannot
    # clobber its direction color or blink edges.
    traffic_running=1 last_wan_red= last_wan_green= last_lan=
    apply_pattern
    assert_activity child-exclusive-ethernet ''
    wifi_stats 100
    update_activity; apply_pattern
    assert_activity baseline ''
    wifi_stats 101
    update_activity; apply_pattern
    assert_activity secondary-bss-activity '1204'
    update_activity; apply_pattern
    assert_activity stop-wifi-activity '1201'
    wifi_stats 0
    update_activity; apply_pattern
    assert_activity counter-reset ''
    NET_DEV="$tmp_dir/missing-net-dev"
    update_activity; apply_pattern
    assert_activity missing-statistics ''
    NET_DEV="$tmp_dir/net-dev"

    peer_activity=1
    pulse_peer_activity
    assert_activity actual-peer-probe '300<peer-pulse>301'
    pulse_peer_activity
    assert_activity no-unconditional-peer-heartbeat ''

    ONESHOT=0
    traffic_running=0
    ensure_traffic
    original_pid=$traffic_pid
    kill -0 "$original_pid"
    [ "$traffic_running" = 1 ]
    ensure_traffic
    [ "$traffic_pid" = "$original_pid" ]
    kill "$original_pid"
    wait "$original_pid" 2>/dev/null || true
    ensure_traffic 2> "$tmp_dir/restart-log"
    [ "$traffic_pid" != "$original_pid" ]
    kill -0 "$traffic_pid"
    grep -q restarting "$tmp_dir/restart-log"
    stop_traffic
    [ -z "$traffic_pid" ] && [ "$traffic_running" = 0 ]
    all_off
    assert_activity shutdown '15001400130012003001600'
)
echo 'LED ownership, physical-port health, Wi-Fi/peer activity, child lifecycle and state export: PASS'
