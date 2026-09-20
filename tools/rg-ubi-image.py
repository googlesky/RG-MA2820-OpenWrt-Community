#!/usr/bin/env python3
"""Build the RG-MA2820(T) UBI payload without touching CFE or factory data."""

from __future__ import annotations

import argparse
import pathlib
import struct
import subprocess
import sys
import tempfile


PEB_SIZE = 131072
LEB_SIZE = 126976
MIN_IO_SIZE = 2048
IMAGE_SEQUENCE = 624117603

# Keep the stock allocation total (725 LEBs).  This leaves the same four UBI
# bookkeeping PEBs and 79 bad-block reserve PEBs on the 808-PEB partition.
ROOTFS_LEBS = 256
OVERLAY_LEBS = 443
METADATA_LEBS = 1
FILESTRUCT_LEBS = 24
TOTAL_VOLUME_LEBS = (
    ROOTFS_LEBS + OVERLAY_LEBS + 2 * METADATA_LEBS + FILESTRUCT_LEBS
)


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


def command_build(args: argparse.Namespace) -> int:
    if TOTAL_VOLUME_LEBS != 725:
        raise AssertionError("volume allocation no longer matches stock")
    require_image(args.rootfs, ROOTFS_LEBS * LEB_SIZE, "rootfs")
    require_image(args.metadata, LEB_SIZE, "METADATA")
    require_image(args.metadata_copy, LEB_SIZE, "METADATACOPY")
    require_image(args.filestruct, FILESTRUCT_LEBS * LEB_SIZE, "filestruct")
    if args.metadata.read_bytes() != args.metadata_copy.read_bytes():
        raise ValueError("stock METADATA and METADATACOPY payloads differ")
    if args.output.exists():
        raise FileExistsError(f"refusing to overwrite {args.output}")
    if not args.ubinize.is_file():
        raise FileNotFoundError(args.ubinize)

    config = "\n".join(
        (
            section(
                "rootfs",
                0,
                "rootfs_ubifs",
                "dynamic",
                ROOTFS_LEBS,
                args.rootfs.resolve(),
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
                "filestruct",
                10,
                "filestruct_full.bin",
                "static",
                FILESTRUCT_LEBS,
                args.filestruct.resolve(),
            ),
        )
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rg-ma2820-ubinize-") as temp_dir:
        config_path = pathlib.Path(temp_dir) / "ubinize.ini"
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
    print(f"wrote {args.output} ({len(blob)} bytes, {len(blob) // PEB_SIZE} PEBs)")
    print(
        f"volume allocation: rootfs={ROOTFS_LEBS}, overlay={OVERLAY_LEBS}, "
        f"metadata=2, filestruct={FILESTRUCT_LEBS}, total={TOTAL_VOLUME_LEBS} LEBs"
    )
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__)
    top.add_argument("--rootfs", required=True, type=pathlib.Path)
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
