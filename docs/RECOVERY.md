# Recovery and first-install safety

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

Serve the matching stock `vmlinux.lz`, `947622.dtb`, and the initramfs produced
by `tools/package-hybrid-ramdisk.sh`. The verified physical RAM address for the
external initramfs is `0x08000000`:

```text
r n 192.168.1.100 vmlinux.lz initramfs.cpio.gz 947622.dtb 0x08000000
```

This command boots RAM and does not erase NAND. Check Ethernet, both radios,
interface MAC addresses, SSH, and LuCI. A power cycle returns to RGOS.

Do not use CFE flash/erase commands during this test. Do not guess a different
RAM address from examples for MIPS Broadcom boards.

## Initial web conversion

The `*-web.bin` wrapper is intended only for the matching physical AP while it
still runs stock RGOS. Use `tools/rg-eweb.py upload-check` first; it asks RGOS
to validate the real model/header and then cancels the upload:

```sh
python3 tools/rg-eweb.py --host AP_ADDRESS upload-check \
  /private/output-r1/ap2/RG-MA2820T-AP2-OpenWrt-r1-web.bin
```

Only the explicit `upload-flash --yes-really-flash` path starts an upgrade.
Keep UART attached, stable power, the complete stock backup, and a known
working stock-slot rollback procedure during the first persistent test.

The wrapper intentionally contains no CFEROM. Nevertheless, first conversion
replaces the system UBI layout and is a high-risk operation. A structurally
valid image is not proof that untested hardware will boot it.

## After conversion

Normal updates use the matching `*-system.squashfs` through
`rg-ma2820-system-upgrade`; they write the inactive slot and preserve the
accepted fallback. Do not use a full web wrapper for routine updates.

If a trial fails its health gate, the immutable bootstrap returns to the last
accepted system. If both systems are unusable, request immutable recovery and
repair over a directly connected LAN. Rewriting recovery itself is exceptional
because power loss during volume 0 replacement can still require UART.
