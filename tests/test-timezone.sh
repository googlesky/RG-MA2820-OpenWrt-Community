#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
helper="$repo_root/persistent-overlay/usr/sbin/rg-ma2820-timezone"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT INT TERM

state_dir="$work_dir/state"
mkdir -p "$state_dir"
printf '%s\n' UTC >"$state_dir/zonename"
printf '%s\n' GMT0 >"$state_dir/timezone"
printf '%s\n' 1 >"$state_dir/timezone_auto"
printf '%s\n' 0 >"$state_dir/timezone_detected"

cat >"$work_dir/uci" <<'EOF'
#!/bin/sh
set -eu
state_dir=${TEST_STATE_DIR:?}
[ "${1:-}" = -q ] && shift
command=${1:-}
shift || true
case "$command" in
	get)
		option=${1##*.}
		[ -f "$state_dir/$option" ] || exit 1
		cat "$state_dir/$option"
		;;
	set)
		assignment=${1:?}
		key=${assignment%%=*}
		value=${assignment#*=}
		option=${key##*.}
		printf '%s\n' "$value" >"$state_dir/$option"
		;;
	commit)
		if [ -f "$state_dir/fail_commit_once" ]; then
			rm -f "$state_dir/fail_commit_once"
			exit 1
		fi
		;;
	*) exit 2 ;;
esac
EOF

cat >"$work_dir/zoneinfo.uc" <<'EOF'
export default {
	'Asia/Ho_Chi_Minh': '<+07>-7',
	'Europe/London': 'GMT0BST,M3.5.0/1,M10.5.0',
};
EOF

cat >"$work_dir/system-init" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = reload ] || exit 2
if [ -f "${TEST_STATE_DIR:?}/fail_reload_once" ]; then
	rm -f "$TEST_STATE_DIR/fail_reload_once"
	exit 1
fi
EOF

cat >"$work_dir/peer" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"${TEST_STATE_DIR:?}/peer.log"
printf '%s\n' peer >>"$TEST_STATE_DIR/sequence.log"
[ ! -f "$TEST_STATE_DIR/fail_peer" ]
EOF

cat >"$work_dir/lock" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] || printf '%s\n' lock >>"${TEST_STATE_DIR:?}/sequence.log"
exit 0
EOF

chmod +x "$work_dir/uci" "$work_dir/system-init" "$work_dir/peer" "$work_dir/lock"

run_helper()
{
	TEST_STATE_DIR="$state_dir" \
	RG_MA2820_UCI="$work_dir/uci" \
	RG_MA2820_ZONEINFO="$work_dir/zoneinfo.uc" \
	RG_MA2820_SYSTEM_INIT="$work_dir/system-init" \
	RG_MA2820_PEER="$work_dir/peer" \
	RG_MA2820_LOCK="$work_dir/lock" \
	RG_MA2820_TIMEZONE_LOCK="$work_dir/timezone.lock" \
	RG_MA2820_SKIP_TZ_VERIFY=1 \
		"$helper" "$@"
}

assert_value()
{
	actual="$(cat "$state_dir/$1")"
	[ "$actual" = "$2" ] || {
		echo "$1: expected '$2', got '$actual'" >&2
		exit 1
	}
}

status="$(run_helper status)"
printf '%s\n' "$status" | grep -q '"zonename": "UTC"'
printf '%s\n' "$status" | grep -q '"automatic": true'
printf '%s\n' "$status" | grep -q '"initialized": false'

run_helper --validate Asia/Ho_Chi_Minh true
assert_value zonename UTC
if run_helper --validate '../etc/passwd' true >/dev/null 2>&1; then
	echo 'invalid timezone passed validation' >&2
	exit 1
fi
if run_helper --validate Asia/Ho_Chi_Minh maybe >/dev/null 2>&1; then
	echo 'invalid automatic flag passed validation' >&2
	exit 1
fi

if run_helper --configure '../etc/passwd' 1 local >/dev/null 2>&1; then
	echo 'invalid timezone was accepted' >&2
	exit 1
fi
assert_value zonename UTC

run_helper --configure Asia/Ho_Chi_Minh true local >/dev/null
assert_value zonename Asia/Ho_Chi_Minh
assert_value timezone '<+07>-7'
assert_value timezone_auto 1
assert_value timezone_detected 1

: >"$state_dir/sequence.log"
run_helper --configure Europe/London false pair >/dev/null
assert_value zonename Europe/London
assert_value timezone 'GMT0BST,M3.5.0/1,M10.5.0'
assert_value timezone_auto 0
grep -q -- '-- /usr/sbin/rg-ma2820-timezone --configure Europe/London 0 local' \
	"$state_dir/peer.log"
[ "$(sed -n '1p' "$state_dir/sequence.log")" = peer ]
[ "$(sed -n '2p' "$state_dir/sequence.log")" = lock ]

touch "$state_dir/fail_peer"
if run_helper --configure Asia/Ho_Chi_Minh true pair >/dev/null 2>&1; then
	echo 'peer failure was ignored' >&2
	exit 1
fi
rm -f "$state_dir/fail_peer"
assert_value zonename Europe/London
assert_value timezone_auto 0

touch "$state_dir/fail_reload_once"
if run_helper --configure Asia/Ho_Chi_Minh true local >/dev/null 2>&1; then
	echo 'system reload failure was ignored' >&2
	exit 1
fi
assert_value zonename Europe/London
assert_value timezone 'GMT0BST,M3.5.0/1,M10.5.0'
assert_value timezone_auto 0
assert_value timezone_detected 1

touch "$state_dir/fail_commit_once"
if run_helper --configure Asia/Ho_Chi_Minh true local >/dev/null 2>&1; then
	echo 'UCI commit failure was ignored' >&2
	exit 1
fi
assert_value zonename Europe/London
assert_value timezone 'GMT0BST,M3.5.0/1,M10.5.0'

echo 'timezone tests passed'
