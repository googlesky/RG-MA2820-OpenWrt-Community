#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Add a small integer to a 48-bit MAC address without wrapping."""

from __future__ import annotations

import argparse
import re
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mac")
    parser.add_argument("offset", type=int)
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", args.mac):
        parser.error("MAC must contain six colon-separated hexadecimal octets")
    if not 0 <= args.offset <= 255:
        parser.error("offset must be between 0 and 255")
    value = int(args.mac.replace(":", ""), 16) + args.offset
    if value >= 1 << 48:
        parser.error("addition would wrap the 48-bit address")
    octets = value.to_bytes(6, "big")
    if octets[0] & 1:
        parser.error("result is a multicast MAC address")
    print(":".join(f"{byte:02x}" for byte in octets))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
