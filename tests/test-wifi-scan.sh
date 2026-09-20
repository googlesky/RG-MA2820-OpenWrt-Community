#!/usr/bin/env bash
# Verify normalization of Broadcom scan records, including SAE and transition.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
openwrt_host=${RG_TEST_OPENWRT_HOST:-$project_dir/tests/fixtures/host}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-wifi-scan-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

mock_wl=$temporary/wl
cat > "$mock_wl" <<'EOF'
#!/bin/sh
case "$*" in
	*' scanresults') cat <<'RESULTS'
SSID: "SAE network"
Mode: Managed RSSI: -51 dBm SNR: 37 dB noise: -88 dBm Channel: 149/80
BSSID: 02:11:22:33:44:55 Capability: ESS WEP RRM
RSN (WPA3-SAE):
	AKM Suites(2): SAE SAE-FT
Extended Capabilities: BSS_Transition
HE Capable:

SSID: "Transition network"
Mode: Managed RSSI: -63 dBm SNR: 25 dB noise: -88 dBm Channel: 36/80
BSSID: 02:aa:bb:cc:dd:ee Capability: ESS WEP RRM
RSN (WPA2):
	AKM Suites(2): WPA2-PSK SAE
VHT Capable:
RESULTS
		;;
	*' scan') exit 0 ;;
	*) exit 2 ;;
esac
EOF
chmod 0755 "$mock_wl"

result=$(PATH="$openwrt_host/bin:$PATH" \
	RG_MA2820_JSHN="$openwrt_host/share/libubox/jshn.sh" \
	RG_MA2820_WL=$mock_wl RG_MA2820_SCAN_WAIT=0 \
	bash "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-wifi-scan" wl1)

printf '%s' "$result" | jq -e '
	.networks | length == 2 and
	.[0].security == "WPA3-SAE" and .[0].phy == "Wi-Fi 6 (HE)" and
	.[0].rrm == true and .[0].bss_transition == true and
	.[1].security == "WPA2/WPA3" and .[1].phy == "Wi-Fi 5 (VHT)"
' >/dev/null

echo 'Broadcom Wi-Fi scan normalization tests: PASS'
