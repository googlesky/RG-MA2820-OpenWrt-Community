# OpenWrt for Ruijie RG-MA2820(T)

[![Source tests](https://github.com/googlesky/RG-MA2820-OpenWrt-Community/actions/workflows/ci.yml/badge.svg)](https://github.com/googlesky/RG-MA2820-OpenWrt-Community/actions/workflows/ci.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0--only-blue.svg)](LICENSE)

Community build system and device integration for the Ruijie RG-MA2820(T).
It combines an OpenWrt userspace with the matching RGOS 4.1.52 kernel and
Broadcom radio/Ethernet runtime supplied by the device owner.

This is the public, sanitized continuation of release `r33`, which has run on
two hardware units with wired backhaul, A/B rollback, immutable LAN recovery,
LuCI, WPA3/WPA2 roaming, and traffic-driven front-panel LEDs.

## Important: images are device-bound

There is intentionally no universal download-and-flash `.bin`. Each AP has
calibration NVRAM, radio identities, and SSH host keys that must remain unique.
The build creates a separate image for each member of a pair from that pair's
own private inputs. Swapping images between devices can break radio operation
or duplicate network identities.

The repository contains no RGOS firmware, proprietary Broadcom modules,
calibration data, passwords, private keys, or flash dumps. Keep those inputs
outside the checkout and do not publish generated images unless you have
audited them.

## What works

- all five Ethernet sockets bridged for access-point operation;
- DHCP-first management plus deterministic link-local LAN recovery;
- immutable recovery and two independently updated system slots;
- full-image NAND readback, mount/read verification, trial boot, and rollback;
- 2.4 GHz and 5 GHz vendor radios with WPA2/WPA3, 802.11k/v, and 5 GHz 802.11r;
- coordinated wired-backhaul roaming between two APs;
- dedicated LuCI wireless/roaming page and a custom operational overview,
  both showing radios and associated clients across the AP pair;
- WAN/LAN/Wi-Fi/WPS/Power LED control, including physical-port traffic activity;
- automatic geographic timezone selection from the managing browser.

This is wired multi-AP roaming, not 802.11s wireless mesh. The client still
makes the final roaming decision.

## Quick start

1. Read [the safety and support boundary](docs/ARCHITECTURE.md).
2. Back up every MTD partition and prepare the private inputs described in
   [the build guide](docs/BUILD.md).
3. Clone and build the pinned OpenWrt source:

   ```sh
   git clone --recurse-submodules \
     https://github.com/googlesky/RG-MA2820-OpenWrt-Community.git
   cd RG-MA2820-OpenWrt-Community
   ./tools/apply-openwrt-overlay.sh
   cd openwrt
   ./scripts/feeds update -a
   ./scripts/feeds install -a
   make defconfig
   make -j"$(nproc)"
   ```

4. Copy `config/pair.example.env` outside the repository, fill it with the
   identities observed on your APs, and validate it:

   ```sh
   ./tools/build-pair-release.sh --check \
     /private/pair.env /private/ap2-state /private/ap3-state
   ```

5. Build the pair-specific release as shown in [BUILD.md](docs/BUILD.md).

Do a RAM-only UART/TFTP boot before persistent installation. Keep a 3.3 V UART
adapter connected and a verified stock backup available during first bring-up.
See [RECOVERY.md](docs/RECOVERY.md).

## Project status

The source, deterministic image constructors, and runtime have regression
coverage. Release `r33` was accepted on two observed hardware units; its A/B
gate invokes and identity-checks the complete pair-status RPC before accepting
an update. Community images built from other units remain experimental until
their owners verify
the exact board revision, stock kernel/runtime, calibration data, and flash
geometry.

Issues and pull requests are welcome. Never attach private flash dumps,
calibration files, passwords, or device host keys to a public issue.

Ruijie and Broadcom are trademarks of their respective owners. This project is
independent and is not endorsed by either vendor.
