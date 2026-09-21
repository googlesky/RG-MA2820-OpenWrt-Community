#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# One-command owner-side build from a matching stock firmware or UBI backup.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: build-community-from-stock.sh VERSION OUTPUT_DIR STOCK_IMAGE [RUNTIME_ROOT]

If RUNTIME_ROOT is omitted, the pinned OpenWrt submodule is configured and
built first. Set UBIREADER_EXTRACT_IMAGES or place ubireader_extract_images in
PATH. STOCK_IMAGE is a matching RGOS WFI/EWEB image or the owner's raw UBI
rootfs MTD backup. Extracted stock files stay in a temporary directory.
EOF
	exit 2
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
version=$1
output_dir=$(realpath -m "$2")
stock_image=$(realpath "$3")
project_dir=$(cd "$(dirname "$0")/.." && pwd)
runtime_root=${4:-$project_dir/openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755}
runtime_root=$(realpath -m "$runtime_root")
extract_images=${UBIREADER_EXTRACT_IMAGES:-$(command -v ubireader_extract_images || true)}

[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || usage
[ -f "$stock_image" ] || {
	echo "stock image is not a regular file: $stock_image" >&2
	exit 2
}
[ -n "$extract_images" ] && [ -x "$extract_images" ] || {
	echo 'ubireader_extract_images is required (Python package ubi-reader)' >&2
	exit 1
}
command -v unsquashfs >/dev/null || {
	echo 'unsquashfs is required (package squashfs-tools)' >&2
	exit 1
}

if [ ! -x "$runtime_root/sbin/init" ]; then
	echo 'Building the pinned OpenWrt userspace; this can take a while.'
	git -C "$project_dir" submodule update --init --recursive
	"$project_dir/tools/apply-openwrt-overlay.sh"
	(
		cd "$project_dir/openwrt"
		./scripts/feeds update -a
		./scripts/feeds install -a
		make defconfig
		make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
	)
fi
[ -x "$runtime_root/sbin/init" ] || {
	echo "OpenWrt runtime build did not produce $runtime_root" >&2
	exit 1
}

temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-community-build.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

stock_magic=$(od -An -tx1 -N4 "$stock_image" | tr -d '[:space:]')
if [ "$stock_magic" = 55424923 ]; then
	[ "$(($(stat -c %s "$stock_image") % 131072))" -eq 0 ] || {
		echo 'raw stock UBI backup is not aligned to a 128 KiB eraseblock' >&2
		exit 1
	}
	stock_ubi=$stock_image
else
	python3 "$project_dir/tools/rg-web-image.py" extract "$stock_image" \
		--ubi-output "$temporary/stock.ubi"
	stock_ubi=$temporary/stock.ubi
fi
"$extract_images" -o "$temporary/volumes" "$stock_ubi"

rootfs_image=$(find "$temporary/volumes" -type f \
	-name 'img-*_vol-rootfs_ubifs.ubifs' -print)
[ "$(printf '%s\n' "$rootfs_image" | sed '/^$/d' | wc -l)" -eq 1 ] || {
	echo 'stock image did not contain exactly one rootfs_ubifs volume' >&2
	exit 1
}
mkdir -p "$temporary/vendor-root"
unsquashfs -no-progress -d "$temporary/vendor-root" "$rootfs_image" >/dev/null

volume_dir=${rootfs_image%/*}
shopt -s nullglob
filestruct_images=("$volume_dir"/img-*_vol-filestruct_full.bin.ubifs)
shopt -u nullglob
[ "${#filestruct_images[@]}" -eq 1 ] || {
	echo 'stock image does not contain exactly one filestruct volume' >&2
	exit 1
}
filestruct_size=$(stat -c %s "${filestruct_images[0]}")
if [ "$filestruct_size" -gt $((24 * 126976)) ]; then
	echo "stock filestruct ($filestruct_size bytes) exceeds the verified 24-LEB kernel allocation" >&2
	echo 'use a matching RG-MA2820(T) AP_RGOS 11.9(4) backup; do not mix RG-MA2820B R5.2.9 filestruct with this layout' >&2
	exit 1
fi
UBINIZE=${UBINIZE:-$project_dir/openwrt/staging_dir/host/bin/ubinize} \
	"$project_dir/tools/build-community-release.sh" \
	"$version" "$output_dir" "$runtime_root" \
	"$temporary/vendor-root" "$volume_dir"
