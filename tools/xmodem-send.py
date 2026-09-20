#!/usr/bin/env python3
"""Send one file to the stock BusyBox ``rx FILE`` command over UART."""

from __future__ import annotations

import argparse
import pathlib
import sys
import time

try:
    import serial
    from xmodem import XMODEM
except ImportError as exc:  # pragma: no cover - depends on host setup
    print(
        "missing dependency; install pyserial and xmodem in a virtualenv",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("--device", default="/dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "--mode",
        choices=("xmodem", "xmodem1k"),
        default="xmodem",
        help="use 128-byte XMODEM packets (the verified BusyBox rx mode)",
    )
    args = parser.parse_args()

    if not args.image.is_file() or args.image.stat().st_size == 0:
        parser.error(f"input is not a non-empty file: {args.image}")

    size = args.image.stat().st_size
    started = time.monotonic()
    last_report = -1

    with serial.Serial(
        args.device,
        args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=1,
        write_timeout=10,
        xonxoff=False,
        rtscts=False,
        dsrdtr=False,
        exclusive=True,
    ) as uart:
        uart.dtr = False
        uart.rts = False

        def getc(count: int, timeout: float = 1) -> bytes | None:
            uart.timeout = timeout
            data = uart.read(count)
            return data or None

        def putc(data: bytes, timeout: float = 1) -> int | None:
            uart.write_timeout = timeout
            try:
                written = uart.write(data)
                uart.flush()
            except serial.SerialTimeoutException:
                return None
            return written

        def progress(total_packets: int, success_count: int, error_count: int) -> None:
            nonlocal last_report
            packet_size = 1024 if args.mode == "xmodem1k" else 128
            sent = min(size, success_count * packet_size)
            percent = sent * 100 // size
            if percent != last_report and (percent % 5 == 0 or sent == size):
                elapsed = time.monotonic() - started
                print(
                    f"{percent:3d}%  {sent}/{size} bytes  "
                    f"retries={error_count}  elapsed={elapsed:.1f}s",
                    flush=True,
                )
                last_report = percent

        modem = XMODEM(getc, putc, mode=args.mode)
        try:
            with args.image.open("rb") as stream:
                ok = modem.send(
                    stream,
                    retry=32,
                    timeout=60,
                    quiet=True,
                    callback=progress,
                )
        except KeyboardInterrupt:
            modem.abort(timeout=1)
            print("XMODEM transfer cancelled", file=sys.stderr)
            return 130

    elapsed = time.monotonic() - started
    if not ok:
        print(f"XMODEM transfer failed after {elapsed:.1f}s", file=sys.stderr)
        return 1
    print(f"XMODEM transfer complete: {size} bytes in {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
