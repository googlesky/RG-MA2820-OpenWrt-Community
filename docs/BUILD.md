# Building the generic community release

## 1. Keep a private backup first

Before changing flash, capture every `/dev/mtd*` partition, `/proc/mtd`, the
UBI inventory, and a complete UART boot log from each AP. Verify hashes on a
second storage device. Do not put those files in this repository or a public
issue.

The build needs owner-supplied RGOS material because redistribution is outside
this project's scope. Device calibration is no longer a build input: the
generic image imports it read-only from each AP's preserved factory `data` MTD
at first boot.

## 2. Host dependencies

Use a case-sensitive Linux filesystem. Install the normal OpenWrt build
dependencies plus:

```text
bash python3 rsync openssl squashfs-tools cpio gzip xz-utils file
dropbear-bin ubi-reader
```

Package names differ by distribution. `ubi-reader` provides
`ubireader_extract_images` and may instead be installed in a Python virtual
environment.

## 3. One-command owner-side build

The recommended path extracts the owner's raw stock `rootfs` UBI MTD backup,
builds the pinned OpenWrt userspace if it is not already present, and removes
all temporary vendor files on exit:

```sh
./tools/build-community-from-stock.sh r34 /private/output-r34 \
  /private/mtd0-rootfs.raw
```

Set `UBIREADER_EXTRACT_IMAGES=/path/to/ubireader_extract_images` if the helper
is installed in a virtual environment. A prebuilt runtime can be supplied as a
fourth argument to skip the OpenWrt build.

A matching stock WFI/EWEB file also works as input. The similarly named
RG-MA2820B R5.2.9 `*.w` available in the research archive has a larger,
different kernel/filestruct and is **not** compatible with the validated
RG-MA2820(T) AP_RGOS 11.9(4) layout. The builder refuses it; do not increase
kernel volume allocation just to silence that error. A raw backup contains
device-specific material: keep the input private, even though the generated
community image imports calibration separately at first boot.

The output contains:

- `RG-MA2820T-OpenWrt-Community-r34-web.bin` for initial RGOS conversion;
- `*-system.squashfs` for routine A/B updates;
- `*-recovery.squashfs` for exceptional immutable-recovery maintenance;
- `*.ubi`, `SHA256SUMS`, and a non-secret build manifest.

The build audit fails if either SquashFS contains calibration, SSH host keys,
authorized keys, fixed device identities, or unresolved templates.

## 4. Manual generic build

For an already built OpenWrt runtime, prepare the stock runtime and volumes as
follows.

Obtain an RGOS firmware matching the running device. Verify its vendor
checksum before using it. The helper validates the Broadcom WFI CRC and
extracts its UBI payload without extracting or rewriting CFEROM. If using a
matching raw UBI backup instead, pass it directly to `ubireader_extract_images`
and skip this WFI extraction command:

```sh
mkdir -p /private/rg-ma2820
python3 tools/rg-web-image.py extract /private/vendor-firmware.w \
  --ubi-output /private/rg-ma2820/stock.ubi

ubireader_extract_images -o /private/rg-ma2820/volumes \
  /private/rg-ma2820/stock.ubi

mkdir -p /private/rg-ma2820/vendor-root
ROOTFS_IMAGE=$(find /private/rg-ma2820/volumes -type f \
  -name 'img-*_vol-rootfs_ubifs.ubifs' -print)
[ "$(printf '%s\n' "$ROOTFS_IMAGE" | sed '/^$/d' | wc -l)" -eq 1 ]
unsquashfs -d /private/rg-ma2820/vendor-root "$ROOTFS_IMAGE"
STOCK_VOLUME_DIR=${ROOTFS_IMAGE%/*}
```

The count assertion deliberately stops the instructions unless exactly one
`rootfs_ubifs` image matched. The unpacked directory must contain all of these
paths and is used as `VENDOR_ROOT`:

```text
lib/modules/4.1.52/extra/wl.ko
usr/sbin/hostapd
usr/sbin/hostapd_cli
usr/sbin/wl
bin/nvram
lib/ld-linux.so.3
```

Use the directory containing the three extracted images below as
`STOCK_VOLUME_DIR`. The numeric image sequence may vary; the build discovers
it rather than hardcoding it.

```text
img-*_vol-METADATA.ubifs
img-*_vol-METADATACOPY.ubifs
img-*_vol-filestruct_full.bin.ubifs
```

Never substitute filestruct or modules from a different model, kernel build,
or RGOS line merely because their names match.

Then run:

```sh
RUNTIME_ROOT=$PWD/openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755
UBINIZE=$PWD/openwrt/staging_dir/host/bin/ubinize \
  ./tools/build-community-release.sh r34 /private/output-r34 \
  "$RUNTIME_ROOT" /private/rg-ma2820/vendor-root \
  "$STOCK_VOLUME_DIR"
```

## 5. Generic-image safety model

The web image rewrites only the system UBI MTD. It does not contain CFEROM and
does not cover the separate stock `data` MTD. First boot refuses to start the
normal system health trial unless it can validate and copy a 4–64 KiB
`.kernel_nvram.setting` with the expected board identifiers and valid unicast
Ethernet/2.4 GHz/5 GHz MAC addresses.

Each AP generates unique Dropbear keys locally. Never copy `/etc/dropbear`,
`/etc/rg-ma2820/kernel_nvram.setting`, or a writable overlay between APs.

## Legacy pair-specific builder

The original fixed-pair builder remains for existing installations that must
produce byte-compatible `ap2`/`ap3` updates. New community installations
should use the generic builder above.

### Prepare each private state root

Create this layout outside the checkout for each physical AP:

```text
/private/ap2-state/
  etc/rg-ma2820/kernel_nvram.setting
  etc/dropbear/dropbear_rsa_host_key
  etc/dropbear/dropbear_ecdsa_host_key
  etc/dropbear/dropbear_ed25519_host_key
```

Repeat as `/private/ap3-state/` with different host keys and that unit's own
NVRAM. On stock RGOS, the live per-device NVRAM is
`/data/.kernel_nvram.setting`; the zero-length template under `/etc/wlan` is
not a substitute. Copy it byte-for-byte and hash it.

If the AP does not already have Dropbear host keys, generate a unique set for
each unit on the build host:

```sh
dropbearkey -t rsa -s 3072 -f /private/ap2-state/etc/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -s 256 -f /private/ap2-state/etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t ed25519 -f /private/ap2-state/etc/dropbear/dropbear_ed25519_host_key
```

Do not copy one unit's private keys to the other. The builder extracts the
Ed25519 public blobs itself and pins both peers.

### Record radio identities with a RAM-only boot

Build OpenWrt first:

```sh
git submodule update --init --recursive
./tools/apply-openwrt-overlay.sh
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make -j"$(nproc)"
cd ..
```

The OpenWrt userspace root is normally:

```text
openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755
```

Use `tools/package-hybrid-ramdisk.sh` with the vendor root to make a RAM-only
hybrid initramfs, then boot the matching stock kernel/DTB/filestruct from CFE
as described in [RECOVERY.md](RECOVERY.md). From the RAM system record:

```sh
cat /sys/class/net/wl0/address
cat /sys/class/net/wl1/address
```

These become `BSSID_2G` and `BSSID_5G`. Reserve the next unique unicast address
for the 5 GHz compatibility BSS and verify that the driver accepts it:

```sh
python3 tools/mac-add.py "$(cat /sys/class/net/wl1/address)" 1
```

Do not infer radio addresses only from the chassis label; allocation differs
between observed units.

### Create and check the pair profile

Copy `config/pair.example.env` outside the checkout and replace all example
addresses. The strict parser accepts only known `KEY=value` fields and never
executes the file as shell code.

The two link-local addresses must be distinct and unused on your LAN. The six
BSSIDs must be distinct. Set `COUNTRY_CODE` to the driver profile appropriate
for the installation location. `ap2` and `ap3` are coordination roles; DHCP
remains the normal management-address source.

```sh
./tools/build-pair-release.sh --check \
  /private/pair.env /private/ap2-state /private/ap3-state
```

### Build the fixed pair

```sh
RUNTIME_ROOT=$PWD/openwrt/build_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755

./tools/build-pair-release.sh r1 /private/output-r1 \
  "$RUNTIME_ROOT" /private/rg-ma2820/vendor-root \
  /private/ap2-state /private/ap3-state \
  /private/rg-ma2820/volumes /private/pair.env
```

The output contains, separately for each role:

- `*-system.squashfs`: normal future A/B updates;
- `*-recovery.squashfs`: immutable recovery maintenance;
- `*.ubi`: complete initial UBI payload;
- `*-web.bin`: RGOS EWEB initial conversion wrapper;
- `SHA256SUMS`: hashes for every artifact.

Never swap the AP2/AP3 output directories. Store the private profile, NVRAM,
keys, generated images, and their hashes with the flash backup.

## Reproducibility

The packager normalizes ownership, ordering, timestamps, SquashFS options, and
gzip metadata. Set `SOURCE_DATE_EPOCH` to a fixed unsigned integer and rebuild
into a new empty output directory. With identical tool versions and byte-exact
inputs, the resulting artifacts should match.
