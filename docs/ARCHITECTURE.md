# Architecture and support boundary

## Why this is a hybrid firmware

Mainline Linux describes the BCM47622 CPU, interrupt controller, UART, SPI, and
NAND controller, but it does not provide the complete Ethernet and WLAN stack
needed by this board. The persistent firmware therefore retains the exact
RGOS Linux 4.1.52 kernel, DTB/filestruct, Broadcom modules, radio utilities,
and their isolated glibc runtime. OpenWrt supplies the init system, networking,
management services, LuCI, SSH, update logic, and application layer.

The `openwrt-overlay/` target also builds a mainline diagnostic initramfs. It
is useful for source development but is not a replacement for the hybrid image
on current hardware.

## Persistent flash layout

The generated pure-UBI web image does not include CFEROM/NVRAM and does not
cover the separate factory/data MTD partitions. It keeps the stock reservation
total while defining:

| UBI ID | Name | Role |
| ---: | --- | --- |
| 0 | `rootfs_ubifs` | Small immutable wired recovery/bootstrap root |
| 1/2 | `METADATA` / `METADATACOPY` | Stock boot metadata |
| 3 | `rootfs_data` | Writable OpenWrt overlay |
| 4/5 | `system_a` / `system_b` | Independently replaceable system roots |
| 6 | `bootstate` | Checksummed atomic A/B state |
| 10 | `filestruct_full.bin` | Exact vendor kernel/DTB/filestruct payload |

An update writes only the inactive system slot, reads the complete NAND data
back, mounts it with the retained kernel, reads every regular file, and marks
one trial boot. The new system is accepted only after its network, SSH, LuCI,
radio, roaming, and management health gate remains successful. Otherwise the
bootstrap returns to the previously accepted slot.

Updating immutable recovery is a separate maintenance action. Its updater
keeps a complete in-RAM backup and attempts restoration if post-write
verification fails, but a power loss during that particular write can still
require UART recovery.

## Per-device identity

The logical roles remain `ap2` and `ap3`: `ap2` is the bounded coordination
leader and `ap3` the follower. They are roles, not IP address suffixes. The
community profile supplies arbitrary unique link-local addresses and the real
radio identities observed on each physical unit.

The build embeds only that unit's:

- `/data/.kernel_nvram.setting` calibration/runtime NVRAM;
- RSA, ECDSA, and Ed25519 Dropbear host keys;
- local BSSIDs and peer BSSIDs;
- rescue address and peer trust pins.

The strict package and updater checks prevent an AP2 image from being staged
on AP3 and prevent a recovery image with different host keys from replacing
the trusted recovery root.

## Wired roaming

Every Ethernet port joins `br-lan`; any port can be the uplink. The two APs
exchange radio/channel state over Ethernet, install each other as 802.11k
neighbors, offer 802.11v BSS transition, and support 802.11r on suitable 5 GHz
profiles. Automatic channel selection coordinates non-overlapping fallback
blocks after simultaneous power-up.

The proprietary driver does not expose a usable mac80211 802.11s mesh-point
mode. Marketing this design as wireless mesh would be misleading: Ethernet is
the backhaul, and standards-assisted client roaming is the service.

## Verified and unverified scope

The private hardware campaign behind `r30` covered web conversion on stock,
A/B update/readback, deliberate rollback, immutable recovery, factory reset,
simultaneous reboot, radios, Ethernet, LuCI/SSH, roaming, and LED behavior on
two RG-MA2820(T) units. The public tree contains no claim that every board or
RGOS release is byte-compatible. Compare model, hardware revision, kernel
version, NAND geometry, and UBI layout before building for another unit.
