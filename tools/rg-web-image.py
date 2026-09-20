#!/usr/bin/env python3
"""Build and inspect RG-MA2820(T) EWEB firmware containers.

The stock upgrader consumes a 2048-byte Ruijie header, removes it, and passes
the remaining Broadcom WFI image to libbcm_flashutil.  This tool deliberately
defaults to a pure-UBI WFI payload so a package does not contain or rewrite the
per-device CFE/NVRAM partition.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import zlib


RGOS_HEADER_SIZE = 2048
RGOS_STRUCT_SIZE = 1548
RGOS_MAGIC_1 = 0x12468ACE
RGOS_MAGIC_2 = 0xCE8A4612
WFI_VERSION = 0x5732
WFI_CHIP_ID = 0x47622
WFI_NAND_128K = 3
# The known RG-MA2820B image uses BTRM support plus Broadcom's DDR-type flag.
WFI_FLAGS = 0x6
PEB_SIZE = 128 * 1024

FIELDS = (
    ("name", 12, 128),
    ("target", 140, 128),
    ("license", 268, 128),
    ("version", 396, 128),
    ("release", 524, 128),
    ("build_date", 652, 128),
    ("build_host", 780, 128),
    ("description", 908, 128),
    ("support_list", 1036, 512),
)


def encode_field(value: str, size: int, field: str) -> bytes:
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError(f"{field} must contain ASCII only") from exc
    if b"\0" in encoded or len(encoded) >= size:
        raise ValueError(f"{field} must be shorter than {size} bytes")
    return encoded + bytes(size - len(encoded))


def build_rgos_header(values: dict[str, str]) -> bytes:
    header = bytearray(RGOS_HEADER_SIZE)
    # The third word is present in Ruijie's 1548-byte structure but is not
    # consulted by either get_image_header() or the model/product checks.
    struct.pack_into("<III", header, 0, RGOS_MAGIC_1, RGOS_MAGIC_2, 0)
    for field, offset, size in FIELDS:
        header[offset : offset + size] = encode_field(values[field], size, field)
    return bytes(header)


def wfi_crc32(data: bytes) -> int:
    # Broadcom starts with 0xffffffff and stores the running CRC without the
    # conventional final XOR.  This is the complement of Python's default.
    return zlib.crc32(data) ^ 0xFFFFFFFF


def build_wfi(ubi: bytes, cferom: bytes | None) -> bytes:
    if not ubi.startswith(b"UBI#"):
        raise ValueError("UBI payload does not start with an EC header")
    if len(ubi) % PEB_SIZE:
        raise ValueError("UBI payload size is not aligned to a 128 KiB PEB")
    if cferom is not None and len(cferom) != 1024 * 1024:
        raise ValueError("CFEROM/NVRAM image must be exactly 1 MiB")

    body = (cferom or b"") + ubi
    tail = struct.pack(
        "<IIIII",
        wfi_crc32(body),
        WFI_VERSION,
        WFI_CHIP_ID,
        WFI_NAND_128K,
        WFI_FLAGS,
    )
    return body + tail


def c_string(blob: bytes) -> str:
    return blob.split(b"\0", 1)[0].decode("ascii", errors="replace")


def parse_image(path: pathlib.Path) -> dict[str, object]:
    blob = path.read_bytes()
    payload_offset = 0
    fields: dict[str, str] = {}
    if len(blob) >= RGOS_HEADER_SIZE:
        magic = struct.unpack_from("<II", blob)
        if magic == (RGOS_MAGIC_1, RGOS_MAGIC_2):
            payload_offset = RGOS_HEADER_SIZE
            for field, offset, size in FIELDS:
                fields[field] = c_string(blob[offset : offset + size])

    if len(blob) - payload_offset < 20:
        raise ValueError("image is too short to contain a WFI tail")
    payload = blob[payload_offset:]
    crc, version, chip_id, flash_type, flags = struct.unpack("<IIIII", payload[-20:])
    body = payload[:-20]
    ubi_offset = body.find(b"UBI#")
    return {
        "size": len(blob),
        "payload_offset": payload_offset,
        "fields": fields,
        "wfi_crc": crc,
        "calculated_crc": wfi_crc32(body),
        "version": version,
        "chip_id": chip_id,
        "flash_type": flash_type,
        "flags": flags,
        "ubi_offset": ubi_offset,
        "ubi_size": len(body) - ubi_offset if ubi_offset >= 0 else -1,
    }


def command_build(args: argparse.Namespace) -> int:
    ubi = args.ubi.read_bytes()
    cferom = args.cferom.read_bytes() if args.cferom else None
    values = {
        "name": args.name,
        "target": args.target,
        "license": args.license,
        "version": args.version,
        "release": args.release,
        "build_date": args.build_date,
        "build_host": args.build_host,
        "description": args.description,
        "support_list": args.support_list,
    }
    image = build_rgos_header(values) + build_wfi(ubi, cferom)
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite {args.output}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    print(f"wrote {args.output} ({len(image)} bytes)")
    return command_inspect(argparse.Namespace(image=args.output))


def command_inspect(args: argparse.Namespace) -> int:
    info = parse_image(args.image)
    print(f"file: {args.image}")
    print(f"size: {info['size']}")
    print(f"RGOS header: {'yes' if info['payload_offset'] else 'no'}")
    for field, _, _ in FIELDS:
        if info["fields"]:
            print(f"{field}: {info['fields'][field]}")
    print(f"UBI offset in WFI: 0x{info['ubi_offset']:x}")
    print(f"UBI size: {info['ubi_size']}")
    print(f"WFI version: 0x{info['version']:x}")
    print(f"WFI chip ID: 0x{info['chip_id']:x}")
    print(f"WFI flash type: {info['flash_type']}")
    print(f"WFI flags: 0x{info['flags']:x}")
    print(f"WFI CRC: 0x{info['wfi_crc']:08x}")
    print(f"calculated CRC: 0x{info['calculated_crc']:08x}")

    valid = (
        info["payload_offset"] == RGOS_HEADER_SIZE
        and info["ubi_offset"] in (0, 1024 * 1024)
        and info["ubi_size"] > 0
        and info["wfi_crc"] == info["calculated_crc"]
        and info["version"] == WFI_VERSION
        and info["chip_id"] == WFI_CHIP_ID
        and info["flash_type"] == WFI_NAND_128K
    )
    print(f"structural validation: {'PASS' if valid else 'FAIL'}")
    return 0 if valid else 1


def write_new(path: pathlib.Path, payload: bytes) -> None:
    if path.exists():
        raise FileExistsError(f"refusing to overwrite {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def command_extract(args: argparse.Namespace) -> int:
    blob = args.image.read_bytes()
    info = parse_image(args.image)
    payload = blob[info["payload_offset"] :]
    body = payload[:-20]
    ubi_offset = int(info["ubi_offset"])
    if info["wfi_crc"] != info["calculated_crc"]:
        raise ValueError("WFI CRC does not match")
    if info["chip_id"] != WFI_CHIP_ID or info["flash_type"] != WFI_NAND_128K:
        raise ValueError("image is not for the expected BCM47622/NAND geometry")
    if ubi_offset not in (0, 1024 * 1024):
        raise ValueError(f"unexpected UBI offset: {ubi_offset}")
    ubi = body[ubi_offset:]
    if not ubi.startswith(b"UBI#") or len(ubi) % PEB_SIZE:
        raise ValueError("extracted UBI payload is malformed")
    if args.cferom_output and ubi_offset != 1024 * 1024:
        raise ValueError("input image has no 1 MiB CFEROM prefix")
    for output in (args.ubi_output, args.cferom_output):
        if output is not None and output.exists():
            raise FileExistsError(f"refusing to overwrite {output}")
    write_new(args.ubi_output, ubi)
    print(f"wrote {args.ubi_output} ({len(ubi)} bytes)")
    if args.cferom_output:
        write_new(args.cferom_output, body[:ubi_offset])
        print(f"wrote {args.cferom_output} ({ubi_offset} bytes)")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__)
    sub = top.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="build an RGOS .bin around a pure UBI WFI")
    build.add_argument("--ubi", required=True, type=pathlib.Path)
    build.add_argument("--output", required=True, type=pathlib.Path)
    build.add_argument("--cferom", type=pathlib.Path)
    build.add_argument("--name", default="Main")
    build.add_argument("--target", default="qishan-ctc-main")
    build.add_argument("--license", default="Ruijie")
    build.add_argument("--version", default="OpenWrt")
    build.add_argument("--release", default="experimental")
    build.add_argument("--build-date", default="2026/09/17 00:00:00")
    build.add_argument("--build-host", default="codex-rg-ma2820")
    build.add_argument(
        "--description", default="OpenWrt hybrid using the stock RGOS kernel"
    )
    build.add_argument("--support-list", default="sup_list=0x301B0011;")
    build.set_defaults(func=command_build)

    inspect = sub.add_parser("inspect", help="inspect and validate an image")
    inspect.add_argument("image", type=pathlib.Path)
    inspect.set_defaults(func=command_inspect)

    extract = sub.add_parser("extract", help="verify WFI and extract its UBI payload")
    extract.add_argument("image", type=pathlib.Path)
    extract.add_argument("--ubi-output", required=True, type=pathlib.Path)
    extract.add_argument("--cferom-output", type=pathlib.Path)
    extract.set_defaults(func=command_extract)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, struct.error) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
