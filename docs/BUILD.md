# Building a pair-specific release

## 1. Keep a private backup first

Before changing flash, capture every `/dev/mtd*` partition, `/proc/mtd`, the
UBI inventory, and a complete UART boot log from each AP. Verify hashes on a
second storage device. Do not put those files in this repository or a public
issue.

The build needs owner-supplied RGOS material because redistribution is outside
this project's scope and calibration is device-specific.

## 2. Host dependencies

Use a case-sensitive Linux filesystem. Install the normal OpenWrt build
dependencies plus:

```text
bash python3 rsync openssl squashfs-tools cpio gzip xz-utils file
dropbear-bin ubi-reader
```

Package names differ by distribution. `ubi-reader` provides
`ubireader_extract_images` and `ubireader_extract_files` and may instead be
installed in a Python virtual environment.

## 3. Prepare the stock runtime and volumes

Obtain an RGOS firmware matching the running device. Verify its vendor
checksum before using it. The helper validates the Broadcom WFI CRC and
extracts its UBI payload without extracting or rewriting CFEROM:

```sh
mkdir -p /private/rg-ma2820
python3 tools/rg-web-image.py extract /private/vendor-firmware.w \
  --ubi-output /private/rg-ma2820/stock.ubi \
  --cferom-output /private/rg-ma2820/cferom.bin

ubireader_extract_images -o /private/rg-ma2820/volumes \
  /private/rg-ma2820/stock.ubi
ubireader_extract_files -o /private/rg-ma2820/files \
  /private/rg-ma2820/stock.ubi
```

Locate the extracted directory that contains all of these paths and use it as
`VENDOR_ROOT`:

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

## 4. Prepare each private state root

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

## 5. Record radio identities with a RAM-only boot

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

## 6. Create and check the pair profile

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

## 7. Build

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
