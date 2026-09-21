#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

[ "$#" -eq 2 ] || {
	echo "usage: $0 SYSTEM_SQUASHFS RECOVERY_SQUASHFS" >&2
	exit 2
}

system_image=$(realpath "$1")
recovery_image=$(realpath "$2")
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-community-audit.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

unsquashfs -no-progress -d "$temporary/system" "$system_image" >/dev/null
unsquashfs -no-progress -d "$temporary/recovery" "$recovery_image" >/dev/null

fail() {
	echo "community image audit: $*" >&2
	exit 1
}

for root in "$temporary/system" "$temporary/recovery"; do
	device=$root/etc/rg-ma2820/device.env
	grep -qx "DEVICE_ID='auto'" "$device" || fail 'generic device ID is missing'
	grep -qx "SYSTEM_FORMAT='3'" "$device" || fail 'community system format is missing'
	grep -qx "IMAGE_COMPAT='rg-ma2820t-community-v1'" "$device" ||
		fail 'compatibility class is missing'
	grep -qx "COMMUNITY_AUTOPROVISION='1'" "$device" ||
		fail 'automatic provisioning marker is missing'
	[ ! -e "$root/etc/rg-ma2820/kernel_nvram.setting" ] ||
		fail 'generic image contains device calibration'
	if find "$root/etc/dropbear" -type f -name 'dropbear_*_host_key' -print -quit |
		grep -q .; then
		fail 'generic image contains a Dropbear host key'
	fi
	[ ! -e "$root/etc/dropbear/authorized_keys" ] ||
		fail 'generic image contains a device authorization list'
	[ ! -e "$root/root/.ssh/known_hosts" ] ||
		fail 'generic image contains pinned device identities'
	expected_hash=$(openssl passwd -6 -salt rgma2820auto root)
	actual_hash=$(awk -F: '$1 == "root" { print $2; exit }' "$root/etc/shadow")
	[ "$actual_hash" = "$expected_hash" ] ||
		fail 'factory root credential is not root/root'
	grep -qx "WIFI_SECURITY='open'" "$root/etc/rg-ma2820/wifi.env" ||
		fail 'factory WLAN is not open'
	grep -qx "SSID_BASE='RG-MA2820-Setup'" "$root/etc/rg-ma2820/wifi.env" ||
		fail 'factory WLAN name is wrong'
	grep -R -n -E '@[A-Z0-9_]+@' "$root/etc/rg-ma2820" >/dev/null 2>&1 &&
		fail 'an unresolved packaging placeholder remains'
done

[ -L "$temporary/system/etc/rc.d/S07rg-ma2820-provision" ] ||
	fail 'system does not enable factory-data provisioning'
[ -L "$temporary/system/etc/rc.d/S85rg-ma2820-cluster-sync" ] ||
	fail 'system does not enable N-node synchronization'
[ ! -L "$temporary/system/etc/rc.d/S65rg-ma2820-neighbor-sync" ] ||
	fail 'system still enables pair-only neighbor synchronization'
[ -e "$temporary/recovery/etc/rg-ma2820/recovery-root" ] ||
	fail 'recovery marker is missing'
[ -L "$temporary/recovery/etc/rc.d/S07rg-ma2820-provision" ] ||
	fail 'recovery cannot derive its per-device management identity'
[ ! -L "$temporary/recovery/etc/rc.d/S60rg-ma2820-wifi" ] ||
	fail 'recovery unexpectedly starts the radios'
[ ! -L "$temporary/recovery/etc/rc.d/S85rg-ma2820-cluster-sync" ] ||
	fail 'recovery unexpectedly starts cluster synchronization'

echo 'generic identity, first-boot provisioning, defaults and recovery audit: PASS'
