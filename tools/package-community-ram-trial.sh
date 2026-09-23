#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Private, flash-preserving hardware trial of a generic community system root.

set -euo pipefail
umask 077

usage() {
	echo "usage: $0 SYSTEM_SQUASHFS FACTORY_CALIBRATION VMLINUX_LZ DTB PRIVATE_OUTPUT_DIR" >&2
	exit 2
}

[ "$#" -eq 5 ] || usage
system_image=$(realpath "$1")
calibration=$(realpath "$2")
kernel=$(realpath "$3")
dtb=$(realpath "$4")
output=$(realpath -m "$5")
project_dir=$(cd "$(dirname "$0")/.." && pwd)
source_date_epoch=${SOURCE_DATE_EPOCH:-0}

fail() {
	echo "community RAM trial: $*" >&2
	exit 1
}

for input in "$system_image" "$calibration" "$kernel" "$dtb"; do
	[ -f "$input" ] && [ -s "$input" ] || fail "missing input: $input"
done
[[ $source_date_epoch =~ ^[0-9]+$ ]] || fail 'invalid SOURCE_DATE_EPOCH'
[ ! -e "$output" ] || fail "refusing to overwrite: $output"
case "$output/" in
	"$project_dir/"*) fail 'output must be outside the public source tree' ;;
esac
command -v unsquashfs >/dev/null || fail 'unsquashfs is required'
command -v fdtget >/dev/null || fail 'fdtget is required'
command -v cpio >/dev/null || fail 'cpio is required'

bootargs=$(fdtget -t s "$dtb" /chosen bootargs) || fail 'DTB has no bootargs'
case " $bootargs " in
	*'ubi.mtd='*|*'ubi.block='*|*'root=/dev/'*)
		fail 'DTB requests NAND/UBI root; RAM trial requires an initramfs-only boot' ;;
esac

temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-community-ram.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
stage=$temporary/output
mkdir -p "$stage"
unsquashfs -no-progress -d "$root" "$system_image" >/dev/null

device=$root/etc/rg-ma2820/device.env
provision=$root/etc/init.d/rg-ma2820-provision
layout=$root/etc/init.d/rg-ma2820-network-layout
[ -x "$root/sbin/init" ] || fail 'system image has no OpenWrt init'
grep -Fqx 'export INITRAMFS=1' "$root/init" || fail 'system image has no initramfs boot path'
grep -qx "DEVICE_ID='auto'" "$device" || fail 'system image is not generic'
grep -qx "SYSTEM_FORMAT='3'" "$device" || fail 'unexpected system format'
[ ! -e "$root/etc/rg-ma2820/kernel_nvram.setting" ] ||
	fail 'system image already embeds calibration'
[ -d "$root/lib/modules/4.1.52" ] || fail 'stock 4.1.52 modules are missing'
grep -Fqx 'DATA_SOURCE=${RG_MA2820_DATA_SOURCE:-}' "$provision" ||
	fail 'unexpected factory-data provisioner'
grep -Fqx 'ROM_ROOT=${RG_MA2820_ROM_ROOT:-/rom}' "$layout" ||
	fail 'unexpected overlay migration service'
for service in S07rg-ma2820-provision S24rg-ma2820-reset-watch \
	S99rg-ma2820-boot-success; do
	[ -L "$root/etc/rc.d/$service" ] || fail "missing $service"
done

size=$(wc -c < "$calibration")
[ "$size" -ge 4096 ] && [ "$size" -le 65536 ] ||
	fail "invalid calibration size: $size"
grep -qx 'boardnum=6755' "$calibration" || fail 'unexpected calibration board number'
grep -qx 'boardtype=0x08a9' "$calibration" || fail 'unexpected calibration board type'

# Keep the factory MTD untouched during this partial trial. The real generic
# first boot still imports this file from the separate on-device data MTD.
install -D -m 0600 "$calibration" \
	"$root/etc/rg-ma2820/kernel_nvram.setting"
sed -i '/^DATA_SOURCE=/a DATA_SOURCE=/etc/rg-ma2820/kernel_nvram.setting' \
	"$provision"

# Initramfs skips mount_root, so /rom is not a separate immutable mount. The
# release files live directly in the RAM root for this trial only.
sed -i '/^ROM_ROOT=/c\ROM_ROOT=/' "$layout"

# Neither A/B boot acceptance nor the physical Reset watcher should run from
# a RAM experiment. Removing these boot symlinks does not remove the tools.
unlink "$root/etc/rc.d/S99rg-ma2820-boot-success"
unlink "$root/etc/rc.d/S24rg-ma2820-reset-watch"
printf 'RAM-only partial trial; do not publish or flash this private bundle.\n' \
	> "$root/etc/rg-ma2820/ram-trial"

find "$root" -exec touch -h --date="@$source_date_epoch" -- {} +
(
	cd "$root"
	find . -print0 | LC_ALL=C sort -z |
		cpio --null --quiet --create --format=newc \
			--owner=0:0 --reproducible | gzip -9n > "$stage/initramfs.cpio.gz"
)
gzip -t "$stage/initramfs.cpio.gz"
cp "$kernel" "$stage/vmlinux.lz"
cp "$dtb" "$stage/947622.dtb"
(
	cd "$stage"
	sha256sum vmlinux.lz 947622.dtb initramfs.cpio.gz > SHA256SUMS
)
mkdir -p "$(dirname "$output")"
mv "$stage" "$output"
echo "private RAM-only AP trial bundle: $output"
echo 'Power cycling returns to the installed firmware; this does not test web flashing or persistent rollback.'
