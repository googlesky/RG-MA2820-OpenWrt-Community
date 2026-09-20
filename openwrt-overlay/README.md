# OpenWrt source overlay

The `openwrt/` submodule is pinned to upstream commit
`928cd26bd938b8ac46b79e14f5f9f4b1d772abe8`.  This directory contains the
project-specific files that are not part of that upstream commit.

Apply the overlay and seed the configuration from the repository root:

```sh
./tools/apply-openwrt-overlay.sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
```

The upstream target builds a mainline Linux diagnostic/RAM-recovery image.
The persistent EWEB packages additionally require the device-derived vendor
kernel, modules, calibration data, and metadata described in
`../docs/BUILD.md`; those private inputs are intentionally not part of the
source overlay.
