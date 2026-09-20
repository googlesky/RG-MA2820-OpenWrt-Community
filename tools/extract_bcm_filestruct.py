#!/usr/bin/env python3
"""List or extract Broadcom filestruct_full.bin entries.

The MA2820B reference firmware stores its DTBs, CFE RAM image, and kernel in a
small big-endian container.  Records after the first one have a four-byte
link/check word before the next header; its checksum algorithm is deliberately
left untouched because extraction does not need to reinterpret it.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys


HEADER = struct.Struct(">IIII")


def safe_name(raw: bytes) -> str:
    name = raw.split(b"\0", 1)[0].decode("ascii")
    if not name or pathlib.PurePath(name).name != name:
        raise ValueError(f"unsafe entry name: {name!r}")
    return name


def records(blob: bytes):
    offset = 0
    index = 0
    while offset + HEADER.size <= len(blob):
        total_size, name_span, data_size, data_check = HEADER.unpack_from(
            blob, offset
        )
        if total_size == 0 or name_span < 8:
            break

        data_offset = offset + 8 + name_span
        end_offset = offset + total_size
        if data_offset + data_size != end_offset or end_offset > len(blob):
            raise ValueError(f"invalid record {index} at 0x{offset:x}")

        name = safe_name(blob[offset + HEADER.size : data_offset])
        yield index, offset, data_offset, end_offset, data_check, name

        index += 1
        if end_offset + 4 + HEADER.size <= len(blob):
            offset = end_offset + 4
        else:
            offset = end_offset


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    blob = args.image.read_bytes()
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)

    count = 0
    for index, header, payload, end, check, name in records(blob):
        size = end - payload
        print(
            f"{index:02d} {name:<16} size={size:9d} "
            f"header=0x{header:08x} payload=0x{payload:08x} check=0x{check:08x}"
        )
        if args.output:
            (args.output / name).write_bytes(blob[payload:end])
        count += 1

    if not count:
        print("no filestruct records found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
