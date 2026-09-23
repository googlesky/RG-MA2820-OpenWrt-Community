#!/usr/bin/env bash
# Build the small userspace activity controller for the retained ARM kernel.
set -euo pipefail
[ "$#" = 1 ] || { echo "usage: $0 OUTPUT" >&2; exit 2; }
project_dir=$(cd "$(dirname "$0")/.." && pwd)
compiler=${RG_MA2820_CC:-$project_dir/openwrt/staging_dir/toolchain-arm_cortex-a7_gcc-14.4.0_musl_eabi/bin/arm-openwrt-linux-gcc}
staging_dir=${RG_MA2820_STAGING_DIR:-$project_dir/openwrt/staging_dir}
STAGING_DIR="$staging_dir" "$compiler" \
	-Os -Wall -Wextra -Werror -std=c11 -fno-ident -Wl,--build-id=none -s \
	-o "$1" "$project_dir/src/led-traffic.c"
