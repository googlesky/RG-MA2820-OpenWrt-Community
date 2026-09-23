# OpenWrt for Ruijie RG-MA2820(T)

[![Source tests](https://github.com/googlesky/RG-MA2820-OpenWrt-Community/actions/workflows/ci.yml/badge.svg)](https://github.com/googlesky/RG-MA2820-OpenWrt-Community/actions/workflows/ci.yml)
[![License: GPL-2.0](https://img.shields.io/badge/License-GPL--2.0--only-blue.svg)](LICENSE)

Community build system and device integration for the Ruijie RG-MA2820(T).
It combines an OpenWrt userspace with the matching RGOS 4.1.52 kernel and
Broadcom radio/Ethernet runtime supplied by the device owner.

The device integration through `r33` has run on two physical units. The
community profile adds a calibration-safe generic image and a controllerless,
dynamic N-node wired AP cluster. It is not limited to two APs or to the
historical `ap2`/`ap3` roles.

> **Do not install the r34 source prerelease.** It derived node identity from
> an `et0macaddr` placeholder shared by observed units and used `cksum`, which
> is absent from the target runtime. The r38 candidate corrects those issues
> and the downstream identity checks and management-election fallback;
> its complete first boot on an AP is still unverified.

## Generic image, unique devices

One generated `*-web.bin` can be installed on compatible RG-MA2820(T) units.
It intentionally contains no calibration, MAC address, serial number, SSH
host key, or fixed management IP. On first boot, each AP:

- mounts the separate stock `data` MTD read-only;
- validates board `6755` / type `0x08a9` and copies its own radio calibration;
- derives unique node, hostname, BSSID, and link-local recovery identities;
- generates new RSA, ECDSA, and Ed25519 Dropbear host keys.

The public repository contains no RGOS firmware, proprietary Broadcom modules,
calibration data, passwords, private keys, or flash dumps. Build the generic
image locally from a stock firmware file you are authorized to use; generated
firmware is ignored by Git and should remain private unless its redistribution
rights have been established separately.

## What works

- all five Ethernet sockets bridged for access-point operation;
- DHCP-first management plus deterministic link-local LAN recovery;
- immutable recovery and two independently updated system slots;
- full-image NAND readback, mount/read verification, trial boot, and rollback;
- 2.4 GHz and 5 GHz vendor radios with WPA2/WPA3, 802.11k/v, and 5 GHz 802.11r;
- authenticated mDNS discovery and wired-backhaul roaming across a dynamic
  number of APs;
- dedicated LuCI wireless/roaming page and a custom operational overview,
  both showing radios and associated clients across all discovered APs;
- WAN/LAN/Wi-Fi/WPS/Power LED control, including physical-port traffic activity;
- automatic geographic timezone selection from the managing browser.

This is wired multi-AP roaming, not 802.11s wireless mesh. The client still
makes the final roaming decision.

## Quick build

1. Read [the safety and support boundary](docs/ARCHITECTURE.md).
2. Back up every MTD partition as described in [the build guide](docs/BUILD.md).
3. Install the host dependencies, including `squashfs-tools` and
   `ubi-reader`, then run the owner-side builder with a matching stock UBI
   backup from your own RG-MA2820(T):

   ```sh
   git clone --recurse-submodules \
     https://github.com/googlesky/RG-MA2820-OpenWrt-Community.git
   cd RG-MA2820-OpenWrt-Community
   ./tools/build-community-from-stock.sh r38 ./output-r38 \
     /private/mtd0-rootfs.raw
   ```

   The script builds the pinned OpenWrt userspace when necessary, extracts the
   owner-supplied stock runtime in a temporary directory, and emits one generic
   web image plus A/B update and recovery images with `SHA256SUMS`.
   A matching stock WFI/EWEB package may be used instead of the UBI backup;
   firmware for the similarly named RG-MA2820B R5.2.9 is incompatible.

4. Validate the web image before installation:

   ```sh
   python3 tools/rg-web-image.py inspect \
     output-r38/RG-MA2820T-OpenWrt-Community-r38-web.bin
   ```

5. Read [RECOVERY.md](docs/RECOVERY.md), use the stock upload-check path first,
   and keep UART plus a verified stock backup available for initial conversion.

## Add any number of APs

Connect every AP to the same trusted Ethernet Layer-2 network/VLAN. Log in with
`root` / `root`, open **Network → RG-MA2820 Cluster**, and enter the exact same
cluster name and 12–128 character secret on each node. Nodes are discovered
dynamically; no member list or IP address is compiled into the firmware.

The shared profile uses wildcard 802.11r key holders, refreshes 802.11k
neighbors from every authenticated member, and exposes all node/client status
from any AP. Reapply the Wi-Fi profile to the cluster after joining a new AP.
See [the multi-AP operating guide](docs/CLUSTER.md) for topology, scaling, and
security details.

Do a RAM-only UART/TFTP boot before persistent installation. A private
calibration-backed RAM trial can check the generic runtime without writing the
new UBI layout, but cannot prove the web conversion or rollback path. Keep a
3.3 V UART adapter and a verified stock backup available during first
bring-up. See [RECOVERY.md](docs/RECOVERY.md).

## Project status

The source, deterministic image constructors, and runtime have regression
coverage. Release `r33` was accepted on two observed hardware units. The new
generic/N-node profile passes three-node provisioning tests, target-ARM ucode
tests, complete SquashFS builds, UBI volume/CRC reconstruction, EWEB/WFI CRC
validation, and private-material scans. The r38 provisioning functions also
passed an isolated `/tmp` test using one physical AP's real calibration; that
did not boot the new ROM or write flash. It remains a release candidate until
the complete generic first-boot path is exercised on physical hardware.

Issues and pull requests are welcome. Never attach private flash dumps,
calibration files, passwords, or device host keys to a public issue.

Ruijie and Broadcom are trademarks of their respective owners. This project is
independent and is not endorsed by either vendor.
