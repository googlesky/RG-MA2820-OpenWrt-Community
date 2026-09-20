#!/usr/bin/env python3
"""Add the little-endian CFE header used by BCM6755 vmlinux.lz files."""

import argparse
import pathlib
import struct


MAGIC = b"BRCM"
HEADER = struct.Struct("<III4sI")


def auto_int(value: str) -> int:
    return int(value, 0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-file", required=True, type=pathlib.Path)
    parser.add_argument("--output-file", required=True, type=pathlib.Path)
    parser.add_argument("--load-addr", required=True, type=auto_int)
    parser.add_argument("--entry-addr", required=True, type=auto_int)
    args = parser.parse_args()

    payload = args.input_file.read_bytes()
    header = HEADER.pack(
        args.load_addr,
        args.entry_addr,
        len(payload),
        MAGIC,
        0,
    )
    args.output_file.write_bytes(header + payload)


if __name__ == "__main__":
    main()
