#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build one calibration-free image for any compatible RG-MA2820(T).

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage: build-community-release.sh VERSION OUTPUT_DIR RUNTIME_ROOT VENDOR_ROOT STOCK_VOLUME_DIR

VENDOR_ROOT and STOCK_VOLUME_DIR must come from a stock RG-MA2820(T) image
owned by the builder. The output is generic: calibration, MAC addresses and
SSH host keys are read/generated independently on each AP at first boot.
EOF
	exit 2
}

[ "$#" -eq 5 ] || usage
version=$1
output_dir=$(realpath -m "$2")
runtime_root=$(realpath "$3")
vendor_root=$(realpath "$4")
stock_volume_dir=$(realpath "$5")
project_dir=$(cd "$(dirname "$0")/.." && pwd)
ubinize=${UBINIZE:-$project_dir/openwrt/staging_dir/host/bin/ubinize}

[[ $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || usage
[ ! -e "$output_dir" ] || {
	echo "refusing to reuse output directory: $output_dir" >&2
	exit 1
}

one_volume() {
	local pattern=$1 label=$2 matches=()
	shopt -s nullglob
	matches=("$stock_volume_dir"/$pattern)
	shopt -u nullglob
	[ "${#matches[@]}" -eq 1 ] || {
		echo "expected exactly one $label matching $pattern in $stock_volume_dir" >&2
		exit 2
	}
	printf '%s\n' "${matches[0]}"
}

metadata=$(one_volume 'img-*_vol-METADATA.ubifs' METADATA)
metadata_copy=$(one_volume 'img-*_vol-METADATACOPY.ubifs' METADATACOPY)
filestruct=$(one_volume 'img-*_vol-filestruct_full.bin.ubifs' filestruct)
filestruct_size=$(stat -c %s "$filestruct")
[ "$filestruct_size" -le $((24 * 126976)) ] || {
	echo "stock filestruct ($filestruct_size bytes) exceeds the verified 24-LEB kernel allocation" >&2
	echo 'use a matching RG-MA2820(T) AP_RGOS 11.9(4) backup; do not change the flash layout to fit an unrelated kernel' >&2
	exit 1
}
for required in \
	"$runtime_root/sbin/init" \
	"$vendor_root/lib/modules/4.1.52/extra/wl.ko" \
	"$vendor_root/usr/sbin/hostapd" \
	"$metadata" "$metadata_copy" "$filestruct" "$ubinize"; do
	[ -e "$required" ] || {
		echo "missing build input: $required" >&2
		exit 1
	}
done

mkdir -p "$output_dir"
system_image=$output_dir/rg-ma2820t-community-$version-system.squashfs
recovery_image=$output_dir/rg-ma2820t-community-$version-recovery.squashfs
ubi_image=$output_dir/rg-ma2820t-community-$version.ubi
web_image=$output_dir/RG-MA2820T-OpenWrt-Community-$version-web.bin

RG_COMMUNITY_MODE=1 \
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0} \
RG_RELEASE_VERSION=$version \
	"$project_dir/tools/package-persistent-rootfs.sh" \
	"$runtime_root" "$vendor_root" /dev/null \
	"$system_image" "$recovery_image" \
	rg-ma2820-auto root RG-MA2820-Setup open \
	6 36 00:00:00:00:00:00 00:00:00:00:00:00 6 36

"$project_dir/tools/audit-community-images.sh" "$system_image" "$recovery_image"

python3 "$project_dir/tools/rg-ab-ubi-image.py" \
	--recovery "$recovery_image" \
	--system-a "$system_image" \
	--active a --metadata "$metadata" --metadata-copy "$metadata_copy" \
	--filestruct "$filestruct" --output "$ubi_image" --ubinize "$ubinize"

python3 "$project_dir/tools/rg-web-image.py" build \
	--ubi "$ubi_image" --output "$web_image" \
	--version "OpenWrt-$version" --release community-generic-ab \
	--description 'OpenWrt wired AP cluster with factory-data provisioning'

(
	cd "$output_dir"
	sha256sum ./* > SHA256SUMS
)

cat > "$output_dir/BUILD-INFO.txt" <<EOF
Model: RG-MA2820(T)
Release: $version
Compatibility: rg-ma2820t-community-v1
Initial install: RGOS web updater
Factory/data MTD: preserved and read-only
Embedded calibration: no
Embedded device MAC addresses: no
Embedded SSH host keys: no
Default login: root / root
Default WLAN: RG-MA2820-Setup (open)
Cluster size: dynamic N-node wired backhaul
EOF

echo "generic community release built in $output_dir"
echo "web image: $web_image"
