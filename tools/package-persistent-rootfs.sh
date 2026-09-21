#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

usage() {
	echo "usage: $0 ROOTFS VENDOR_ROOTFS KERNEL_NVRAM SYSTEM_OUTPUT RECOVERY_OUTPUT HOSTNAME ROOT_PASSWORD ROAM_SSID WPA_PSK_OR_OPEN CHANNEL_2G CHANNEL_5G PEER_BSSID_2G PEER_BSSID_5G PEER_CHANNEL_2G PEER_CHANNEL_5G" >&2
	exit 2
}

[ "$#" -eq 15 ] || usage

rootfs=$(realpath "$1")
vendor_rootfs=$(realpath "$2")
kernel_nvram=$(realpath "$3")
system_output=$(realpath -m "$4")
recovery_output=$(realpath -m "$5")
hostname=$6
root_password=$7
roam_ssid=$8
wifi_secret=$9
channel_2g=${10}
channel_5g=${11}
peer_bssid_2g=${12}
peer_bssid_5g=${13}
peer_channel_2g=${14}
peer_channel_5g=${15}
source_date_epoch=${SOURCE_DATE_EPOCH:-0}
release_version=${RG_RELEASE_VERSION:-unknown}
community_mode=${RG_COMMUNITY_MODE:-0}
dropbear_hostkey_dir=${DROPBEAR_HOSTKEY_DIR:-}
rescue_link_local=${RG_RESCUE_LINK_LOCAL:-}
peer_link_local=${RG_PEER_LINK_LOCAL:-}
local_bssid_2g=${RG_LOCAL_BSSID_2G:-}
local_bssid_5g=${RG_LOCAL_BSSID_5G:-}
local_bssid_5g_legacy=${RG_LOCAL_BSSID_5G_LEGACY:-}
peer_bssid_5g_legacy=${RG_PEER_BSSID_5G_LEGACY:-}
ap2_public_key=${RG_AP2_ED25519_PUBLIC:-}
ap3_public_key=${RG_AP3_ED25519_PUBLIC:-}
country_code=${RG_COUNTRY_CODE:-}
# squashfs-tools also consumes SOURCE_DATE_EPOCH itself. The script passes
# explicit timestamps below, so remove the inherited copy to avoid ambiguity.
unset SOURCE_DATE_EPOCH

case "$community_mode" in 0|1) ;; *) echo 'RG_COMMUNITY_MODE must be 0 or 1' >&2; exit 2 ;; esac
if [ "$community_mode" = 1 ]; then
	[ "$hostname" = rg-ma2820-auto ] || {
		echo 'community hostname must be rg-ma2820-auto' >&2
		exit 2
	}
	device_id=auto
else
	[[ $hostname =~ ^rg-ma2820-ap(2|3)$ ]] || {
		echo "hostname must be rg-ma2820-ap2 or rg-ma2820-ap3" >&2
		exit 2
	}
	device_id=${hostname##*-}
fi
[[ $root_password =~ ^[A-Za-z0-9]{4,63}$ ]] || {
	echo "root password must be 4-63 ASCII letters or digits" >&2
	exit 2
}
[[ $roam_ssid =~ ^[A-Za-z0-9._-]{1,32}$ ]] || {
	echo "roaming SSID must be 1-32 ASCII letters, digits, dots, underscores, or dashes" >&2
	exit 2
}
if [ "$wifi_secret" = open ]; then
	wifi_security=open
	wpa_psk=
else
	[[ $wifi_secret =~ ^[A-Za-z0-9]{8,63}$ ]] || {
		echo "WPA2 passphrase must be 8-63 ASCII letters or digits, or use literal 'open'" >&2
		exit 2
	}
	wifi_security=wpa2
	wpa_psk=$wifi_secret
fi
[[ $source_date_epoch =~ ^[0-9]+$ ]] || {
	echo "SOURCE_DATE_EPOCH must be an unsigned integer" >&2
	exit 2
}
[[ $release_version =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || {
	echo "RG_RELEASE_VERSION must be a short filesystem-safe version" >&2
	exit 2
}
if [ "$community_mode" != 1 ]; then
	[[ $channel_2g =~ ^(1|6|11)$ && $peer_channel_2g =~ ^(1|6|11)$ ]] || {
		echo "2.4 GHz channels must be 1, 6, or 11" >&2
		exit 2
	}
	[[ $channel_5g =~ ^(36|40|44|48|149|153|157|161)$ && \
		$peer_channel_5g =~ ^(36|40|44|48|149|153|157|161)$ ]] || {
		echo "5 GHz channels must be non-DFS 36-48 or 149-161" >&2
		exit 2
	}
	[[ $peer_bssid_2g =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ && \
		$peer_bssid_5g =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || {
		echo "peer BSSIDs must use colon-separated hexadecimal notation" >&2
		exit 2
	}
case "$device_id" in
	ap2)
		peer_id=ap3; peer_hostname=rg-ma2820-ap3
		ap2_link_local=$rescue_link_local; ap3_link_local=$peer_link_local
		;;
	ap3)
		peer_id=ap2; peer_hostname=rg-ma2820-ap2
		ap2_link_local=$peer_link_local; ap3_link_local=$rescue_link_local
		;;
esac
peer_bssid_2g_device=${peer_bssid_2g,,}
peer_bssid_5g_device=${peer_bssid_5g,,}
else
	rescue_link_local=169.254.254.1
	peer_link_local=
	peer_id=
	peer_hostname=
	local_bssid_2g=00:00:00:00:00:00
	local_bssid_5g=00:00:00:00:00:00
	local_bssid_5g_legacy=00:00:00:00:00:00
	peer_bssid_2g_device=00:00:00:00:00:00
	peer_bssid_5g_device=00:00:00:00:00:00
	peer_bssid_5g_legacy=00:00:00:00:00:00
	country_code=US
fi

valid_link_local() {
	local address=$1 third fourth
	[[ $address =~ ^169\.254\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	third=${BASH_REMATCH[1]}
	fourth=${BASH_REMATCH[2]}
	(( third <= 255 && fourth >= 1 && fourth <= 254 ))
}

valid_mac() {
	[[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

if [ "$community_mode" != 1 ]; then
valid_link_local "$rescue_link_local" &&
	valid_link_local "$peer_link_local" &&
	[ "$rescue_link_local" != "$peer_link_local" ] || {
	echo "RG_RESCUE_LINK_LOCAL and RG_PEER_LINK_LOCAL must be distinct 169.254/16 host addresses" >&2
	exit 2
}
for identity_mac in "$local_bssid_2g" "$local_bssid_5g" \
	"$local_bssid_5g_legacy" "$peer_bssid_5g_legacy"; do
	valid_mac "$identity_mac" || {
		echo "all RG_*_BSSID_* values must use colon-separated hexadecimal notation" >&2
		exit 2
	}
done
for public_key in "$ap2_public_key" "$ap3_public_key"; do
	[[ $public_key =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || {
		echo "RG_AP2_ED25519_PUBLIC and RG_AP3_ED25519_PUBLIC must be base64 OpenSSH key blobs" >&2
		exit 2
	}
done
[[ $country_code =~ ^([A-Za-z]{2}|#[ahru])$ ]] || {
	echo "RG_COUNTRY_CODE must be a two-letter driver country or a documented Broadcom pseudo-domain" >&2
	exit 2
}
[[ $country_code = \#* ]] || country_code=${country_code^^}
fi
[ "$system_output" != "$recovery_output" ] || {
	echo "system and recovery output paths must differ" >&2
	exit 2
}
for output in "$system_output" "$recovery_output"; do
	[ ! -e "$output" ] || {
		echo "refusing to overwrite existing output: $output" >&2
		exit 1
	}
done
if [ "$community_mode" != 1 ]; then
	[ -n "$dropbear_hostkey_dir" ] || {
		echo "DROPBEAR_HOSTKEY_DIR must name a directory with pre-generated per-device host keys" >&2
		exit 2
	}
	dropbear_hostkey_dir=$(realpath "$dropbear_hostkey_dir")
	for hostkey in rsa ecdsa ed25519; do
		[ -s "$dropbear_hostkey_dir/dropbear_${hostkey}_host_key" ] || {
			echo "missing Dropbear $hostkey host key in $dropbear_hostkey_dir" >&2
			exit 2
		}
	done
fi
for runtime_file in sbin/init sbin/rpcd usr/sbin/uhttpd www/cgi-bin/luci \
	usr/share/luci/menu.d/luci-mod-network.json \
	usr/share/rpcd/acl.d/luci-mod-network.json; do
	[ -e "$rootfs/$runtime_file" ] || {
		echo "OpenWrt runtime is incomplete (missing $runtime_file): $rootfs" >&2
		exit 1
	}
done
for vendor_file in lib/modules/4.1.52/extra/wl.ko usr/sbin/hostapd usr/sbin/wl; do
	[ -e "$vendor_rootfs/$vendor_file" ] || {
		echo "vendor runtime is incomplete (missing $vendor_file): $vendor_rootfs" >&2
		exit 1
	}
done
if [ "$community_mode" != 1 ]; then
	[ -s "$kernel_nvram" ] || {
		echo "backed-up kernel NVRAM file is missing or empty: $kernel_nvram" >&2
		exit 1
	}
fi

project_dir=$(cd "$(dirname "$0")/.." && pwd)
hybrid_overlay="$project_dir/hybrid-overlay"
persistent_overlay="$project_dir/persistent-overlay"
community_overlay="$project_dir/community-overlay"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-persistent.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
system_root="$work_dir/system"
recovery_root="$work_dir/recovery"

mkdir -p "$system_root/lib/modules" \
	"$(dirname "$system_output")" "$(dirname "$recovery_output")"
# Kernel packages in the OpenWrt staging root belong to the mainline 6.18
# diagnostic build. A persistent hybrid image boots the exact RGOS 4.1.52
# kernel, so copy only its matching, device-derived module tree.
rsync -a \
	--exclude='/lib/modules/' \
	--exclude='/etc/modules.d/' \
	--exclude='/etc/modules-boot.d/' \
	"$rootfs/" "$system_root/"
mkdir -p "$system_root/etc/modules.d" \
	"$system_root/etc/modules-boot.d"
rsync -a "$vendor_rootfs/lib/modules/4.1.52" \
	"$system_root/lib/modules/"
rsync -a "$hybrid_overlay/" "$system_root/"
rsync -a "$persistent_overlay/" "$system_root/"
if [ "$community_mode" = 1 ]; then
	[ -d "$community_overlay" ] || {
		echo "community overlay is missing: $community_overlay" >&2
		exit 1
	}
	rsync -a "$community_overlay/" "$system_root/"
fi
"$project_dir/tools/build-led-traffic.sh" \
	"$system_root/usr/libexec/rg-ma2820/led-traffic"
# The retained vendor kernel opens /data/.restoredefault_flag directly when
# Reset is held for five seconds. Keep the parent in the immutable lower root
# so the signal also works before the writable overlay has created anything.
mkdir -p "$system_root/data"
python3 "$project_dir/tools/copy-vendor-runtime.py" \
	--vendor-root "$vendor_rootfs" \
	--target-root "$system_root"

for utility in hostapd hostapd_cli nvram wl; do
	utility_path="$system_root/opt/bcm/sbin/$utility"
	if [ -e "$utility_path" ] || [ -L "$utility_path" ]; then
		[ -L "$utility_path" ] && [ "$(readlink "$utility_path")" = vendor-run ] || {
			echo "refusing to replace unexpected vendor utility: $utility_path" >&2
			exit 1
		}
	else
		ln -s vendor-run "$utility_path"
	fi
done

if [ "$community_mode" != 1 ]; then
	install -D -m 0600 "$kernel_nvram" \
		"$system_root/etc/rg-ma2820/kernel_nvram.setting"
else
	rm -f "$system_root/etc/rg-ma2820/kernel_nvram.setting"
fi
printf '%s\n' "$release_version" > "$system_root/etc/rg-ma2820/release"

defaults="$system_root/etc/uci-defaults/99-rg-ma2820-recovery"
sed -i -e "s/@HOSTNAME@/$hostname/g" "$defaults"

device_env="$system_root/etc/rg-ma2820/device.env"
if [ "$community_mode" != 1 ]; then
	sed -i \
		-e "s/@DEVICE_ID@/$device_id/g" \
		-e "s/@HOSTNAME@/$hostname/g" \
		-e "s/@RESCUE_LINK_LOCAL@/$rescue_link_local/g" \
		-e "s/@PEER_ID@/$peer_id/g" \
		-e "s/@PEER_HOSTNAME@/$peer_hostname/g" \
		-e "s/@PEER_LINK_LOCAL@/$peer_link_local/g" \
		-e "s/@LOCAL_BSSID_2G@/$local_bssid_2g/g" \
		-e "s/@LOCAL_BSSID_5G@/$local_bssid_5g/g" \
		-e "s/@LOCAL_BSSID_5G_LEGACY@/$local_bssid_5g_legacy/g" \
		-e "s/@PEER_BSSID_2G_DEVICE@/$peer_bssid_2g_device/g" \
		-e "s/@PEER_BSSID_5G_DEVICE@/$peer_bssid_5g_device/g" \
		-e "s/@PEER_BSSID_5G_LEGACY@/$peer_bssid_5g_legacy/g" \
		"$device_env"
fi

wifi_env="$system_root/etc/rg-ma2820/wifi.env"
if [ "$community_mode" != 1 ]; then
	case "$channel_5g" in
		36|40|44|48) center_channel_5g=42 ;;
		149|153|157|161) center_channel_5g=155 ;;
	esac
	case "$peer_channel_5g" in
		36|40|44|48) peer_center_channel_5g=42 ;;
		149|153|157|161) peer_center_channel_5g=155 ;;
	esac
	peer_op_class_5g=128
	roam_ssid_hex=$(printf %s "$roam_ssid" | od -An -tx1 | tr -d ' \n')
	sed -i \
		-e "s/@ROAM_SSID@/$roam_ssid/g" \
		-e "s/@ROAM_SSID_HEX@/$roam_ssid_hex/g" \
		-e "s/@WIFI_SECURITY@/$wifi_security/g" \
		-e "s/@WPA_PSK@/$wpa_psk/g" \
		-e "s/@COUNTRY_CODE@/$country_code/g" \
		-e "s/@CHANNEL_2G@/$channel_2g/g" \
		-e "s/@CHANNEL_5G@/$channel_5g/g" \
		-e "s/@CENTER_CHANNEL_5G@/$center_channel_5g/g" \
		-e "s/@PEER_BSSID_2G@/${peer_bssid_2g,,}/g" \
		-e "s/@PEER_BSSID_5G@/${peer_bssid_5g,,}/g" \
		-e "s/@PEER_CHANNEL_2G@/$peer_channel_2g/g" \
		-e "s/@PEER_CHANNEL_5G@/$peer_channel_5g/g" \
		-e "s/@PEER_CENTER_CHANNEL_5G@/$peer_center_channel_5g/g" \
		-e "s/@PEER_OP_CLASS_5G@/$peer_op_class_5g/g" \
		"$wifi_env"
fi

# The deterministic salt keeps otherwise identical rebuilds byte-for-byte.
password_hash=$(openssl passwd -6 -salt "rgma2820${device_id}" \
	"$root_password")
sed -i "s#^root:[^:]*:#root:$password_hash:#" \
	"$system_root/etc/shadow"
sed -i \
	-e "s#@FACTORY_ROOT_HASH@#$password_hash#g" \
	-e "s/@FACTORY_SSID_BASE@/$roam_ssid/g" \
	-e "s/@FACTORY_WIFI_SECURITY@/$wifi_security/g" \
	-e "s/@FACTORY_COUNTRY_CODE@/$country_code/g" \
	"$device_env"

mkdir -p "$system_root/etc/dropbear" "$system_root/root/.ssh"
if [ "$community_mode" != 1 ]; then
	# Pair images retain their pre-generated per-device trust material.
	for hostkey in rsa ecdsa ed25519; do
		install -m 0600 \
			"$dropbear_hostkey_dir/dropbear_${hostkey}_host_key" \
			"$system_root/etc/dropbear/dropbear_${hostkey}_host_key"
	done
	printf '%s\n' \
		"ssh-ed25519 $ap2_public_key rg-ma2820-ap2-peer-rescue" \
		"ssh-ed25519 $ap3_public_key rg-ma2820-ap3-peer-rescue" \
		> "$system_root/etc/dropbear/authorized_keys"
	printf '%s\n' \
		"$ap2_link_local ssh-ed25519 $ap2_public_key" \
		"$ap3_link_local ssh-ed25519 $ap3_public_key" \
		> "$system_root/root/.ssh/known_hosts"
	chmod 0600 "$system_root/etc/dropbear/authorized_keys"
	chmod 0700 "$system_root/root/.ssh"
	chmod 0600 "$system_root/root/.ssh/known_hosts"
else
	# A public image must not clone an identity onto every unit. S07 provision
	# creates unique host keys after validating this AP's preserved factory MTD.
	rm -f "$system_root"/etc/dropbear/dropbear_*_host_key \
		"$system_root/etc/dropbear/authorized_keys" \
		"$system_root/root/.ssh/known_hosts"
	chmod 0700 "$system_root/root/.ssh"
fi

chmod 0755 \
	"$system_root/etc/init.d/bcm6755-vendor-drivers" \
	"$system_root/etc/init.d/rg-ma2820-network-layout" \
	"$system_root/etc/init.d/rg-ma2820-reset-watch" \
	"$system_root/etc/init.d/rg-ma2820-management" \
	"$system_root/etc/init.d/rg-ma2820-neighbor-sync" \
	"$system_root/etc/init.d/rg-ma2820-roaming" \
	"$system_root/etc/init.d/rg-ma2820-leds" \
	"$system_root/etc/init.d/rg-ma2820-boot-success" \
	"$system_root/etc/init.d/rg-ma2820-wifi" \
	"$system_root/etc/init.d/sysntpd" \
	"$system_root/etc/init.d/umdns" \
	"$system_root/opt/bcm/sbin/vendor-run" \
	"$system_root/sbin/rg-ma2820-bootstrap-init" \
	"$system_root/usr/libexec/rg-ma2820/bootstate" \
	"$system_root/usr/libexec/rg-ma2820/channel-select" \
	"$system_root/usr/libexec/rg-ma2820/neighbor-sync" \
	"$system_root/usr/libexec/rg-ma2820/roaming-steer" \
	"$system_root/usr/libexec/rg-ma2820/led-loop" \
	"$system_root/usr/libexec/rg-ma2820/management-loop" \
	"$system_root/usr/libexec/rg-ma2820/reset-watch" \
	"$system_root/usr/sbin/rg-ma2820-factory-reset" \
	"$system_root/usr/sbin/rg-ma2820-peer" \
	"$system_root/usr/sbin/rg-ma2820-set-wifi" \
	"$system_root/usr/sbin/rg-ma2820-timezone" \
	"$system_root/usr/sbin/rg-ma2820-overview-status" \
	"$system_root/usr/sbin/rg-ma2820-wifi-capabilities" \
	"$system_root/usr/sbin/rg-ma2820-wifi-scan" \
	"$system_root/usr/sbin/rg-ma2820-wifi-status" \
	"$system_root/usr/sbin/rg-ma2820-recovery-upgrade" \
	"$system_root/usr/sbin/rg-ma2820-system-upgrade" \
	"$defaults"
if [ "$community_mode" = 1 ]; then
	chmod 0755 \
		"$system_root/etc/init.d/rg-ma2820-provision" \
		"$system_root/etc/init.d/rg-ma2820-cluster-sync" \
		"$system_root/usr/libexec/rg-ma2820/cluster-sync-loop" \
		"$system_root/usr/sbin/rg-ma2820-cluster" \
		"$system_root/www/cgi-bin/rg-ma2820-cluster"
	chmod 0600 "$system_root/etc/rg-ma2820/cluster.env"
	chmod 0644 "$system_root/etc/rg-ma2820/community-build" \
		"$system_root/usr/share/ucode/rg-ma2820/cluster.uc" \
		"$system_root/www/luci-static/resources/view/rg-ma2820/cluster.js"
fi
chmod 0600 "$device_env" "$wifi_env"

# Keep an authoritative service copy outside /etc. A retained writable
# overlay can otherwise shadow fixes to the Wi-Fi init script.
install -D -m 0755 \
	"$system_root/etc/init.d/rg-ma2820-wifi" \
	"$system_root/usr/libexec/rg-ma2820/rg-ma2820-wifi"
install -D -m 0755 \
	"$system_root/etc/init.d/sysntpd" \
	"$system_root/usr/libexec/rg-ma2820/sysntpd.init"
install -D -m 0600 \
	"$device_env" \
	"$system_root/usr/libexec/rg-ma2820/device.env"
install -D -m 0600 \
	"$wifi_env" \
	"$system_root/usr/libexec/rg-ma2820/wifi.env.factory"

mkdir -p "$system_root/etc/rc.d" "$system_root/.bootstrap"
ln -sfn ../init.d/bcm6755-vendor-drivers \
	"$system_root/etc/rc.d/S08bcm6755-vendor-drivers"
if [ "$community_mode" = 1 ]; then
	ln -sfn ../init.d/rg-ma2820-provision \
		"$system_root/etc/rc.d/S07rg-ma2820-provision"
fi
ln -sfn ../init.d/rg-ma2820-network-layout \
	"$system_root/etc/rc.d/S19rg-ma2820-network-layout"
ln -sfn ../init.d/rg-ma2820-reset-watch \
	"$system_root/etc/rc.d/S24rg-ma2820-reset-watch"
ln -sfn ../init.d/rg-ma2820-management \
	"$system_root/etc/rc.d/S25rg-ma2820-management"
ln -sfn ../init.d/rg-ma2820-wifi \
	"$system_root/etc/rc.d/S60rg-ma2820-wifi"
if [ "$community_mode" = 1 ]; then
	rm -f "$system_root/etc/rc.d/S65rg-ma2820-neighbor-sync"
	ln -sfn ../init.d/rg-ma2820-cluster-sync \
		"$system_root/etc/rc.d/S85rg-ma2820-cluster-sync"
else
	ln -sfn ../init.d/rg-ma2820-neighbor-sync \
		"$system_root/etc/rc.d/S65rg-ma2820-neighbor-sync"
fi
ln -sfn ../init.d/rg-ma2820-leds \
	"$system_root/etc/rc.d/S66rg-ma2820-leds"
ln -sfn ../init.d/rg-ma2820-roaming \
	"$system_root/etc/rc.d/S67rg-ma2820-roaming"
ln -sfn ../init.d/rg-ma2820-boot-success \
	"$system_root/etc/rc.d/S99rg-ma2820-boot-success"

# dnsmasq is launched only by the management controller when an isolated pair
# needs a temporary recovery subnet. firewall4 and its mainline kmods are not
# compatible with the retained RGOS 4.1.52 kernel.
for link in "$system_root"/etc/rc.d/S*dnsmasq \
	"$system_root"/etc/rc.d/S*firewall \
	"$system_root"/etc/rc.d/S*ubihealthd; do
	if [ -L "$link" ]; then
		unlink "$link"
	fi
done

if [ ! -e "$system_root/init" ] && [ ! -L "$system_root/init" ]; then
	ln -s sbin/init "$system_root/init"
fi

if grep -R -n -E '@[A-Z0-9_]+@' \
	"$system_root/etc/rg-ma2820" "$defaults"; then
	echo "unresolved packaging placeholder" >&2
	exit 1
fi

# Recovery starts from the same authenticated userspace, then drops all radio
# payloads. It retains Ethernet, Dropbear, LuCI, UBI tools, and the A/B updater.
rsync -a "$system_root/" "$recovery_root/"
touch "$recovery_root/etc/rg-ma2820/recovery-root"
mkdir -p "$recovery_root/mnt/system"
mv "$recovery_root/sbin/init" "$recovery_root/sbin/init.openwrt"
install -m 0755 "$recovery_root/sbin/rg-ma2820-bootstrap-init" \
	"$recovery_root/sbin/init"
rm -f "$recovery_root/etc/rc.d/S60rg-ma2820-wifi" \
	"$recovery_root/etc/rc.d/S65rg-ma2820-neighbor-sync" \
	"$recovery_root/etc/rc.d/S67rg-ma2820-roaming" \
	"$recovery_root/etc/rc.d/S85rg-ma2820-cluster-sync"
rm -rf -- "$recovery_root/opt/bcm"
find "$recovery_root/lib/modules/4.1.52" -type f \
	\( -name 'wl*.ko' -o -name 'dhd*.ko' -o -name 'hnd*.ko' \
	-o -name 'cfg80211.ko' -o -name 'emf.ko' -o -name 'igs.ko' \
	-o -name 'dpsta.ko' \) -delete

build_squashfs() {
	local source_root=$1 output=$2
	find "$source_root" -exec \
		touch -h --date="@$source_date_epoch" -- {} +
	# RGOS 11.9's 4.1.52 XZ decoder cannot read the ARM BCJ option.
	mksquashfs "$source_root" "$output" \
		-noappend -all-root -comp xz -b 131072 \
		-no-xattrs -no-exports -mkfs-time "$source_date_epoch" \
		-all-time "$source_date_epoch" -processors 1 -no-progress
	python3 "$project_dir/tools/verify-vendor-squashfs.py" "$output"
	file "$output"
	sha256sum "$output"
}

build_squashfs "$system_root" "$system_output"
build_squashfs "$recovery_root" "$recovery_output"
