#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Build device-bound A/B images for a pair of RG-MA2820(T) access points.

set -euo pipefail

usage() {
	cat >&2 <<'EOF'
usage:
  build-pair-release.sh --check PROFILE AP2_STATE_ROOT AP3_STATE_ROOT
  build-pair-release.sh VERSION OUTPUT_DIR RUNTIME_ROOT VENDOR_ROOT \
      AP2_STATE_ROOT AP3_STATE_ROOT STOCK_VOLUME_DIR PROFILE

The state roots must contain etc/rg-ma2820/kernel_nvram.setting and unique
Dropbear RSA, ECDSA, and Ed25519 host keys. PROFILE follows
config/pair.example.env. No stock or per-device material is stored by Git.
EOF
	exit 2
}

project_dir=$(cd "$(dirname "$0")/.." && pwd)
profile_keys=(
	AP2_RESCUE_LINK_LOCAL AP3_RESCUE_LINK_LOCAL
	AP2_BSSID_2G AP2_BSSID_5G AP2_BSSID_5G_LEGACY
	AP3_BSSID_2G AP3_BSSID_5G AP3_BSSID_5G_LEGACY
	AP2_CHANNEL_2G AP2_CHANNEL_5G AP3_CHANNEL_2G AP3_CHANNEL_5G
	FACTORY_ROOT_PASSWORD FACTORY_SSID FACTORY_WIFI_SECRET COUNTRY_CODE
)

is_profile_key() {
	local wanted=$1 candidate
	for candidate in "${profile_keys[@]}"; do
		[ "$wanted" != "$candidate" ] || return 0
	done
	return 1
}

read_profile() {
	local profile=$1 line key value required
	[ -f "$profile" ] || { echo "profile is not a regular file: $profile" >&2; exit 2; }
	for required in "${profile_keys[@]}"; do unset "$required"; done
	while IFS= read -r line || [ -n "$line" ]; do
		[[ $line =~ ^[[:space:]]*$ ]] && continue
		[[ $line =~ ^[[:space:]]*# ]] && continue
		[[ $line =~ ^([A-Z0-9_]+)=([A-Za-z0-9._:/+#=-]+)[[:space:]]*$ ]] || {
			echo "invalid profile line: $line" >&2
			exit 2
		}
		key=${BASH_REMATCH[1]}
		value=${BASH_REMATCH[2]}
		is_profile_key "$key" || { echo "unknown profile key: $key" >&2; exit 2; }
		[ -z "${!key+x}" ] || { echo "duplicate profile key: $key" >&2; exit 2; }
		printf -v "$key" '%s' "$value"
	done < "$profile"
	for required in "${profile_keys[@]}"; do
		[ -n "${!required:-}" ] || { echo "missing profile key: $required" >&2; exit 2; }
	done
}

valid_link_local() {
	local address=$1 third fourth
	[[ $address =~ ^169\.254\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	third=${BASH_REMATCH[1]}; fourth=${BASH_REMATCH[2]}
	(( third <= 255 && fourth >= 1 && fourth <= 254 ))
}

valid_mac() { [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; }

validate_profile() {
	local field value other
	valid_link_local "$AP2_RESCUE_LINK_LOCAL" && valid_link_local "$AP3_RESCUE_LINK_LOCAL" &&
		[ "$AP2_RESCUE_LINK_LOCAL" != "$AP3_RESCUE_LINK_LOCAL" ] || {
		echo 'rescue addresses must be distinct 169.254/16 host addresses' >&2
		exit 2
	}
	for field in AP2_BSSID_2G AP2_BSSID_5G AP2_BSSID_5G_LEGACY \
		AP3_BSSID_2G AP3_BSSID_5G AP3_BSSID_5G_LEGACY; do
		value=${!field}
		valid_mac "$value" || { echo "invalid MAC in $field: $value" >&2; exit 2; }
		printf -v "$field" '%s' "${value,,}"
	done
	for field in AP2_BSSID_2G AP2_BSSID_5G AP2_BSSID_5G_LEGACY \
		AP3_BSSID_2G AP3_BSSID_5G AP3_BSSID_5G_LEGACY; do
		for other in AP2_BSSID_2G AP2_BSSID_5G AP2_BSSID_5G_LEGACY \
			AP3_BSSID_2G AP3_BSSID_5G AP3_BSSID_5G_LEGACY; do
			[ "$field" = "$other" ] && continue
			[ "${!field}" != "${!other}" ] || {
				echo "duplicate radio identity in $field and $other" >&2
				exit 2
			}
		done
	done
	[[ $AP2_CHANNEL_2G =~ ^(1|6|11)$ && $AP3_CHANNEL_2G =~ ^(1|6|11)$ ]] || {
		echo '2.4 GHz fallback channels must be 1, 6, or 11' >&2; exit 2;
	}
	[[ $AP2_CHANNEL_5G =~ ^(36|40|44|48|149|153|157|161)$ &&
		$AP3_CHANNEL_5G =~ ^(36|40|44|48|149|153|157|161)$ ]] || {
		echo '5 GHz fallback channels must be non-DFS 36-48 or 149-161' >&2; exit 2;
	}
	[[ $FACTORY_ROOT_PASSWORD =~ ^[A-Za-z0-9]{4,63}$ ]] || {
		echo 'factory root password must be 4-63 ASCII letters or digits' >&2; exit 2;
	}
	[[ $FACTORY_SSID =~ ^[A-Za-z0-9._-]{1,32}$ ]] || {
		echo 'factory SSID contains unsupported characters' >&2; exit 2;
	}
	[ "$FACTORY_WIFI_SECRET" = open ] || [[ $FACTORY_WIFI_SECRET =~ ^[A-Za-z0-9]{8,63}$ ]] || {
		echo "factory Wi-Fi secret must be 'open' or 8-63 ASCII letters/digits" >&2; exit 2;
	}
	[[ $COUNTRY_CODE =~ ^([A-Za-z]{2}|#[ahru])$ ]] || {
		echo 'country code must be a two-letter driver country or a documented Broadcom pseudo-domain' >&2; exit 2;
	}
	[[ $COUNTRY_CODE = \#* ]] || COUNTRY_CODE=${COUNTRY_CODE^^}
}

validate_state_root() {
	local root=$1 hostkey
	[ -s "$root/etc/rg-ma2820/kernel_nvram.setting" ] || {
		echo "missing calibration NVRAM in $root" >&2; exit 2;
	}
	for hostkey in rsa ecdsa ed25519; do
		[ -s "$root/etc/dropbear/dropbear_${hostkey}_host_key" ] || {
			echo "missing Dropbear $hostkey host key in $root" >&2; exit 2;
		}
	done
}

[ "$#" -ge 1 ] || usage
if [ "$1" = --check ]; then
	[ "$#" -eq 4 ] || usage
	profile=$(realpath "$2")
	ap2_state_root=$(realpath "$3")
	ap3_state_root=$(realpath "$4")
	read_profile "$profile"
	validate_profile
	validate_state_root "$ap2_state_root"
	validate_state_root "$ap3_state_root"
	ap2_public=$(python3 "$project_dir/tools/dropbear-ed25519-public.py" --blob \
		"$ap2_state_root/etc/dropbear/dropbear_ed25519_host_key")
	ap3_public=$(python3 "$project_dir/tools/dropbear-ed25519-public.py" --blob \
		"$ap3_state_root/etc/dropbear/dropbear_ed25519_host_key")
	[ "$ap2_public" != "$ap3_public" ] || { echo 'the AP host keys must be unique' >&2; exit 2; }
	echo 'pair profile: PASS'
	python3 "$project_dir/tools/dropbear-ed25519-public.py" --fingerprint \
		"$ap2_state_root/etc/dropbear/dropbear_ed25519_host_key" | sed 's/^/AP2 /'
	python3 "$project_dir/tools/dropbear-ed25519-public.py" --fingerprint \
		"$ap3_state_root/etc/dropbear/dropbear_ed25519_host_key" | sed 's/^/AP3 /'
	exit 0
fi

[ "$#" -eq 8 ] || usage
version=$1
output_dir=$(realpath -m "$2")
runtime_root=$(realpath "$3")
vendor_root=$(realpath "$4")
ap2_state_root=$(realpath "$5")
ap3_state_root=$(realpath "$6")
stock_volume_dir=$(realpath "$7")
profile=$(realpath "$8")
[[ $version =~ ^r[0-9]+$ ]] || usage
[ ! -e "$output_dir" ] || { echo "refusing to reuse output directory: $output_dir" >&2; exit 1; }

read_profile "$profile"
validate_profile
validate_state_root "$ap2_state_root"
validate_state_root "$ap3_state_root"
ap2_public=$(python3 "$project_dir/tools/dropbear-ed25519-public.py" --blob \
	"$ap2_state_root/etc/dropbear/dropbear_ed25519_host_key")
ap3_public=$(python3 "$project_dir/tools/dropbear-ed25519-public.py" --blob \
	"$ap3_state_root/etc/dropbear/dropbear_ed25519_host_key")
[ "$ap2_public" != "$ap3_public" ] || { echo 'the AP host keys must be unique' >&2; exit 2; }

one_volume() {
	local pattern=$1 label=$2 matches=()
	shopt -s nullglob
	matches=("$stock_volume_dir"/$pattern)
	shopt -u nullglob
	[ "${#matches[@]}" -eq 1 ] || {
		echo "expected exactly one $label file matching $pattern in $stock_volume_dir" >&2
		exit 2
	}
	printf '%s\n' "${matches[0]}"
}

metadata=$(one_volume 'img-*_vol-METADATA.ubifs' METADATA)
metadata_copy=$(one_volume 'img-*_vol-METADATACOPY.ubifs' METADATACOPY)
filestruct=$(one_volume 'img-*_vol-filestruct_full.bin.ubifs' filestruct)
ubinize=$project_dir/openwrt/staging_dir/host/bin/ubinize
for required in "$runtime_root/sbin/init" "$vendor_root/lib/modules/4.1.52" \
	"$metadata" "$metadata_copy" "$filestruct" "$ubinize"; do
	[ -e "$required" ] || { echo "missing build input: $required" >&2; exit 1; }
done

mkdir -p "$output_dir"

build_device() {
	local device=$1 state_root=$2 rescue=$3 peer_rescue=$4
	local bssid_2g=$5 bssid_5g=$6 bssid_legacy=$7
	local peer_2g=$8 peer_5g=$9 peer_legacy=${10}
	local channel_2g=${11} channel_5g=${12} peer_channel_2g=${13} peer_channel_5g=${14}
	local device_dir=$output_dir/$device upper
	upper=${device^^}
	mkdir -p "$device_dir"
	DROPBEAR_HOSTKEY_DIR="$state_root/etc/dropbear" \
	SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0} \
	RG_RELEASE_VERSION=$version \
	RG_RESCUE_LINK_LOCAL=$rescue RG_PEER_LINK_LOCAL=$peer_rescue \
	RG_LOCAL_BSSID_2G=$bssid_2g RG_LOCAL_BSSID_5G=$bssid_5g \
	RG_LOCAL_BSSID_5G_LEGACY=$bssid_legacy RG_PEER_BSSID_5G_LEGACY=$peer_legacy \
	RG_AP2_ED25519_PUBLIC=$ap2_public RG_AP3_ED25519_PUBLIC=$ap3_public \
	RG_COUNTRY_CODE=$COUNTRY_CODE \
		"$project_dir/tools/package-persistent-rootfs.sh" \
		"$runtime_root" "$vendor_root" \
		"$state_root/etc/rg-ma2820/kernel_nvram.setting" \
		"$device_dir/rg-ma2820t-$device-$version-system.squashfs" \
		"$device_dir/rg-ma2820t-$device-$version-recovery.squashfs" \
		"rg-ma2820-$device" "$FACTORY_ROOT_PASSWORD" "$FACTORY_SSID" \
		"$FACTORY_WIFI_SECRET" "$channel_2g" "$channel_5g" \
		"$peer_2g" "$peer_5g" "$peer_channel_2g" "$peer_channel_5g"

	python3 "$project_dir/tools/rg-ab-ubi-image.py" \
		--recovery "$device_dir/rg-ma2820t-$device-$version-recovery.squashfs" \
		--system-a "$device_dir/rg-ma2820t-$device-$version-system.squashfs" \
		--active a --metadata "$metadata" --metadata-copy "$metadata_copy" \
		--filestruct "$filestruct" \
		--output "$device_dir/rg-ma2820t-$device-$version.ubi" \
		--ubinize "$ubinize"
	python3 "$project_dir/tools/rg-web-image.py" build \
		--ubi "$device_dir/rg-ma2820t-$device-$version.ubi" \
		--output "$device_dir/RG-MA2820T-$upper-OpenWrt-$version-web.bin" \
		--version "OpenWrt-$version" --release community-recovery-ab
}

build_device ap2 "$ap2_state_root" "$AP2_RESCUE_LINK_LOCAL" "$AP3_RESCUE_LINK_LOCAL" \
	"$AP2_BSSID_2G" "$AP2_BSSID_5G" "$AP2_BSSID_5G_LEGACY" \
	"$AP3_BSSID_2G" "$AP3_BSSID_5G" "$AP3_BSSID_5G_LEGACY" \
	"$AP2_CHANNEL_2G" "$AP2_CHANNEL_5G" "$AP3_CHANNEL_2G" "$AP3_CHANNEL_5G"
build_device ap3 "$ap3_state_root" "$AP3_RESCUE_LINK_LOCAL" "$AP2_RESCUE_LINK_LOCAL" \
	"$AP3_BSSID_2G" "$AP3_BSSID_5G" "$AP3_BSSID_5G_LEGACY" \
	"$AP2_BSSID_2G" "$AP2_BSSID_5G" "$AP2_BSSID_5G_LEGACY" \
	"$AP3_CHANNEL_2G" "$AP3_CHANNEL_5G" "$AP2_CHANNEL_2G" "$AP2_CHANNEL_5G"

(
	cd "$output_dir"
	sha256sum ap2/* ap3/* > SHA256SUMS
)
echo "community release built in $output_dir"
