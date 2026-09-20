#!/usr/bin/env bash
# Verify the dashboard helper without depending on the build host's hardware.

set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
openwrt_host=${RG_TEST_OPENWRT_HOST:-$project_dir/tests/fixtures/host}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/rg-ma2820-overview-test.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

proc_root=$temporary/proc
sys_root=$temporary/sys
init_root=$temporary/init.d
mkdir -p "$proc_root/nvram" "$sys_root/class/thermal/thermal_zone0" \
	"$sys_root/class/ubi/ubi0" "$init_root"

cat > "$temporary/device.env" <<'EOF'
DEVICE_ID='ap3'
HOSTNAME='rg-ma2820-ap3'
RESCUE_LINK_LOCAL='169.254.20.3'
PEER_ID='ap2'
PEER_HOSTNAME='rg-ma2820-ap2'
EOF
printf 'r22\n' > "$temporary/release"
printf '321.50 100.00\n' > "$proc_root/uptime"
printf '0.10 0.20 0.30 1/50 123\n' > "$proc_root/loadavg"
cat > "$proc_root/meminfo" <<'EOF'
MemTotal:         251264 kB
MemFree:           40000 kB
MemAvailable:     100000 kB
Buffers:            8000 kB
Cached:             30000 kB
EOF
printf '/dev/ubiblock0_5 /rom squashfs ro 0 0\n' > "$proc_root/mounts"
printf 'ma2820t\0' > "$proc_root/nvram/projectid"
printf 'MA2820T_V2\0' > "$proc_root/nvram/boardid"
printf '0x301B0011\n' > "$proc_root/nvram/productid"
printf '02:00:00:00:03:00\0' > "$proc_root/nvram/BaseMacAddr"
printf '0\n' > "$proc_root/nvram/ap_upgrade_num"
printf '81000\n' > "$sys_root/class/thermal/thermal_zone0/temp"
printf '110000\n' > "$sys_root/class/thermal/thermal_zone0/trip_point_2_temp"
printf '0\n' > "$sys_root/class/ubi/ubi0/bad_peb_count"
printf 'nameserver 192.0.2.1\n' > "$temporary/resolv.conf"
cat > "$temporary/led.state" <<'EOF'
UPDATED=1789879999
POWER=normal
UPLINK=online
WAN=online
LAN=disconnected
WIFI=ready
MESH=ready
CARRIER=1
WAN_CARRIER=1
LAN_CARRIER=0
GATEWAY_REACHABLE=1
RADIOS_READY=3
RADIOS_EXPECTED=3
PEER_ONLINE=1
EOF

for interface in br-lan eth0 eth1 eth2 eth3 eth4; do
	mkdir -p "$sys_root/class/net/$interface/statistics"
	printf '00:11:22:33:44:55\n' > "$sys_root/class/net/$interface/address"
	for counter in rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
		printf '0\n' > "$sys_root/class/net/$interface/statistics/$counter"
	done
	[ "$interface" = br-lan ] && continue
	mkdir -p "$sys_root/class/net/$interface/brport"
	if [ "$interface" = eth0 ]; then
		printf '1\n' > "$sys_root/class/net/$interface/carrier"
		printf 'up\n' > "$sys_root/class/net/$interface/operstate"
		printf '1000\n' > "$sys_root/class/net/$interface/speed"
		printf 'full\n' > "$sys_root/class/net/$interface/duplex"
		printf '3\n' > "$sys_root/class/net/$interface/brport/state"
	else
		printf '0\n' > "$sys_root/class/net/$interface/carrier"
		printf 'down\n' > "$sys_root/class/net/$interface/operstate"
		printf '0\n' > "$sys_root/class/net/$interface/speed"
		printf 'half\n' > "$sys_root/class/net/$interface/duplex"
		printf '0\n' > "$sys_root/class/net/$interface/brport/state"
	fi
done
printf '123456\n' > "$sys_root/class/net/eth0/statistics/rx_bytes"
printf '654321\n' > "$sys_root/class/net/eth0/statistics/tx_bytes"

cat > "$temporary/bootstate" <<'EOF'
#!/bin/sh
cat <<'STATE'
active=b
pending=none
booting=none
last_result=accepted
STATE
EOF

cat > "$temporary/ip" <<'EOF'
#!/bin/sh
case "$*" in
	'-4 addr show dev br-lan')
		cat <<'STATE'
    inet 169.254.20.3/16 scope global br-lan:rescue
    inet 192.0.2.3/24 brd 192.0.2.255 scope global br-lan
STATE
		;;
	'-4 route show default') echo 'default via 192.0.2.1 dev br-lan' ;;
	*) exit 2 ;;
esac
EOF

cat > "$temporary/df" <<'EOF'
#!/bin/sh
cat <<'STATE'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/ubi0_3 19496 400 18064 2% /overlay
STATE
EOF

cat > "$temporary/date" <<'EOF'
#!/bin/sh
[ "$1" = +%s ] && echo 1789880000 || echo ICT
EOF
cat > "$temporary/uname" <<'EOF'
#!/bin/sh
echo 4.1.52
EOF
cat > "$temporary/pidof" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "$temporary/bootstate" "$temporary/ip" "$temporary/df" \
	"$temporary/date" "$temporary/uname" "$temporary/pidof"
for service in rg-ma2820-leds rg-ma2820-neighbor-sync rg-ma2820-roaming; do
	printf '#!/bin/sh\nexit 0\n' > "$init_root/$service"
	chmod 0755 "$init_root/$service"
done

run_status()
{
	PATH="$openwrt_host/bin:$PATH" \
	RG_MA2820_DEVICE_ENV="$temporary/device.env" \
	RG_MA2820_RELEASE_FILE="$temporary/release" \
	RG_MA2820_RECOVERY_MARKER="$temporary/recovery-root" \
	RG_MA2820_BOOTSTATE="$temporary/bootstate" \
	RG_MA2820_PROC_ROOT="$proc_root" RG_MA2820_SYS_ROOT="$sys_root" \
	RG_MA2820_JSHN="$openwrt_host/share/libubox/jshn.sh" \
	RG_MA2820_IP="$temporary/ip" RG_MA2820_DF="$temporary/df" \
	RG_MA2820_PIDOF="$temporary/pidof" RG_MA2820_DATE="$temporary/date" \
	RG_MA2820_UNAME="$temporary/uname" RG_MA2820_RESOLV_FILE="$temporary/resolv.conf" \
	RG_MA2820_INIT_ROOT="$init_root" RG_MA2820_LED_STATE="$temporary/led.state" \
	bash "$project_dir/persistent-overlay/usr/sbin/rg-ma2820-overview-status"
}

result=$(run_status)

printf '%s' "$result" | jq -e '
	.identity.hostname == "rg-ma2820-ap3" and
	.identity.release == "r22" and
	.boot.running_slot == "b" and .boot.accepted_slot == "b" and
	.network.management_cidr == "192.0.2.3/24" and
	.network.rescue_cidr == "169.254.20.3/16" and
	(.ports | length) == 5 and .ports[0].link == true and
	.ports[0].speed_mbps == 1000 and .ports[0].rx_bytes == 123456 and
	.leds.power == "normal" and .leds.uplink == "online" and .leds.wan == "online" and
	.leds.lan == "disconnected" and .leds.wifi == "ready" and
	.leds.carrier == 1 and .leds.wan_carrier == 1 and .leds.lan_carrier == 0 and
	.leds.wan_color_mode == "green" and
	.leds.mesh == "ready" and .leds.radios_ready == 3 and
	([.services[].running] | all) and
	.system.memory_available_kb == 100000 and .system.temperature_mc == 81000 and
	.system.thermal_trip_mc == 110000
' >/dev/null

# A LAN uplink is healthy even though the physical WAN socket has no cable.
printf 'UPLINK=online\nWAN=disconnected\nWAN_COLOR_MODE=direction\nLAN=ready\nCARRIER=1\nWAN_CARRIER=0\nLAN_CARRIER=1\n' > "$temporary/led.state"
result=$(run_status)
printf '%s' "$result" | jq -e '
	.leds.uplink == "online" and .leds.wan == "disconnected" and
	.leds.lan == "ready" and .leds.wan_carrier == 0 and .leds.lan_carrier == 1 and
	.leds.wan_color_mode == "direction"
' >/dev/null

# Evaluate the actual view functions: a disconnected socket is neutral, while
# generic uplink failure still warns when the LAN socket carries management.
node - "$project_dir/persistent-overlay/www/luci-static/resources/view/status/index.js" <<'JS'
const fs = require('fs');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const labels = source.slice(source.indexOf('function indicatorLabel('), source.indexOf('function indicatorRow('));
const wanDetail = source.slice(source.indexOf('function wanIndicatorDetail('), source.indexOf('function keyValue('));
const warnings = source.slice(source.indexOf('function collectWarnings('), source.indexOf('function dashboardStyle('));
const api = new Function('_', `${labels}\n${wanDetail}\n${warnings}\nreturn { indicatorLabel, indicatorSeverity, wanIndicatorDetail, collectWarnings };`)(s => s);
assert.equal(api.indicatorLabel('disconnected'), 'No cable');
assert.equal(api.indicatorSeverity('disconnected'), 'neutral');
assert.match(api.wanIndicatorDetail('direction'), /green flashes show received traffic and red flashes show transmitted traffic/);
assert.match(api.wanIndicatorDetail('direction'), /red does not mean an error/);
assert.match(api.wanIndicatorDetail('green'), /red means uplink failure/);
assert.equal(api.wanIndicatorDetail(undefined), api.wanIndicatorDetail('green'));
const system = {
    network: { management_cidr: '192.0.2.3/24', gateway: '192.0.2.1' },
    leds: { uplink: 'online', wan: 'disconnected', lan: 'ready' }
};
assert.deepEqual(api.collectWarnings(system, {}), []);
system.leds.wan = 'ready';
system.leds.wan_color_mode = 'direction';
for (const uplink of ['degraded', 'offline']) {
    system.leds.uplink = uplink;
    assert.deepEqual(api.collectWarnings(system, {}), [{
        level: 'warning', text: 'The uplink gateway health check is failing.'
    }]);
}
JS

echo 'operations dashboard status tests: PASS'
