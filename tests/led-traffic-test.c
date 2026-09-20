/* Exercise the real controller with a strict, read-only SF2 driver double. */
#define _GNU_SOURCE
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <net/if.h>
static uint64_t fake_rx[4], fake_tx[4];
static unsigned ioctl_calls;
static int fake_ioctl(int fd, unsigned long request, ...)
{
	assert(fd >= 0 && request == 0x89fd);
	va_list ap; va_start(ap, request);
	struct ifreq *ifr = va_arg(ap, struct ifreq *); va_end(ap);
	assert(!strcmp(ifr->ifr_name, "bcmsw"));
	unsigned char *b = (void *)ifr->ifr_data;
	uint32_t op, unit, type, reg, len;
	memcpy(&op,b,4); memcpy(&unit,b+8,4); memcpy(&type,b+28,4);
	memcpy(&reg,b+248,4); memcpy(&len,b+252,4);
	assert(op == 40 && unit == 1 && type == 2 && len == 8);
	assert((reg >> 8) >= 0x20 && (reg >> 8) <= 0x23);
	assert((reg & 255) == 0x00 || (reg & 255) == 0x50);
	uint64_t v = (reg & 255) ? fake_rx[(reg >> 8) - 0x20] : fake_tx[(reg >> 8) - 0x20];
	memcpy(b + 174, &v, 8); ioctl_calls++;
	return 0;
}
#define ioctl fake_ioctl
#define main led_traffic_main
#include "../src/led-traffic.c"
#undef main
#undef ioctl

static void number(int fd, uint64_t n)
{
	char b[64]; int len = snprintf(b,sizeof(b),"%"PRIu64"\n",n);
	assert(ftruncate(fd, 0) == 0); assert(pwrite(fd,b,len,0) == len);
}
int main(void)
{
	char rx_path[] = "/tmp/rg-led-rx.XXXXXX", tx_path[] = "/tmp/rg-led-tx.XXXXXX";
	int rx_fd = mkstemp(rx_path), tx_fd = mkstemp(tx_path);
	assert(rx_fd >= 0 && tx_fd >= 0);
	unlink(rx_path); unlink(tx_path);
	ports[0].rx_fd = rx_fd; ports[0].tx_fd = tx_fd; ports[0].linked = true;
	number(rx_fd, 100); number(tx_fd, 100);
	struct activity a = sample(); assert(!a.rx && !a.tx && !a.lan && !ioctl_calls);
	number(rx_fd, 101); a = sample(); assert(a.rx && !a.tx && !a.lan);
	number(tx_fd, 102); a = sample(); assert(!a.rx && a.tx && !a.lan);
	number(rx_fd, 0); a = sample(); assert(!a.rx && !a.tx && !a.lan);
	number(rx_fd, 1); a = sample(); assert(a.rx && !a.tx && !a.lan);
	ports[0].linked = false;
	number(rx_fd, 90000); number(tx_fd, 90000);
	a = sample(); assert(!a.rx && !a.tx && !a.lan && !ioctl_calls);
	for (unsigned p = 1; p <= 4; p++) {
		ports[p].linked = true; fake_rx[p-1] = 1000; fake_tx[p-1] = 2000;
		a = sample(); assert(!a.lan);
		fake_rx[p-1]++; a = sample(); assert(!a.rx && !a.tx && a.lan);
		fake_tx[p-1]++; a = sample(); assert(a.lan);
		fake_rx[p-1] = 0; a = sample(); assert(!a.lan);
		ports[p].linked = ports[p].baseline = false;
		unsigned calls = ioctl_calls;
		fake_rx[p-1] = 999999; a = sample(); assert(!a.lan && ioctl_calls == calls);
		ports[p].linked = true; a = sample(); assert(!a.lan);
		ports[p].linked = false;
	}
	struct pattern p = {0}; uint64_t t = 1000 * NS_MS;
	assert(pattern(&p,true,false,false,t) == 1);
	assert(pattern(&p,true,true,false,t) == 0);
	assert(pattern(&p,true,false,false,t+19*NS_MS) == 0);
	assert(pattern(&p,true,false,false,t+20*NS_MS) == 1 && p.phase == 2);
	assert(pattern(&p,true,false,false,t+99*NS_MS) == 1);
	assert(pattern(&p,true,false,false,t+100*NS_MS) == 1 && p.phase == 0);
	assert(pattern(&p,true,false,false,t+200*NS_MS) == 1 && p.phase == 0);
	assert(pattern(&p,true,false,true,t+210*NS_MS) == 0);
	assert(pattern(&p,true,false,false,t+230*NS_MS) == 2);
	assert(pattern(&p,false,true,true,t+240*NS_MS) == 0 && p.phase == 0);
	for (unsigned cycle = 0; cycle < 4; cycle++) {
		t = (2000 + cycle * 100) * NS_MS;
		assert(pattern(&p,true,true,true,t) == 0);
		unsigned color = pattern(&p,true,true,true,t+20*NS_MS);
		assert(color == (cycle % 2 ? 1u : 2u));
		for (unsigned ms = 30; ms <= 90; ms += 10)
			assert(pattern(&p,true,true,true,t+ms*NS_MS) == color);
	}
	assert(pattern(&p,true,false,false,t+120*NS_MS) == 1 && p.phase == 0);
	assert(pattern(&p,false,false,false,t+130*NS_MS) == 0);
	/* Optional health-color mode keeps a WAN fault red while LAN remains
	 * independently linked. /dev/null is only the local opcode sink. */
	led_path = "/dev/null";
	green_mode = true;
	ports[0].linked = ports[1].linked = true;
	assert(render((struct activity){ .rx = true, .tx = true }, false));
	assert(outputs[0] == 0 && outputs[1] == 1 && outputs[2] == 1);
	assert(render((struct activity){0}, true));
	assert(outputs[0] == 1 && outputs[1] == 0 && outputs[2] == 1);
	ports[0].linked = ports[1].linked = false;
	assert(render((struct activity){0}, false));
	assert(outputs[0] == 0 && outputs[1] == 0 && outputs[2] == 0);
	close(rx_fd); close(tx_fd); close(sw_fd);
	puts("Hardware-read ABI, independent ports, resets, Wi-Fi cadence and burst coalescing: PASS");
	return 0;
}
