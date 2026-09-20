#!/usr/bin/env python3
"""Build an RG-MA2820(T) immutable-recovery plus A/B-system UBI image."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


PEB_SIZE = 131072
LEB_SIZE = 126976
MIN_IO_SIZE = 2048
IMAGE_SEQUENCE = 624117603

# Preserve the stock total of 725 reserved LEBs.  The kernel-facing recovery
# root keeps volume ID 0; application roots are independently replaceable.
RECOVERY_LEBS = 256
SYSTEM_LEBS = 128
OVERLAY_LEBS = 186
METADATA_LEBS = 1
BOOTSTATE_LEBS = 1
FILESTRUCT_LEBS = 24
TOTAL_VOLUME_LEBS = (
    RECOVERY_LEBS
    + 2 * SYSTEM_LEBS
    + OVERLAY_LEBS
    + 2 * METADATA_LEBS
    + BOOTSTATE_LEBS
    + FILESTRUCT_LEBS
)
LAYOUT_VOLUME_ID = 0x7FFFEFFF
VTBL_RECORD_SIZE = 172


def require_image(path: pathlib.Path, maximum: int, label: str) -> None:
    if not path.is_file():
        raise ValueError(f"{label} image does not exist: {path}")
    size = path.stat().st_size
    if not 0 < size <= maximum:
        raise ValueError(f"{label} size {size} exceeds allocation {maximum}")


def section(
    name: str,
    volume_id: int,
    volume_name: str,
    volume_type: str,
    volume_lebs: int,
    image: pathlib.Path | None = None,
) -> str:
    lines = [
        f"[{name}]",
        "mode=ubi",
        f"vol_id={volume_id}",
        f"vol_type={volume_type}",
        f"vol_name={volume_name}",
        f"vol_size={volume_lebs * LEB_SIZE}",
    ]
    if image is not None:
        lines.insert(2, f"image={image}")
    return "\n".join(lines) + "\n"


def bootstate(active: str) -> bytes:
    payload = (
        "format=1\n"
        "generation=0\n"
        f"active={active}\n"
        "pending=none\n"
        "booting=none\n"
        "force_recovery=0\n"
        "last_result=factory\n"
    ).encode("ascii")
    checksum = hashlib.sha256(payload).hexdigest().encode("ascii")
    return payload + b"checksum=" + checksum + b"\n"


def ubi_crc(data: bytes) -> int:
    return zlib.crc32(data) ^ 0xFFFFFFFF


def verify_output(args: argparse.Namespace, expected_state: bytes) -> None:
    blob = args.output.read_bytes()
    volumes: dict[int, list[tuple[int, int, bytes]]] = {}
    tables: list[bytes] = []
    for peb_number, offset in enumerate(range(0, len(blob), PEB_SIZE)):
        peb = blob[offset : offset + PEB_SIZE]
        if peb[:4] != b"UBI#":
            raise ValueError(f"PEB {peb_number} lacks an EC header")
        if struct.unpack_from(">I", peb, 60)[0] != ubi_crc(peb[:60]):
            raise ValueError(f"PEB {peb_number} has a bad EC-header CRC")
        vid_offset, data_offset = struct.unpack_from(">II", peb, 16)
        vid = peb[vid_offset : vid_offset + 64]
        if vid[:4] != b"UBI!":
            raise ValueError(f"PEB {peb_number} lacks a VID header")
        if struct.unpack_from(">I", vid, 60)[0] != ubi_crc(vid[:60]):
            raise ValueError(f"PEB {peb_number} has a bad VID-header CRC")
        volume_id, lnum = struct.unpack_from(">II", vid, 8)
        volume_type = vid[5]
        data_size = struct.unpack_from(">I", vid, 20)[0]
        data = peb[data_offset:]
        volumes.setdefault(volume_id, []).append((lnum, data_size, data))
        if volume_id == LAYOUT_VOLUME_ID:
            tables.append(data)
        if volume_type == 2:
            stored_crc = struct.unpack_from(">I", vid, 32)[0]
            if stored_crc != ubi_crc(data[:data_size]):
                raise ValueError(f"static volume {volume_id} LEB {lnum} has bad data CRC")

    if len(tables) != 2 or tables[0] != tables[1]:
        raise ValueError("UBI layout-volume copies are missing or different")
    expected_table = {
        0: (RECOVERY_LEBS, 1, "rootfs_ubifs"),
        1: (METADATA_LEBS, 1, "METADATA"),
        2: (METADATA_LEBS, 1, "METADATACOPY"),
        3: (OVERLAY_LEBS, 1, "rootfs_data"),
        4: (SYSTEM_LEBS, 1, "system_a"),
        5: (SYSTEM_LEBS, 1, "system_b"),
        6: (BOOTSTATE_LEBS, 1, "bootstate"),
        10: (FILESTRUCT_LEBS, 2, "filestruct_full.bin"),
    }
    observed_table: dict[int, tuple[int, int, str]] = {}
    for volume_id in range(128):
        record = tables[0][
            volume_id * VTBL_RECORD_SIZE : (volume_id + 1) * VTBL_RECORD_SIZE
        ]
        reserved = struct.unpack_from(">I", record)[0]
        if not reserved:
            continue
        if struct.unpack_from(">I", record, 168)[0] != ubi_crc(record[:168]):
            raise ValueError(f"volume-table record {volume_id} has a bad CRC")
        volume_type = record[12]
        name_length = struct.unpack_from(">H", record, 14)[0]
        name = record[16 : 16 + name_length].decode("ascii")
        observed_table[volume_id] = (reserved, volume_type, name)
    if observed_table != expected_table:
        raise ValueError(f"unexpected volume table: {observed_table}")

    expected_images: dict[int, bytes] = {
        0: args.recovery.read_bytes(),
        1: args.metadata.read_bytes(),
        2: args.metadata_copy.read_bytes(),
        4: args.system_a.read_bytes(),
        6: expected_state,
        10: args.filestruct.read_bytes(),
    }
    if args.system_b:
        expected_images[5] = args.system_b.read_bytes()
    unexpected = set(volumes) - set(expected_images) - {LAYOUT_VOLUME_ID}
    if unexpected:
        raise ValueError(f"unexpected populated volumes: {sorted(unexpected)}")
    for volume_id, expected in expected_images.items():
        entries = sorted(volumes.get(volume_id, []))
        if [entry[0] for entry in entries] != list(range(len(entries))):
            raise ValueError(f"volume {volume_id} has non-contiguous LEB numbers")
        if volume_id == 10:
            actual = b"".join(data[:data_size] for _, data_size, data in entries)
        else:
            actual = b"".join(data for _, _, data in entries)
        if actual[: len(expected)] != expected:
            raise ValueError(f"volume {volume_id} does not reproduce its input image")
        if volume_id != 10 and any(byte != 0xFF for byte in actual[len(expected) :]):
            raise ValueError(f"volume {volume_id} has non-erased trailing data")
    print("embedded UBI volume table, CRCs, and input images: PASS")


def command_build(args: argparse.Namespace) -> int:
    if TOTAL_VOLUME_LEBS != 725:
        raise AssertionError("volume allocation no longer matches stock")
    require_image(args.recovery, RECOVERY_LEBS * LEB_SIZE, "recovery")
    require_image(args.system_a, SYSTEM_LEBS * LEB_SIZE, "system A")
    if args.system_b is not None:
        require_image(args.system_b, SYSTEM_LEBS * LEB_SIZE, "system B")
    if args.active == "b" and args.system_b is None:
        raise ValueError("active slot B requires --system-b")
    require_image(args.metadata, LEB_SIZE, "METADATA")
    require_image(args.metadata_copy, LEB_SIZE, "METADATACOPY")
    require_image(args.filestruct, FILESTRUCT_LEBS * LEB_SIZE, "filestruct")
    if args.metadata.read_bytes() != args.metadata_copy.read_bytes():
        raise ValueError("stock METADATA and METADATACOPY payloads differ")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite {args.output}")
    if not args.ubinize.is_file():
        raise FileNotFoundError(args.ubinize)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rg-ma2820-ab-ubinize-") as temp_dir:
        temporary = pathlib.Path(temp_dir)
        state_path = temporary / "bootstate.txt"
        initial_state = bootstate(args.active)
        state_path.write_bytes(initial_state)
        config = "\n".join(
            (
                section(
                    "recovery",
                    0,
                    "rootfs_ubifs",
                    "dynamic",
                    RECOVERY_LEBS,
                    args.recovery.resolve(),
                ),
                section(
                    "metadata",
                    1,
                    "METADATA",
                    "dynamic",
                    METADATA_LEBS,
                    args.metadata.resolve(),
                ),
                section(
                    "metadata_copy",
                    2,
                    "METADATACOPY",
                    "dynamic",
                    METADATA_LEBS,
                    args.metadata_copy.resolve(),
                ),
                section("overlay", 3, "rootfs_data", "dynamic", OVERLAY_LEBS),
                section(
                    "system_a",
                    4,
                    "system_a",
                    "dynamic",
                    SYSTEM_LEBS,
                    args.system_a.resolve(),
                ),
                section(
                    "system_b",
                    5,
                    "system_b",
                    "dynamic",
                    SYSTEM_LEBS,
                    args.system_b.resolve() if args.system_b else None,
                ),
                section(
                    "bootstate",
                    6,
                    "bootstate",
                    "dynamic",
                    BOOTSTATE_LEBS,
                    state_path,
                ),
                section(
                    "filestruct",
                    10,
                    "filestruct_full.bin",
                    "static",
                    FILESTRUCT_LEBS,
                    args.filestruct.resolve(),
                ),
            )
        )
        config_path = temporary / "ubinize.ini"
        config_path.write_text(config, encoding="ascii")
        subprocess.run(
            [
                str(args.ubinize),
                "-o",
                str(args.output),
                "-p",
                str(PEB_SIZE),
                "-m",
                str(MIN_IO_SIZE),
                "-s",
                str(MIN_IO_SIZE),
                "-O",
                str(MIN_IO_SIZE),
                "-Q",
                str(IMAGE_SEQUENCE),
                str(config_path),
            ],
            check=True,
        )

    blob = args.output.read_bytes()
    if not blob.startswith(b"UBI#") or len(blob) % PEB_SIZE:
        raise ValueError("ubinize produced a malformed or unaligned image")
    vid_offset, data_offset, sequence = struct.unpack_from(">III", blob, 16)
    if (vid_offset, data_offset, sequence) != (
        MIN_IO_SIZE,
        2 * MIN_IO_SIZE,
        IMAGE_SEQUENCE,
    ):
        raise ValueError("unexpected UBI EC-header geometry")
    verify_output(args, initial_state)
    print(f"wrote {args.output} ({len(blob)} bytes, {len(blob) // PEB_SIZE} PEBs)")
    print(
        "volume allocation: "
        f"recovery={RECOVERY_LEBS}, system_a={SYSTEM_LEBS}, "
        f"system_b={SYSTEM_LEBS}, overlay={OVERLAY_LEBS}, metadata=2, "
        f"bootstate={BOOTSTATE_LEBS}, filestruct={FILESTRUCT_LEBS}, "
        f"total={TOTAL_VOLUME_LEBS} LEBs"
    )
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__)
    top.add_argument("--recovery", required=True, type=pathlib.Path)
    top.add_argument("--system-a", required=True, type=pathlib.Path)
    top.add_argument("--system-b", type=pathlib.Path)
    top.add_argument("--active", choices=("a", "b"), default="a")
    top.add_argument("--metadata", required=True, type=pathlib.Path)
    top.add_argument("--metadata-copy", required=True, type=pathlib.Path)
    top.add_argument("--filestruct", required=True, type=pathlib.Path)
    top.add_argument("--output", required=True, type=pathlib.Path)
    top.add_argument(
        "--ubinize",
        type=pathlib.Path,
        default=pathlib.Path("openwrt/staging_dir/host/bin/ubinize"),
    )
    top.set_defaults(func=command_build)
    return top


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
