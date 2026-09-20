#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

usage() {
	echo "usage: $0 ROOTFS VENDOR_ROOTFS OUTPUT IPADDR HOSTNAME WPA_PSK" >&2
	exit 2
}

[ "$#" -eq 6 ] || usage

rootfs=$(realpath "$1")
vendor_rootfs=$(realpath "$2")
output=$(realpath -m "$3")
ipaddr=$4
hostname=$5
wifi_psk=$6
source_date_epoch=${SOURCE_DATE_EPOCH:-0}

[[ $ipaddr =~ ^192\.168\.1\.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$ ]] || {
	echo "refusing unexpected recovery IP: $ipaddr" >&2
	exit 2
}
[[ $hostname =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || {
	echo "invalid hostname: $hostname" >&2
	exit 2
}
[[ $wifi_psk =~ ^[A-Za-z0-9]{16,63}$ ]] || {
	echo "WPA PSK must be 16-63 ASCII letters or digits" >&2
	exit 2
}
[[ $source_date_epoch =~ ^[0-9]+$ ]] || {
	echo "SOURCE_DATE_EPOCH must be an unsigned integer" >&2
	exit 2
}
[ -x "$rootfs/sbin/init" ] || {
	echo "OpenWrt rootfs has no executable /sbin/init: $rootfs" >&2
	exit 1
}
[ -d "$vendor_rootfs/lib/modules/4.1.52" ] || {
	echo "vendor 4.1.52 module tree not found: $vendor_rootfs" >&2
	exit 1
}

project_dir=$(cd "$(dirname "$0")/.." && pwd)
overlay="$project_dir/hybrid-overlay"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-hybrid.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

mkdir -p "$work_dir/rootfs" "$(dirname "$output")"
rsync -a "$rootfs/" "$work_dir/rootfs/"
rsync -a "$vendor_rootfs/lib/modules/4.1.52" \
	"$work_dir/rootfs/lib/modules/"
rsync -a "$overlay/" "$work_dir/rootfs/"
python3 "$project_dir/tools/copy-vendor-runtime.py" \
	--vendor-root "$vendor_rootfs" \
	--target-root "$work_dir/rootfs"

for utility in hostapd hostapd_cli nvram wl; do
	ln -s vendor-run "$work_dir/rootfs/opt/bcm/sbin/$utility"
done

defaults="$work_dir/rootfs/etc/uci-defaults/99-rg-ma2820-recovery"
sed -i \
	-e "s/@IPADDR@/$ipaddr/g" \
	-e "s/@HOSTNAME@/$hostname/g" \
	"$defaults"

ssid_base="OpenWrt-MA2820-$(tr '[:lower:]' '[:upper:]' <<< "${hostname##*-}")"
wifi_env="$work_dir/rootfs/etc/rg-ma2820/wifi.env"
sed -i \
	-e "s/@SSID_BASE@/$ssid_base/g" \
	-e "s/@WPA_PSK@/$wifi_psk/g" \
	"$wifi_env"

chmod 0755 \
	"$work_dir/rootfs/etc/init.d/bcm6755-vendor-drivers" \
	"$work_dir/rootfs/etc/init.d/rg-ma2820-wifi" \
	"$work_dir/rootfs/opt/bcm/sbin/vendor-run" \
	"$defaults"
chmod 0600 "$wifi_env"
ln -s ../init.d/bcm6755-vendor-drivers \
	"$work_dir/rootfs/etc/rc.d/S08bcm6755-vendor-drivers"
ln -s ../init.d/rg-ma2820-wifi \
	"$work_dir/rootfs/etc/rc.d/S60rg-ma2820-wifi"
if [ ! -e "$work_dir/rootfs/init" ] && [ ! -L "$work_dir/rootfs/init" ]; then
	ln -s sbin/init "$work_dir/rootfs/init"
fi

# Normalize mtimes as well as cpio metadata so identical inputs really do
# produce the same compressed ramdisk.
find "$work_dir/rootfs" -exec \
	touch -h --date="@$source_date_epoch" -- {} +

# Deterministic names, ownership, ordering and gzip header.  The vendor kernel
# recognizes an external newc initramfs through the DTB initrd-start/end fields.
(
	cd "$work_dir/rootfs"
	find . -print0 \
		| LC_ALL=C sort -z \
		| cpio --null --quiet --create --format=newc \
			--owner=0:0 --reproducible \
		| gzip -9n > "$output"
)

gzip -t "$output"
sha256sum "$output"
