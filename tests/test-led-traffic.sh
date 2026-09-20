#!/usr/bin/env bash
# Native activity logic, real-process CPU and complete proc-write checks.
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
cc -O2 -Wall -Wextra -Werror -std=c11 -o "$tmp_dir/unit" "$project_dir/tests/led-traffic-test.c"
"$tmp_dir/unit"
cc -O2 -Wall -Wextra -Werror -std=c11 -o "$tmp_dir/led-traffic" "$project_dir/src/led-traffic.c"
mkdir -p "$tmp_dir/net/eth0/statistics"
printf '1\n' > "$tmp_dir/net/eth0/carrier"
printf '%020d\n' 100 > "$tmp_dir/net/eth0/statistics/rx_packets"
printf '%020d\n' 200 > "$tmp_dir/net/eth0/statistics/tx_packets"
export RG_MA2820_NET_CLASS="$tmp_dir/net"
export RG_MA2820_LED_METRICS="$tmp_dir/metrics"
export RG_MA2820_LED_PROC="$tmp_dir/led"
"$tmp_dir/led-traffic" direction --observe --duration-ms 200
[ ! -e "$tmp_dir/led" ]
grep -q '^PULSES=0$' "$tmp_dir/metrics"
grep -q '^READ_ERRORS=0$' "$tmp_dir/metrics"
python3 - "$tmp_dir" <<'PY'
import os, pathlib, subprocess, sys, threading, time
p = pathlib.Path(sys.argv[1])
reader, writer = os.pipe()
env = os.environ.copy(); env['RG_MA2820_LED_PROC'] = f'/proc/self/fd/{writer}'
events = []
def collect():
    pending = b''
    while True:
        b = os.read(reader, 4096)
        if not b: break
        pending += b
        while len(pending) >= 4:
            events.append((time.monotonic(), pending[:4].decode())); pending = pending[4:]
    assert not pending
thread = threading.Thread(target=collect); thread.start()
proc = subprocess.Popen([str(p/'led-traffic'), 'direction'], env=env, pass_fds=(writer,))
os.close(writer)
def number(name, n):
    fd = os.open(p/'net/eth0/statistics'/name, os.O_WRONLY)
    os.pwrite(fd, f'{n:020d}\n'.encode(), 0); os.close(fd)
time.sleep(.15)
number('rx_packets', 101); time.sleep(.2)
number('tx_packets', 201); time.sleep(.2)
for i in range(60):
    number('rx_packets', 102+i*10000); time.sleep(.005)
quiet = time.monotonic(); time.sleep(.3)
quiet_end = time.monotonic()
(p/'net/eth0/carrier').write_text('0\n'); time.sleep(.15)
proc.terminate(); assert proc.wait(timeout=3) == 0
thread.join(timeout=3); os.close(reader)
commands = [c for _,c in events]
assert '1401' in commands and '1501' in commands, commands
assert '1301' not in commands, commands
assert not [c for t,c in events if quiet+.2 < t < quiet_end], events
mask = {'140':0, '150':0, '130':0}
for _,c in events:
    assert len(c)==4 and c[:3] in mask and c[3] in '01', c
    mask[c[:3]]=int(c[3]); assert not(mask['140'] and mask['150']), events
assert not any(mask.values()), mask
metrics = dict(l.split('=',1) for l in (p/'metrics').read_text().splitlines())
assert int(metrics['READ_ERRORS']) == 0, metrics
assert int(metrics['WIDTH_MIN_US']) >= 70000, metrics
assert int(metrics['WIDTH_MAX_US']) < 200000, metrics
assert int(metrics['CPU_MS']) < int(metrics['UPTIME_MS'])/10, metrics
print('Process: traffic edges, no phantom LAN, no replay, colors, low CPU and shutdown: PASS')
PY
if RG_MA2820_LED_PROC=/dev/full "$tmp_dir/led-traffic" direction --duration-ms 50 2> "$tmp_dir/error"; then
    echo 'Ignored LED write failure' >&2; exit 1
fi
grep -q 'LED output' "$tmp_dir/error"
if "$tmp_dir/led-traffic" blue > /dev/null 2>&1; then exit 1; fi
target_root=${RG_MA2820_TEST_TARGET_ROOT:-$project_dir/openwrt/staging_dir/target-arm_cortex-a7_musl_eabi/root-bcm6755}
if command -v qemu-arm >/dev/null && [ -f "$target_root/lib/libsetlbf.so" ]; then
    "$project_dir/tools/build-led-traffic.sh" "$tmp_dir/arm-led-traffic"
    env RG_MA2820_LED_PROC=/dev/null \
        qemu-arm -L "$target_root" -E LD_PRELOAD=/lib/libsetlbf.so -strace \
        "$tmp_dir/arm-led-traffic" direction --duration-ms 50 \
        > "$tmp_dir/arm.out" 2> "$tmp_dir/syscalls"
    grep -Eq 'write\([0-9]+,.*,[[:space:]]*4\) = 4' "$tmp_dir/syscalls"
    if grep -Eq 'write\([0-9]+,.*,[[:space:]]*[123]\)' "$tmp_dir/syscalls"; then
        echo 'Fragmented LED command' >&2; exit 1
    fi
    echo 'ARM proc commands under procd preload: PASS'
fi
