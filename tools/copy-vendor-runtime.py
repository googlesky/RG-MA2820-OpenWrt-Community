#!/usr/bin/env python3
"""Copy a minimal, isolated glibc runtime for Broadcom WLAN utilities."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess


NEEDED = re.compile(r"Shared library: \[([^]]+)]")


def dependencies(path: pathlib.Path) -> list[str]:
    output = subprocess.check_output(
        ["readelf", "-d", path], text=True, stderr=subprocess.DEVNULL
    )
    return NEEDED.findall(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-root", required=True, type=pathlib.Path)
    parser.add_argument("--target-root", required=True, type=pathlib.Path)
    args = parser.parse_args()

    vendor = args.vendor_root.resolve()
    target = args.target_root.resolve()
    library_dirs = [vendor / "lib", vendor / "usr/lib"]
    binary_paths = [
        vendor / "bin/nvram",
        vendor / "usr/sbin/hostapd",
        vendor / "usr/sbin/hostapd_cli",
        vendor / "usr/sbin/wl",
    ]
    target_bin = target / "opt/bcm/bin"
    target_lib = target / "opt/bcm/lib"
    target_bin.mkdir(parents=True, exist_ok=True)
    target_lib.mkdir(parents=True, exist_ok=True)

    pending: list[str] = []
    for source in binary_paths:
        if not source.is_file():
            raise FileNotFoundError(source)
        shutil.copy2(source, target_bin / source.name)
        pending.extend(dependencies(source))

    loader = vendor / "lib/ld-linux.so.3"
    if not loader.is_file():
        raise FileNotFoundError(loader)
    shutil.copy2(loader, target_lib / loader.name)

    copied: set[str] = set()
    while pending:
        name = pending.pop()
        if name in copied:
            continue
        source = next((d / name for d in library_dirs if (d / name).exists()), None)
        if source is None:
            raise FileNotFoundError(f"unresolved vendor library: {name}")

        copied.add(name)
        real_source = source.resolve(strict=True)
        real_name = real_source.name
        real_target = target_lib / real_name
        if not real_target.exists():
            shutil.copy2(real_source, real_target)
            pending.extend(dependencies(real_source))

        link_target = target_lib / name
        if name != real_name and not link_target.exists():
            os.symlink(real_name, link_target)

    print(f"copied {len(binary_paths)} binaries and {len(copied)} libraries")


if __name__ == "__main__":
    main()
