/* SPDX-License-Identifier: GPL-2.0-only
 * RG-MA2820(T), retained RGOS 4.1.52 driver: physical Ethernet activity.
 * Read hardware counters every 10 ms; use the stock Wi-Fi LED's 80/20 ms
 * activity cadence. Packet bursts are coalesced, never queued for playback.
 * There is no packet queue or replay. See docs/LED_CONTROL.md for the ABI.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <net/if.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define NS_MS UINT64_C(1000000)
#define ON_NS (80 * NS_MS)
#define GAP_NS (20 * NS_MS)
#define SAMPLE_NS (10 * NS_MS)
#define LINK_NS (100 * NS_MS)
#define REPORT_NS (10 * UINT64_C(1000000000))

struct port {
	bool linked, baseline;
	uint64_t rx, tx;
	int rx_fd, tx_fd;
};
struct activity { bool rx, tx, lan; };
struct pattern {
	unsigned phase, color;
	bool alternate_tx, pending_rx, pending_tx;
	uint64_t due, began, last_rx, last_tx;
};
static struct pattern wan_pattern, lan_pattern;
struct metrics {
	uint64_t samples, rx, tx, lan, pulses, widths, width_sum, width_min, width_max;
	uint64_t errors, start, cpu_start;
};
static struct port ports[5];
static struct metrics stats;
static volatile sig_atomic_t stopping;
static int sw_fd = -1;
static int outputs[3] = { -1, -1, -1 };
static bool observe, green_mode;
static const char *net_class, *led_path, *state_path, *metrics_path;
static void wait_until(uint64_t deadline);

static uint64_t clock_ns(clockid_t id)
{
	struct timespec t;
	if (clock_gettime(id, &t)) { perror("LED clock"); exit(1); }
	return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static uint64_t now(void) { return clock_ns(CLOCK_MONOTONIC); }
static const char *setting(const char *key, const char *fallback)
{
	const char *s = getenv(key);
	return s && *s ? s : fallback;
}
static void on_signal(int sig) { (void)sig; stopping = 1; }

static bool read_number(int fd, uint64_t *value)
{
	char b[64], *end;
	ssize_t n = pread(fd, b, sizeof(b) - 1, 0);
	if (n <= 0) return false;
	b[n] = 0;
	if (b[0] < '0' || b[0] > '9') return false;
	errno = 0;
	*value = strtoull(b, &end, 10);
	return !errno && (end[0] == '\n' || end[0] == 0);
}
static int open_net(unsigned port, const char *suffix)
{
	char path[512];
	if (snprintf(path, sizeof(path), "%s/eth%u/%s", net_class, port, suffix) >= (int)sizeof(path)) {
		errno = ENAMETOOLONG; return -1;
	}
	return open(path, O_RDONLY | O_CLOEXEC);
}
static void refresh_links(void)
{
	for (unsigned i = 0; i < 5; i++) {
		uint64_t v = 0;
		int fd = open_net(i, "carrier");
		bool linked = fd >= 0 && read_number(fd, &v) && v == 1;
		if (fd >= 0) close(fd);
		if (ports[i].linked != linked) ports[i].baseline = false;
		ports[i].linked = linked;
	}
}

static void put32(unsigned char *p, size_t offset, uint32_t value)
{
	memcpy(p + offset, &value, sizeof(value));
}
static bool sf2_octets(unsigned port, bool receive, uint64_t *value)
{
	/* Verified against this board's libethswctl.so and bcm_enet.ko, not a
	 * guessed SDK layout. This is strictly ETHSWREGACCESS / TYPE_GET, unit 1.
	 * Only the four external LAN ports' non-clearing MIB counters are read.
	 * Do not use frequent sysfs LAN reads: that getter caches for one second
	 * and refreshes its timestamp even when returning its old cache.
	 */
	union { uint64_t align; unsigned char b[456]; } data = {0};
	struct ifreq ifr = {0};
	if (port < 1 || port > 4) return false;
	if (sw_fd < 0) sw_fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (sw_fd < 0) return false;
	memcpy(ifr.ifr_name, "bcmsw", sizeof("bcmsw"));
	ifr.ifr_data = (void *)data.b;
	put32(data.b, 0, 40);             /* ETHSWREGACCESS */
	put32(data.b, 8, 1);              /* external switch */
	put32(data.b, 28, 2);             /* TYPE_GET; never SET */
	put32(data.b, 248, ((0x20 + port - 1) << 8) | (receive ? 0x50 : 0x00));
	put32(data.b, 252, 8);            /* 64-bit octet counter */
	if (ioctl(sw_fd, 0x89fd, &ifr)) return false;
	memcpy(value, data.b + 174, sizeof(*value));
	return true;
}
static bool sample_port(unsigned i, uint64_t *rx, uint64_t *tx)
{
	if (i) return sf2_octets(i, true, rx) && sf2_octets(i, false, tx);
	/* eth0 is UNIMAC: selective sysfs reads hit live hardware counters. */
	if (ports[0].rx_fd < 0) ports[0].rx_fd = open_net(0, "statistics/rx_packets");
	if (ports[0].tx_fd < 0) ports[0].tx_fd = open_net(0, "statistics/tx_packets");
	if (read_number(ports[0].rx_fd, rx) && read_number(ports[0].tx_fd, tx)) return true;
	if (ports[0].rx_fd >= 0) close(ports[0].rx_fd);
	if (ports[0].tx_fd >= 0) close(ports[0].tx_fd);
	ports[0].rx_fd = ports[0].tx_fd = -1;
	return false;
}
static struct activity sample(void)
{
	struct activity a = {0};
	for (unsigned i = 0; i < 5; i++) {
		struct port *p = &ports[i];
		uint64_t rx, tx;
		if (!p->linked) continue;
		if (!sample_port(i, &rx, &tx)) { p->baseline = false; stats.errors++; continue; }
		/* Initial/cable-change samples and counter resets produce no pulse. */
		if (p->baseline && rx >= p->rx && tx >= p->tx) {
			if (i == 0) { a.rx = rx > p->rx; a.tx = tx > p->tx; }
			else a.lan |= rx > p->rx || tx > p->tx;
		}
		p->rx = rx; p->tx = tx; p->baseline = true;
	}
	stats.samples++; stats.rx += a.rx; stats.tx += a.tx; stats.lan += a.lan;
	return a;
}

static bool drive(unsigned output, int value)
{
	static const char *commands[3][2] = {
		{ "1400", "1401" }, { "1500", "1501" }, { "1300", "1301" }
	};
	if (outputs[output] == value) return true;
	/* The vendor handler rejects a nonzero file offset. Reopen for every
	 * command; submit all four bytes together despite procd's LD_PRELOAD. */
	int fd = open(led_path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) return false;
	ssize_t n = write(fd, commands[output][value], 4);
	int saved = errno;
	close(fd);
	if (n != 4) { errno = n < 0 ? saved : EIO; return false; }
	outputs[output] = value;
	return true;
}
static bool dark(void)
{
	bool ok = drive(0, 0);
	if (!drive(1, 0)) ok = false;
	if (!drive(2, 0)) ok = false;
	return ok;
}
static unsigned pattern(struct pattern *p, bool linked, bool rx, bool tx, uint64_t t)
{
	if (!linked) { memset(p, 0, sizeof(*p)); return 0; }
	if (rx) { p->pending_rx = true; p->last_rx = t; }
	if (tx) { p->pending_tx = true; p->last_tx = t; }
	if (p->phase == 0) {
		if (!rx && !tx) return 1; /* linked and idle: steady green */
		p->phase = 1; p->due = t + GAP_NS;
	}
	if (p->phase == 1) {
		if (t < p->due) return 0;
		p->phase = 2; p->began = t; p->due = t + ON_NS;
		if (p->pending_rx && p->pending_tx) {
			p->alternate_tx = !p->alternate_tx;
			p->color = p->alternate_tx ? 2 : 1;
		} else p->color = p->pending_tx ? 2 : 1;
		p->pending_rx = p->pending_tx = false;
		stats.pulses++;
		return p->color;
	}
	if (t < p->due) return p->color;
	uint64_t width = t - p->began;
	stats.widths++;
	stats.width_sum += width;
	if (!stats.width_min || width < stats.width_min) stats.width_min = width;
	if (width > stats.width_max) stats.width_max = width;
	/* Only fresh activity can start another cycle. A large earlier burst
	 * does not leave a queue to play back after traffic stops.
	 */
	p->pending_rx = p->last_rx && t - p->last_rx < 2 * SAMPLE_NS;
	p->pending_tx = p->last_tx && t - p->last_tx < 2 * SAMPLE_NS;
	if (p->pending_rx || p->pending_tx) {
		p->phase = 1; p->due = t + GAP_NS; return 0;
	}
	p->phase = 0;
	return 1;
}
static bool uplink_ok(void)
{
	if (!green_mode) return true;
	FILE *f = fopen(state_path, "r");
	char line[256]; bool ok = false;
	if (!f) return false;
	while (fgets(line, sizeof(line), f)) if (!strcmp(line, "UPLINK=online\n")) ok = true;
	fclose(f);
	return ok;
}
static bool render(struct activity a, bool online)
{
	uint64_t t = now();
	bool lan_linked = false;
	for (unsigned i = 1; i < 5; i++) lan_linked |= ports[i].linked;
	unsigned lan = pattern(&lan_pattern, lan_linked, a.lan, false, t);
	unsigned wan = pattern(&wan_pattern, ports[0].linked, a.rx, a.tx, t);
	if (green_mode) {
		if (ports[0].linked && !online) {
			memset(&wan_pattern, 0, sizeof(wan_pattern)); wan = 2;
		} else if (wan == 2) wan = 1;
	}
	/* Turn the old color off before enabling the new one. */
	if (wan != 1 && !drive(0, 0)) return false;
	if (wan != 2 && !drive(1, 0)) return false;
	return drive(0, wan == 1) && drive(1, wan == 2) && drive(2, lan != 0);
}
static void report(void)
{
	char path[512];
	if (snprintf(path, sizeof(path), "%s.new", metrics_path) >= (int)sizeof(path)) return;
	FILE *f = fopen(path, "w");
	if (!f) return;
	fprintf(f, "ACTIVITY_ON_US=80000\nACTIVITY_GAP_US=20000\nSAMPLE_US=10000\nMODE=%s\nOBSERVE=%u\n"
		"SAMPLES=%"PRIu64"\nWAN_RX_WINDOWS=%"PRIu64"\nWAN_TX_WINDOWS=%"PRIu64"\nLAN_WINDOWS=%"PRIu64"\n"
		"PULSES=%"PRIu64"\nWIDTH_MIN_US=%"PRIu64"\nWIDTH_AVG_US=%"PRIu64"\nWIDTH_MAX_US=%"PRIu64"\n"
		"READ_ERRORS=%"PRIu64"\nUPTIME_MS=%"PRIu64"\nCPU_MS=%"PRIu64"\n",
		green_mode ? "green" : "direction", observe, stats.samples, stats.rx, stats.tx, stats.lan,
		stats.pulses, stats.width_min / 1000, stats.widths ? stats.width_sum / stats.widths / 1000 : 0,
		stats.width_max / 1000, stats.errors, (now() - stats.start) / NS_MS,
		(clock_ns(CLOCK_PROCESS_CPUTIME_ID) - stats.cpu_start) / NS_MS);
	if (!fclose(f)) rename(path, metrics_path);
}
static void wait_until(uint64_t deadline)
{
	struct timespec t = { .tv_sec = deadline / 1000000000, .tv_nsec = deadline % 1000000000 };
	while (!stopping && clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL) == EINTR) {}
}
int main(int argc, char **argv)
{
	uint64_t duration = 0;
	if (argc < 2 || (strcmp(argv[1], "direction") && strcmp(argv[1], "green"))) goto usage;
	green_mode = !strcmp(argv[1], "green");
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--observe")) observe = true;
		else if (!strcmp(argv[i], "--duration-ms") && i + 1 < argc) {
			char *end; errno = 0;
			duration = strtoull(argv[++i], &end, 10);
			if (errno || *end || duration < 1 || duration > 3600000) goto usage;
			duration *= NS_MS;
		} else goto usage;
	}
	net_class = setting("RG_MA2820_NET_CLASS", "/sys/class/net");
	led_path = setting("RG_MA2820_LED_PROC", "/proc/factory_led");
	state_path = setting("RG_MA2820_LED_STATE", "/var/run/rg-ma2820-led.state");
	metrics_path = setting("RG_MA2820_LED_METRICS", "/var/run/rg-ma2820-led-traffic.state");
	for (unsigned i = 0; i < 5; i++) ports[i].rx_fd = ports[i].tx_fd = -1;
	signal(SIGTERM, on_signal); signal(SIGINT, on_signal);
	pid_t parent = getppid();
	prctl(PR_SET_PDEATHSIG, SIGTERM); if (getppid() != parent) return 1;
	prctl(PR_SET_TIMERSLACK, 1);
	if (!observe) {
		if (!dark()) { perror("LED output"); return 1; }
	}
	stats.start = now(); stats.cpu_start = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
	uint64_t next = stats.start, links = 0, reported = stats.start;
	bool online = false, ok = true;
	while (!stopping && (!duration || now() - stats.start < duration)) {
		uint64_t t = now();
		if (t >= links) { refresh_links(); online = uplink_ok(); links = t + LINK_NS; }
		struct activity a = sample();
		if (!observe && !render(a, online)) { perror("LED pulse"); ok = false; break; }
		if (t - reported >= REPORT_NS) { report(); reported = t; }
		next += SAMPLE_NS;
		/* A delayed process skips missed observations instead of catching up. */
		if (next <= now()) next = now() + SAMPLE_NS;
		wait_until(next);
	}
	if (!observe && !dark()) ok = false;
	report();
	return ok ? 0 : 1;
usage:
	fprintf(stderr, "Usage: led-traffic direction|green [--observe] [--duration-ms 1..3600000]\n");
	return 2;
}
