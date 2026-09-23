# Recovery and first-install safety

## Back up before conversion

Capture every `/dev/mtd*` partition, `/proc/mtd`, the UBI inventory, the
factory `/data/.kernel_nvram.setting`, and a complete UART boot log before a
persistent installation. Hash the backup and copy it to a second storage
device. A generic image preserves the separate factory `data` MTD, but that is
not a substitute for an offline backup.

## UART wiring

Use a 3.3 V USB-TTL adapter. The verified console is 115200 baud, 8 data bits,
no parity, one stop bit, and no flow control. Power the AP normally and never
connect the adapter's VCC pin.

`J105` is the four-pin header beside the large shield. Count from the
silkscreen triangle:

| Pin | Function | Adapter |
| ---: | --- | --- |
| 1 | Supply/unused | Leave disconnected |
| 2 | Ground | GND |
| 3 | AP transmit | RXD |
| 4 | AP receive | TXD |

Connect or move wires only with AP power off. Verify that the adapter TX idle
level is approximately 3.3 V before connecting pin 4. The helper starts a
private timestamped capture under `/tmp`:

```sh
./tools/uart-console.sh /dev/ttyUSB0
```

Raw boot logs can contain transient WLAN material; do not commit them.

## RAM-only validation

Start with an isolated Ethernet link and a TFTP host at `192.168.1.100/24`.
Interrupt CFE and use its read-only information command first. Continue only
after confirming the expected BCM47622 board, 256 MiB RAM, and NAND geometry.

For a generic candidate on an AP that already runs the older pair-specific
OpenWrt, first package a **private** RAM trial with that AP's own backed-up
calibration, stock kernel, and matching DTB. This bundle embeds calibration
only to avoid attaching the factory MTD during the RAM test; it is not a
redistributable community image:

```sh
./tools/package-community-ram-trial.sh \
  /private/output-r38/rg-ma2820t-community-r38-system.squashfs \
  /private/ap3/.kernel_nvram.setting \
  /private/ap3/vmlinux.lz /private/ap3/947622.dtb \
  /private/ap3-r38-ram-trial
cd /private/ap3-r38-ram-trial
sha256sum -c SHA256SUMS
```

The trial omits the boot-success and physical-Reset services, uses a RAM-backed
OpenWrt root, and never invokes a firmware writer. Isolate the AP from the
production LAN: its default WLAN is open and its initial root password is
`root`. The verified physical RAM address for the external initramfs is
`0x08000000`:

```text
r n 192.168.1.100 vmlinux.lz initramfs.cpio.gz 947622.dtb 0x08000000
```

This CFE command requests a RAM boot and does not erase NAND. On the serial
console, confirm the expected initramfs, `/proc/cmdline`, and that no writable
NAND overlay was mounted; then check Ethernet, both radios, interface MACs,
SSH, and LuCI. A power cycle returns to the firmware already installed on
that AP (RGOS or the older OpenWrt release). This is a **partial runtime test**:
it bypasses first-boot factory-MTD import and does not prove the web wrapper,
persistent A/B conversion, or network-only rollback.

Do not use CFE flash/erase commands during this test. Do not guess a different
RAM address from examples for MIPS Broadcom boards.

## Initial web conversion

The generic `*-web.bin` wrapper is intended only for a compatible
RG-MA2820(T) still running stock RGOS. Inspect it locally and ask RGOS to
validate the real upload without starting an upgrade:

```sh
python3 tools/rg-web-image.py inspect \
  /private/output-r38/RG-MA2820T-OpenWrt-Community-r38-web.bin

python3 tools/rg-eweb.py --host AP_ADDRESS upload-check \
  /private/output-r38/RG-MA2820T-OpenWrt-Community-r38-web.bin
```

The EWEB client prompts for the current management password without terminal
echo. Only the explicit `upload-flash --yes-really-flash` path starts an
upgrade. Keep UART attached, stable power, the complete stock backup, and a
tested TFTP path during the first persistent conversion.

The wrapper intentionally contains no CFEROM. Nevertheless, first conversion
replaces the system UBI layout and is a high-risk operation. A structurally
valid image or a successful vendor upload check does not prove that untested
hardware will boot it.

## First boot and emergency access

Successful first boot imports that unit's factory calibration, creates unique
SSH host keys, and starts an open `RG-MA2820-Setup` WLAN. The initial login is
`root` / `root`. Connect only from a trusted local network, change the root
password and Wi-Fi profile immediately, then create or join the wired cluster.

DHCP is the normal management path. The generated per-device link-local
address is available in `/etc/rg-ma2820/device.env` and on the LuCI overview.
It is stable for that AP and is intended for a directly connected recovery
host when upstream DHCP or topology is broken.

## Routine update and rollback

Normal updates use the generic `*-system.squashfs` through
`rg-ma2820-system-upgrade`. The updater checks the compatibility class, writes
the inactive slot, performs complete readback/mount/file verification, and
requests one trial boot. It preserves the accepted slot; do not use the full
web wrapper for routine updates.

If a trial fails its health gate, immutable bootstrap returns to the last
accepted system. A peer does not have to be online for that health decision.
If both systems are unusable, request immutable recovery and repair over a
directly connected LAN. Rewriting recovery itself is exceptional because
power loss during volume 0 replacement can still require UART.
