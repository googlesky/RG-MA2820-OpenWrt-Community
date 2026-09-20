#!/usr/bin/env bash
# Verify that a new A/B slot replaces stale managed files in the saved overlay.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-overlay-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

rom=$temporary/rom
target=$temporary/target
mkdir -p "$rom/usr/sbin" "$target/usr/sbin"
printf 'new release\n' > "$rom/usr/sbin/rg-ma2820-wifi-status"
printf 'stale overlay\n' > "$target/usr/sbin/rg-ma2820-wifi-status"
chmod 0600 "$target/usr/sbin/rg-ma2820-wifi-status"

RG_MA2820_ROM_ROOT=$rom RG_MA2820_SYNC_ROOT=$target \
	NETWORK_LAYOUT="$project_dir/persistent-overlay/etc/init.d/rg-ma2820-network-layout" \
	sh -c '. "$NETWORK_LAYOUT"; sync_release_file /usr/sbin/rg-ma2820-wifi-status 0755 test'

cmp "$rom/usr/sbin/rg-ma2820-wifi-status" \
	"$target/usr/sbin/rg-ma2820-wifi-status"
[ "$(stat -c '%a' "$target/usr/sbin/rg-ma2820-wifi-status")" = 755 ]

layout=$project_dir/persistent-overlay/etc/init.d/rg-ma2820-network-layout
for required in \
	/etc/init.d/rg-ma2820-network-layout \
	/usr/sbin/rg-ma2820-recovery-upgrade \
	/usr/sbin/rg-ma2820-overview-status \
	/usr/sbin/rg-ma2820-set-wifi \
	/usr/sbin/rg-ma2820-wifi-capabilities \
	/usr/sbin/rg-ma2820-wifi-scan \
	/usr/sbin/rg-ma2820-wifi-status \
	/usr/libexec/rg-ma2820/led-traffic \
	/usr/lib/lua/luci/i18n/base.vi.lmo \
	/usr/lib/lua/luci/i18n/rg-ma2820.vi.lmo \
	/usr/share/rpcd/ucode/rg-ma2820.uc \
	/www/luci-static/resources/view/rg-ma2820/wireless.js \
	/www/luci-static/resources/view/status/index.js; do
	grep -Fq "$required|" "$layout"
done

echo 'A/B overlay migration test: PASS'
