#!/usr/bin/env python3
"""Reject SquashFS features unsupported by the RGOS 11.9 vendor kernel."""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys


SQUASHFS_MAGIC = 0x73717368
SQUASHFS_XZ = 4
SQUASHFS_COMP_OPT = 0x0400
VENDOR_BLOCK_SIZE = 128 * 1024


def validate(path: pathlib.Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 48:
        return ["file is shorter than a SquashFS superblock"]

    magic, _, _, block_size, _ = struct.unpack_from("<IIIII", data)
    compression, _, flags, _, major, minor = struct.unpack_from("<HHHHHH", data, 20)
    bytes_used = struct.unpack_from("<Q", data, 40)[0]

    errors: list[str] = []
    if magic != SQUASHFS_MAGIC:
        errors.append(f"bad magic 0x{magic:08x}")
    if (major, minor) != (4, 0):
        errors.append(f"unsupported SquashFS version {major}.{minor}")
    if compression != SQUASHFS_XZ:
        errors.append(f"compression id {compression} is not XZ ({SQUASHFS_XZ})")
    if block_size != VENDOR_BLOCK_SIZE:
        errors.append(
            f"block size {block_size} does not match stock {VENDOR_BLOCK_SIZE}"
        )
    if flags & SQUASHFS_COMP_OPT:
        errors.append(
            "compressor-options block is present; RGOS 11.9 cannot decode "
            "the ARM BCJ option used by the failed r2 image"
        )
    if not 48 <= bytes_used <= len(data):
        errors.append(f"bytes_used {bytes_used} is outside file size {len(data)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=pathlib.Path)
    args = parser.parse_args()

    try:
        errors = validate(args.image)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"vendor SquashFS compatibility: PASS ({args.image})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
