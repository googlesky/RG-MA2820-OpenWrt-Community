#!/usr/bin/env bash
# Verify that one generic image derives independent state for any number of APs.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
provision=$project_dir/community-overlay/etc/init.d/rg-ma2820-provision
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-provision-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

cat > "$temporary/dropbearkey" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
	[ "$1" != -f ] || { output=$2; shift; }
	shift
done
[ -n "$output" ] || exit 2
printf 'unique-test-key:%s\n' "$output" > "$output"
printf 'public-test-key:%s\n' "$output" > "$output.pub"
EOF
chmod 0755 "$temporary/dropbearkey"

# The device BusyBox has sha256sum but no cksum. A cksum dependency must
# make this test fail even when the build host provides that command.
mkdir -p "$temporary/bin"
cat > "$temporary/bin/cksum" <<'EOF'
#!/bin/sh
exit 127
EOF
chmod 0755 "$temporary/bin/cksum"

make_calibration() {
	local path=$1 ethernet=$2 radio2=$3 radio5=$4
	{
		printf 'boardnum=6755\nboardtype=0x08a9\n'
		printf 'et0macaddr=%s\nsb/0/macaddr=%s\nsb/1/macaddr=%s\n' \
			"$ethernet" "$radio2" "$radio5"
		yes '# padding' | head -n 600 || true
	} > "$path"
}

run_node() {
	local name=$1 ethernet=$2 radio2=$3 radio5=$4 root
	root=$temporary/$name
	mkdir -p "$root/etc/rg-ma2820"
	cp "$project_dir/community-overlay/etc/rg-ma2820/device.env" \
		"$root/etc/rg-ma2820/device.env"
	cp "$project_dir/community-overlay/etc/rg-ma2820/cluster.env" \
		"$root/etc/rg-ma2820/cluster.env"
	sed -i \
		-e "s#@FACTORY_ROOT_HASH@#test-hash#" \
		-e "s/@FACTORY_SSID_BASE@/RG-MA2820-Setup/" \
		-e "s/@FACTORY_WIFI_SECURITY@/open/" \
		-e "s/@FACTORY_COUNTRY_CODE@/US/" \
		"$root/etc/rg-ma2820/device.env"
	printf 'test-release\n' > "$root/etc/rg-ma2820/release"
	make_calibration "$root/factory-nvram" "$ethernet" "$radio2" "$radio5"
	: > "$root/hostname"

	PATH="$temporary/bin:$PATH" \
	RG_MA2820_ETC_ROOT="$root/etc" \
	RG_MA2820_DATA_SOURCE="$root/factory-nvram" \
	RG_MA2820_UMDNS_DIR="$root/etc/umdns" \
	RG_MA2820_DROPBEAR_DIR="$root/etc/dropbear" \
	RG_MA2820_DROPBEARKEY="$temporary/dropbearkey" \
	RG_MA2820_HOSTNAME_FILE="$root/hostname" \
	RG_MA2820_LOG_CONSOLE=/dev/null \
	RG_MA2820_RELEASE_FILE="$root/etc/rg-ma2820/release" \
	RG_MA2820_PROVISION_MARKER="$root/etc/rg-ma2820/provisioned" \
	PROVISION="$provision" sh -c '. "$PROVISION"; start'
}

shared_ethernet=00:90:4c:32:4a:11
# Both observed RG-MA2820(T) units have this same Broadcom placeholder in
# factory data. Identity must instead follow each radio's unique MAC.
run_node first "$shared_ethernet" 02:00:00:11:22:40 02:00:00:11:22:50
run_node second "$shared_ethernet" 02:00:00:44:55:70 02:00:00:44:55:80
run_node third "$shared_ethernet" 02:00:00:77:88:a0 02:00:00:77:88:b0

for spec in 'first 020000112240 02:00:00:11:22:51' \
	'second 020000445570 02:00:00:44:55:81' \
	'third 0200007788a0 02:00:00:77:88:b1'; do
	set -- $spec
	root=$temporary/$1
	grep -qx "DEVICE_ID='node-$2'" "$root/etc/rg-ma2820/device.env"
	grep -qx "HOSTNAME='rg-ma2820-$2'" "$root/etc/rg-ma2820/device.env"
	grep -qx "LOCAL_BSSID_5G_LEGACY='$3'" "$root/etc/rg-ma2820/device.env"
	grep -qx "IMAGE_COMPAT='rg-ma2820t-community-v1'" "$root/etc/rg-ma2820/device.env"
	grep -q "node=node-$2" "$root/etc/umdns/rg-ma2820.json"
	[ -s "$root/etc/rg-ma2820/kernel_nvram.setting" ]
	[ -e "$root/etc/rg-ma2820/provisioned" ]
	for type in rsa ecdsa ed25519; do
		[ -s "$root/etc/dropbear/dropbear_${type}_host_key" ]
		[ ! -e "$root/etc/dropbear/dropbear_${type}_host_key.new.pub" ]
	done
done

# No device runtime may depend on cksum: the target BusyBox does not include
# it, and an empty shell-arithmetic fallback would synchronize every node.
if grep -R -n -w cksum "$project_dir/community-overlay" \
	"$project_dir/persistent-overlay" "$project_dir/hybrid-overlay"; then
	echo 'target runtime still calls unavailable cksum' >&2
	exit 1
fi

identities=$(sed -n "s/^DEVICE_ID='\([^']*\)'/\1/p" \
	"$temporary"/*/etc/rg-ma2820/device.env | sort -u | wc -l)
addresses=$(sed -n "s/^RESCUE_LINK_LOCAL='\([^']*\)'/\1/p" \
	"$temporary"/*/etc/rg-ma2820/device.env | sort -u | wc -l)
[ "$identities" -eq 3 ]
[ "$addresses" -eq 3 ]

before=$(sha256sum "$temporary/first/etc/dropbear"/* | sha256sum)
run_node first "$shared_ethernet" 02:00:00:11:22:40 02:00:00:11:22:50
after=$(sha256sum "$temporary/first/etc/dropbear"/* | sha256sum)
[ "$before" = "$after" ]

cp "$temporary/first/factory-nvram" "$temporary/invalid-board"
sed -i 's/^boardnum=6755$/boardnum=0/' "$temporary/invalid-board"
if RG_MA2820_DATA_SOURCE="$temporary/invalid-board" \
	RG_MA2820_LOG_CONSOLE=/dev/null PROVISION="$provision" \
	sh -c '. "$PROVISION"; validate_calibration' >/dev/null 2>&1; then
	echo 'invalid factory board number was accepted' >&2
	exit 1
fi

echo 'generic three-node identity, calibration and host-key provisioning tests: PASS'
