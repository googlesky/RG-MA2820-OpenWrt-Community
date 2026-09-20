#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
openwrt_dir=${1:-"$project_dir/openwrt"}

[ -f "$openwrt_dir/Makefile" ] || {
	echo "OpenWrt checkout not found: $openwrt_dir" >&2
	exit 1
}

cp -a "$project_dir/openwrt-overlay/target/linux/bcm6755" \
	"$openwrt_dir/target/linux/"
cp -a "$project_dir/openwrt-overlay/scripts/bcm6755-cfe-kernel.py" \
	"$openwrt_dir/scripts/"
mkdir -p "$openwrt_dir/package/system/ubus/patches"
cp -a "$project_dir/openwrt-overlay/package/system/ubus/patches/." \
	"$openwrt_dir/package/system/ubus/patches/"
mkdir -p "$openwrt_dir/package/network/config/netifd/patches"
cp -a "$project_dir/openwrt-overlay/package/network/config/netifd/patches/." \
	"$openwrt_dir/package/network/config/netifd/patches/"
cp "$project_dir/openwrt-overlay/config.seed" "$openwrt_dir/.config"

echo "Applied RG-MA2820(T) target and configuration seed to $openwrt_dir"
