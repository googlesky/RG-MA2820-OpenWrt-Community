#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT

make_state() {
	local root=$1 marker=$2
	mkdir -p "$root/etc/rg-ma2820" "$root/etc/dropbear"
	printf 'boardnum=6755\nmarker=%s\n' "$marker" > "$root/etc/rg-ma2820/kernel_nvram.setting"
	printf 'rsa-%s\n' "$marker" > "$root/etc/dropbear/dropbear_rsa_host_key"
	printf 'ecdsa-%s\n' "$marker" > "$root/etc/dropbear/dropbear_ecdsa_host_key"
	python3 - "$root/etc/dropbear/dropbear_ed25519_host_key" "$marker" <<'PY'
import pathlib, struct, sys
algorithm = b"ssh-ed25519"
seed = bytes([int(sys.argv[2])]) * 32
public = bytes([int(sys.argv[2]) + 16]) * 32
blob = struct.pack(">I", len(algorithm)) + algorithm
blob += struct.pack(">I", 64) + seed + public
pathlib.Path(sys.argv[1]).write_bytes(blob)
PY
}

make_state "$temporary/ap2" 2
make_state "$temporary/ap3" 3
cp "$project_dir/config/pair.example.env" "$temporary/pair.env"

output=$("$project_dir/tools/build-pair-release.sh" --check \
	"$temporary/pair.env" "$temporary/ap2" "$temporary/ap3")
grep -qx 'pair profile: PASS' <<<"$output"
grep -Eq '^AP2 SHA256:[A-Za-z0-9+/]+$' <<<"$output"
grep -Eq '^AP3 SHA256:[A-Za-z0-9+/]+$' <<<"$output"

sed 's/AP3_BSSID_2G=.*/AP3_BSSID_2G=02:00:00:00:02:20/' \
	"$temporary/pair.env" > "$temporary/bad.env"
if "$project_dir/tools/build-pair-release.sh" --check \
	"$temporary/bad.env" "$temporary/ap2" "$temporary/ap3" >/dev/null 2>&1; then
	echo 'duplicate BSSID profile unexpectedly passed' >&2
	exit 1
fi

echo 'community profile tests: PASS'
