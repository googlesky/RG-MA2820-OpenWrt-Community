#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Extract an OpenSSH public blob from a Dropbear Ed25519 private host key."""

from __future__ import annotations

import argparse
import base64
import hashlib
import pathlib
import struct
import sys


def read_string(blob: bytes, offset: int) -> tuple[bytes, int]:
    if offset + 4 > len(blob):
        raise ValueError("truncated SSH string length")
    size = struct.unpack_from(">I", blob, offset)[0]
    offset += 4
    end = offset + size
    if end > len(blob):
        raise ValueError("truncated SSH string payload")
    return blob[offset:end], end


def public_blob(path: pathlib.Path) -> bytes:
    private = path.read_bytes()
    algorithm, offset = read_string(private, 0)
    material, offset = read_string(private, offset)
    if offset != len(private):
        raise ValueError("unexpected trailing data in Dropbear key")
    if algorithm != b"ssh-ed25519":
        raise ValueError(f"not a Dropbear Ed25519 key: {algorithm!r}")
    if len(material) != 64:
        raise ValueError(f"unexpected Ed25519 private material size: {len(material)}")
    public = material[-32:]
    return struct.pack(">I", len(algorithm)) + algorithm + struct.pack(">I", 32) + public


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("key", type=pathlib.Path)
    parser.add_argument("--blob", action="store_true", help="print only the base64 blob")
    parser.add_argument("--fingerprint", action="store_true", help="print an SHA256 fingerprint")
    args = parser.parse_args()
    try:
        blob = public_blob(args.key)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    encoded = base64.b64encode(blob).decode("ascii")
    if args.fingerprint:
        digest = base64.b64encode(hashlib.sha256(blob).digest()).decode("ascii").rstrip("=")
        print(f"SHA256:{digest}")
    elif args.blob:
        print(encoded)
    else:
        print(f"ssh-ed25519 {encoded}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
