# Architecture and support boundary

## Why this is a hybrid firmware

Mainline Linux describes the BCM47622 CPU, interrupt controller, UART, SPI,
and NAND controller, but it does not provide the complete Ethernet and WLAN
stack needed by this board. The persistent firmware therefore retains the
exact RGOS Linux 4.1.52 kernel, DTB/filestruct, Broadcom modules, radio tools,
and their isolated glibc runtime. OpenWrt supplies init, networking,
management services, LuCI, SSH, update logic, and the application layer.

The `openwrt-overlay/` target also builds a mainline diagnostic initramfs. It
is useful for source development but is not a replacement for the hybrid
image on current hardware.

## One image, per-device identity

The community image is intentionally generic. It contains no calibration,
device MAC address, serial number, SSH host key, fixed management address, or
pre-enrolled peer. Early on first boot, `rg-ma2820-provision`:

1. locates the separate stock `data` MTD and mounts it read-only;
2. validates the calibration size, board number `6755`, board type `0x08a9`,
   and the two distinct unicast radio MAC addresses; the observed Ethernet
   field is a shared placeholder and is not used as a node identity;
3. copies that AP's calibration into its writable overlay;
4. derives a stable `node-<12 hex digits>` identity, hostname, recovery
   link-local address, and BSSIDs from the device's validated factory radio
   MACs, not the shared `et0macaddr` placeholder; and
5. generates new RSA, ECDSA, and Ed25519 Dropbear host keys locally.

Normal services do not pass their health gate if provisioning fails. The
factory `data` MTD remains outside the system UBI written by the web image.
Never clone the writable overlay between APs: doing so would clone identity
and private keys.

The older fixed-pair packager remains available for existing `ap2`/`ap3`
installations. Its embedded identities and SSH peer transport are a legacy
compatibility mode, not a limit of the generic community profile.

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
back, mounts it with the retained kernel, and reads every regular file before
marking one trial boot. The new system is accepted only after its network,
SSH, LuCI, radio, management, provisioning, and cluster health checks remain
successful. A cluster peer is not required to be online, so a single AP can
still be updated or recovered independently. Otherwise the bootstrap returns
to the previously accepted slot.

Updating immutable recovery is a separate maintenance action. Its updater
keeps a complete in-RAM backup and attempts restoration if post-write
verification fails, but power loss during that exceptional write can still
require UART recovery.

## Dynamic wired AP cluster

The generic profile has no compiled two-node member list and no elected
controller. Each AP advertises a minimal service record with mDNS, filters it
by cluster ID, and authenticates every status or configuration RPC with an
HMAC-SHA256 key derived from the shared cluster secret. Discovery alone does
not grant access. Before sending a configuration body, the caller first
requires a signed status challenge from the discovered candidate; an mDNS
spoof therefore receives no Wi-Fi secret.

All members configured with the same cluster name and secret:

- use the same 802.11r mobility domain and wildcard R0KH/R1KH key-holder
  material, so a newly joined AP does not require rebuilding every old AP;
- refresh their 802.11k neighbor reports from every authenticated, reachable
  member with a matching SSID and band;
- expose node, radio, and associated-client status from any member's LuCI;
- can receive a validated Wi-Fi profile from any member; and
- continue serving clients locally when another AP or the entire discovery
  plane is unavailable.

Membership is dynamic: adding the third, fourth, or later AP is the same
operation as adding the second. There is no source-code rebuild, fixed IP, or
central controller. Removing an AP requires no cleanup after its mDNS record
expires.

This does not imply an unlimited tested scale. Status collection and neighbor
synchronization are controllerless all-to-all operations, so control traffic
and work grow approximately with the square of the member count. The
validated public test covers three simulated identities; the private hardware
campaign covers two physical APs. Larger deployments should keep one cluster
inside one trusted Layer-2 management VLAN, measure multicast and neighbor
table behavior, and split independent sites into separate cluster names.

## Wired roaming, not 802.11s

Every Ethernet socket joins `br-lan`; any socket can be the uplink. Ethernet
is the backhaul. 802.11k provides neighbor information, 802.11v can suggest a
transition, and 802.11r can shorten reauthentication. The client still makes
the final roaming decision, and a client that ignores those standards may
remain associated with a weak AP until steering or disconnect thresholds are
reached.

The proprietary driver does not expose a usable mac80211 802.11s mesh-point
mode. Describing this design as wireless mesh would therefore be misleading;
it is a controllerless wired multi-AP roaming system.

## Trust boundary

Cluster requests and responses are authenticated and integrity-protected;
mutations use a bounded recent-nonce replay cache. They are currently HTTP on
the local wired network, not encrypted transport. A passive observer can see
a Wi-Fi password while an administrator distributes a new profile. Put AP
management on a trusted VLAN, never forward the cluster CGI endpoint from the
Internet, and rotate the cluster and Wi-Fi secrets after any management-LAN
compromise.

## Verified and unverified scope

The private hardware campaign through `r33` covered web conversion on stock,
A/B update/readback, deliberate rollback, immutable recovery, factory reset,
simultaneous reboot, radios, Ethernet, LuCI/SSH, pair-wide client visibility,
roaming, and LED behavior on two RG-MA2820(T) units.

The generic image adds automated factory-data provisioning and dynamic
N-node clustering. Its source tests cover three unique nodes, target-ARM ucode
compilation and HMAC vectors, image privacy audits, SquashFS compatibility,
UBI volume reconstruction, and EWEB/WFI CRCs. Its first persistent boot has
not yet been independently exercised on another physical unit, so it remains
a release candidate. Do not assume that every board or RGOS release is
byte-compatible; compare model, hardware revision, kernel version, NAND
geometry, and UBI layout before building for another unit.
