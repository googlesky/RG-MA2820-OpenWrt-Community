#!/bin/sh
# Lightweight tests for the physical-reset watcher and peer command router.

set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-tools-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT INT TERM

marker=$temporary/restoredefault
printf '1\000ignored' > "$marker"
RG_MA2820_RESET_FLAG=$marker \
RG_MA2820_FACTORY_RESET=/bin/true \
RG_MA2820_CONSOLE=/dev/null \
	sh "$project_dir/persistent-overlay/usr/libexec/rg-ma2820/reset-watch"
[ ! -e "$marker" ] || {
	echo 'reset watcher did not consume a valid kernel marker' >&2
	exit 1
}

device_env=$temporary/device.env
cat > "$device_env" <<'EOF'
DEVICE_ID='ap3'
HOSTNAME='rg-ma2820-ap3'
RESCUE_LINK_LOCAL='169.254.20.3'
PEER_ID='ap2'
PEER_HOSTNAME='rg-ma2820-ap2'
PEER_LINK_LOCAL='169.254.20.2'
SYSTEM_FORMAT='2'
EOF

peer=$project_dir/persistent-overlay/usr/sbin/rg-ma2820-peer
ssh_home=$temporary/root
known_hosts=$ssh_home/.ssh/known_hosts
mkdir -p "$ssh_home/.ssh"
cat > "$known_hosts" <<'EOF'
169.254.20.2 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
169.254.20.3 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
EOF
[ "$(wc -l < "$known_hosts")" -eq 2 ]
grep -q '^169\.254\.20\.2 ssh-ed25519 ' "$known_hosts"
grep -q '^169\.254\.20\.3 ssh-ed25519 ' "$known_hosts"
if grep -q ',' "$known_hosts"; then
	echo 'Dropbear does not support comma-separated aliases in known_hosts' >&2
	exit 1
fi

status=$(env RG_MA2820_DEVICE_ENV="$device_env" \
	RG_MA2820_PEER_IDENTITY="$temporary/key" \
	RG_MA2820_PEER_SSH_HOME="$ssh_home" \
	RG_MA2820_DBCLIENT=/bin/echo sh "$peer" status)
printf '%s\n' "$status" | grep -q 'root@169.254.20.2'
printf '%s\n' "$status" | grep -q 'StrictHostKeyChecking=yes'

copy=$(env RG_MA2820_DEVICE_ENV="$device_env" \
	RG_MA2820_PEER_IDENTITY="$temporary/key" RG_MA2820_SCP=/bin/echo \
	RG_MA2820_PEER_SSH_HOME="$ssh_home" \
	sh "$peer" copy "$project_dir/tests/test-recovery-tools.sh")
printf '%s\n' "$copy" |
	grep -q 'root@169.254.20.2:/tmp/rg-ma2820-peer-system.squashfs'

upgrade=$(env RG_MA2820_DEVICE_ENV="$device_env" \
	RG_MA2820_PEER_IDENTITY="$temporary/key" \
	RG_MA2820_PEER_SSH_HOME="$ssh_home" \
	RG_MA2820_DBCLIENT=/bin/echo RG_MA2820_SCP=/bin/echo \
	sh "$peer" upgrade \
	"$project_dir/tests/test-recovery-tools.sh" --no-reboot)
printf '%s\n' "$upgrade" | grep -q 'rg-ma2820-system-upgrade'

if env RG_MA2820_DEVICE_ENV="$device_env" \
	RG_MA2820_PEER_IDENTITY="$temporary/key" \
	RG_MA2820_PEER_SSH_HOME="$ssh_home" \
	RG_MA2820_DBCLIENT=/bin/echo \
	sh "$peer" factory-reset >/dev/null 2>&1; then
	echo 'peer factory reset did not require --yes' >&2
	exit 1
fi

# Validate the generic recovery-upgrade identity gate without a UBI volume or
# a writable image: a deliberately wrong SHA256 must stop before any write.
cat > "$device_env" <<'EOF'
DEVICE_ID='node-020000112240'
COMMUNITY_AUTOPROVISION='1'
IMAGE_COMPAT='rg-ma2820t-community-v1'
RESCUE_LINK_LOCAL='169.254.10.20'
FACTORY_ROOT_HASH='test-hash'
FACTORY_SSID_BASE='RG-MA2820-Setup'
FACTORY_WIFI_SECURITY='open'
FACTORY_COUNTRY_CODE='US'
SYSTEM_FORMAT='3'
EOF
printf 'invalid image\n' > "$temporary/invalid-image"
cat > "$temporary/id" <<'EOF'
#!/bin/sh
echo 0
EOF
chmod 0755 "$temporary/id"
recovery_upgrade=$project_dir/persistent-overlay/usr/sbin/rg-ma2820-recovery-upgrade
if RG_MA2820_DEVICE_ENV=$device_env RG_MA2820_ID="$temporary/id" \
	RG_MA2820_RECOVERY_MARKER="$temporary/no-marker" \
	RG_MA2820_RECOVERY_BACKUP="$temporary/no-backup" \
	sh "$recovery_upgrade" "$temporary/invalid-image" \
	"$(printf '%064d' 0)" r38 --yes > "$temporary/recovery-log" 2>&1; then
	echo 'recovery updater accepted an invalid image hash' >&2
	exit 1
fi
grep -q 'input SHA256 does not match' "$temporary/recovery-log"
sed -i 's/node-020000112240/node-a1b2c3/' "$device_env"
if RG_MA2820_DEVICE_ENV=$device_env RG_MA2820_ID="$temporary/id" \
	RG_MA2820_RECOVERY_MARKER="$temporary/no-marker" \
	RG_MA2820_RECOVERY_BACKUP="$temporary/no-backup" \
	sh "$recovery_upgrade" "$temporary/invalid-image" \
	"$(printf '%064d' 0)" r38 --yes > "$temporary/recovery-log" 2>&1; then
	echo 'recovery updater accepted an obsolete six-digit community identity' >&2
	exit 1
fi
grep -q 'invalid community device identity' "$temporary/recovery-log"
[ ! -e "$temporary/no-backup" ]

echo 'recovery tool tests: PASS'
