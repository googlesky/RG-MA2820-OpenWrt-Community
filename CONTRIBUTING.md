# Contributing

Keep changes small, explain the hardware assumption they rely on, and add a
regression test where practical. Run `./tools/run-source-tests.sh` before
opening a pull request.

Never commit or attach:

- stock/vendor firmware or extracted proprietary binaries;
- MTD/UBI dumps, calibration NVRAM, generated firmware images;
- passwords, private keys, host-specific known-host entries;
- serial numbers, owner SSIDs, or raw UART logs.

Use documentation-range IPs and locally administered `02:` MAC addresses in
tests. Describe on-device results with the board revision, RGOS/kernel version,
and exact test boundary, without claiming broader hardware support.
