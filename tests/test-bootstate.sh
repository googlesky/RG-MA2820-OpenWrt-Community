#!/usr/bin/env bash
# Exercise the shell state machine without requiring a live UBI device.
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
bootstate="$project_dir/persistent-overlay/usr/libexec/rg-ma2820/bootstate"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-bootstate-test.XXXXXXXX")
state_file="$work_dir/state"
mock_bin="$work_dir/bin"
trap 'rm -rf -- "$work_dir" /tmp/rg-ma2820-bootstate.lock' EXIT
mkdir -p "$mock_bin"

cat > "$mock_bin/dd" <<'EOF'
#!/bin/sh
for argument in "$@"; do
	case "$argument" in
		of=*) output=${argument#of=} ;;
	esac
done
cp "$RG_MA2820_TEST_STATE" "$output"
EOF
cat > "$mock_bin/ubiupdatevol" <<'EOF'
#!/bin/sh
cp "$2" "$RG_MA2820_TEST_STATE"
EOF
chmod 0755 "$mock_bin/dd" "$mock_bin/ubiupdatevol"

write_initial_state() {
	cat > "$work_dir/payload" <<'EOF'
format=1
generation=0
active=a
pending=none
booting=none
force_recovery=0
last_result=factory
EOF
	{
		cat "$work_dir/payload"
		printf 'checksum=%s\n' "$(sha256sum "$work_dir/payload" | cut -d' ' -f1)"
	} > "$state_file"
}

run_state() {
	PATH="$mock_bin:$PATH" \
	RG_MA2820_STATE_DEV=/dev/null \
	RG_MA2820_TEST_STATE="$state_file" \
		"$bootstate" "$@"
}

assert_field() {
	local field=$1 expected=$2 actual
	actual=$(run_state status | sed -n "s/^${field}=//p")
	[ "$actual" = "$expected" ] || {
		echo "expected $field=$expected, got $actual" >&2
		exit 1
	}
}

write_initial_state
[ "$(run_state prepare)" = a ]
run_state accept a
assert_field active a
assert_field booting none

run_state stage b
[ "$(run_state prepare)" = b ]
# No acceptance simulates a failed trial boot. The next prepare must atomically
# reject B and start accepted slot A in the same physical boot.
[ "$(run_state prepare)" = a ]
assert_field active a
assert_field pending none
assert_field booting a
assert_field last_result booting
run_state accept a

run_state stage b
[ "$(run_state prepare)" = b ]
run_state accept b
assert_field active b
assert_field pending none

# An accepted slot that fails before the health gate must enter recovery rather
# than loop forever or overwrite its only known-good alternative.
[ "$(run_state prepare)" = b ]
if run_state prepare >/dev/null 2>&1; then
	echo "active-slot failure unexpectedly selected another system" >&2
	exit 1
fi
assert_field force_recovery 1
assert_field last_result active-failed
run_state retry
assert_field force_recovery 0

if run_state stage b >/dev/null 2>&1; then
	echo "state machine allowed overwrite of active slot B" >&2
	exit 1
fi

# Any torn or corrupted state is rejected before a system slot is selected.
sed -i 's/^generation=.*/generation=999/' "$state_file"
if run_state status >/dev/null 2>&1; then
	echo "corrupt bootstate checksum was accepted" >&2
	exit 1
fi

echo "bootstate A/B rollback and corruption tests: PASS"
