#!/usr/bin/env bash
# Unit-test the weak-signal counters, BTM request and hard fallback.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-roam-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

mkdir -p "$temporary/bin" "$temporary/ctrl" "$temporary/state"
touch "$temporary/ctrl/wl1" "$temporary/ctrl/wl1.1"

cat > "$temporary/wifi.env" <<'EOF'
WIFI_PROFILE='wired-mesh'
ROAM_STEERING='1'
ROAM_INTERVAL='2'
ROAM_RSSI_TRIGGER='-72'
ROAM_RSSI_HARD='-82'
ROAM_RSSI_SAMPLES='3'
ROAM_COOLDOWN='60'
ROAM_MIN_ASSOC_AGE='15'
ROAM_HARD_FALLBACK='1'
ROAM_HARD_DELAY='12'
ROAM_HARD_WINDOW='45'
EOF
cat > "$temporary/device.env" <<'EOF'
PEER_LINK_LOCAL='169.254.20.3'
EOF
cat > "$temporary/peer.state" <<'EOF'
FORMAT=1
PROFILE=wired-mesh
BSSID_5G=02:00:00:00:03:50
EOF
printf '%s\n' -77 > "$temporary/rssi"
printf '%s\n' 1 > "$temporary/ping-ok"

cat > "$temporary/bin/wl" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_CALLS"
interface=$2
command=$3
case "$interface:$command" in
	wl1:assoclist) echo 'assoclist AA:BB:CC:DD:EE:FF' ;;
	wl1.1:assoclist) ;;
	wl1:rssi) cat "$TEST_RSSI" ;;
	wl1:sta_info)
		cat <<'INFO'
	 in network 120 seconds
	 auth: WPA3-SAE
	wnm
0x1:  BSS-Transition
RRM capability = 0x1 Neighbor_Report
INFO
		;;
esac
EOF
cat > "$temporary/bin/hostapd_cli" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_ACTIONS"
echo OK
EOF
cat > "$temporary/bin/ping" <<'EOF'
#!/bin/sh
[ "$(cat "$TEST_PING_OK")" = 1 ]
EOF
chmod +x "$temporary/bin/"*

export TEST_CALLS="$temporary/calls"
export TEST_ACTIONS="$temporary/actions"
export TEST_RSSI="$temporary/rssi"
export TEST_PING_OK="$temporary/ping-ok"
export RG_MA2820_WIFI_ENV="$temporary/wifi.env"
export RG_MA2820_DEVICE_ENV="$temporary/device.env"
export RG_MA2820_PEER_WIFI_STATE="$temporary/peer.state"
export RG_MA2820_ROAM_STATE_DIR="$temporary/state"
export RG_MA2820_ROAM_EVENTS="$temporary/events"
export RG_MA2820_WL="$temporary/bin/wl"
export RG_MA2820_HOSTAPD_CLI="$temporary/bin/hostapd_cli"
export RG_MA2820_HOSTAPD_CTRL="$temporary/ctrl"
export RG_MA2820_PING="$temporary/bin/ping"

steering="$project_dir/persistent-overlay/usr/libexec/rg-ma2820/roaming-steer"
: > "$TEST_ACTIONS"
sh "$steering" --once
sh "$steering" --once
[ ! -s "$TEST_ACTIONS" ]
sh "$steering" --once
grep -q 'bss_tm_req aa:bb:cc:dd:ee:ff pref=1 abridged=1 valid_int=10' "$TEST_ACTIONS"
grep -q 'soft interface=wl1 sta=aa:bb:cc:dd:ee:ff rssi=-77 btm=1' "$temporary/events"
! grep -q -- '-i wl0' "$TEST_CALLS"

# A very weak station that ignored the soft request gets the standards-based
# disassociation-imminent BTM request after the grace period.
printf '%s\n' -85 > "$temporary/rssi"
printf '%s\n' "$(( $(date +%s) - 20 ))" > "$temporary/state/wl1_aabbccddeeff.soft"
sh "$steering" --once
grep -q 'disassoc_imminent=1 disassoc_timer=100' "$TEST_ACTIONS"
grep -q 'hard interface=wl1 sta=aa:bb:cc:dd:ee:ff rssi=-85 btm=1' "$temporary/events"

# An unavailable wired peer suppresses both automatic and manual steering.
printf '%s\n' 0 > "$temporary/ping-ok"
before=$(wc -l < "$TEST_ACTIONS")
if sh "$steering" --steer wl1 aa:bb:cc:dd:ee:ff; then
	echo 'manual steer unexpectedly succeeded with peer offline' >&2
	exit 1
fi
[ "$(wc -l < "$TEST_ACTIONS")" = "$before" ]

# Community steering needs a recently installed authenticated neighbor, not
# just an unauthenticated mDNS service that happens to claim cluster membership.
cat > "$temporary/cluster.env" <<'EOF'
CLUSTER_ENABLED='1'
CLUSTER_ID='0123456789abcdef'
EOF
export RG_MA2820_CLUSTER_ENV="$temporary/cluster.env"
export RG_MA2820_CLUSTER_NEIGHBORS="$temporary/cluster-neighbors.state"
if sh "$steering" --steer wl1 aa:bb:cc:dd:ee:ff; then
	echo 'community steering unexpectedly accepted absent authenticated neighbors' >&2
	exit 1
fi
printf '%s\n' 'ffffffffffffffff' > "$RG_MA2820_CLUSTER_NEIGHBORS"
if sh "$steering" --steer wl1 aa:bb:cc:dd:ee:ff; then
	echo 'community steering unexpectedly accepted the wrong cluster' >&2
	exit 1
fi
printf '%s\n' '0123456789abcdef' > "$RG_MA2820_CLUSTER_NEIGHBORS"
touch -d '2 minutes ago' "$RG_MA2820_CLUSTER_NEIGHBORS"
if sh "$steering" --steer wl1 aa:bb:cc:dd:ee:ff; then
	echo 'community steering unexpectedly accepted expired neighbor state' >&2
	exit 1
fi
touch "$RG_MA2820_CLUSTER_NEIGHBORS"
sh "$steering" --steer wl1 aa:bb:cc:dd:ee:ff
grep -q 'manual interface=wl1 sta=aa:bb:cc:dd:ee:ff' "$temporary/events"

echo 'active roaming steering tests: PASS'
