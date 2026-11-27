/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * init: process 1 of the fault probe's Linux guest (tools/lib/erx/fault_probe.rb,
 * docs/design-recovery.md, "Fault injection and tests"). It mounts devtmpfs and sysfs,
 * loads the virtio driver modules the initramfs carries in /modules (the stock kernel
 * builds them as modules), brings eth0 up, and runs four threads, each exercising one
 * thing a fault may stop:
 *
 *   tick     "fault: tick N" on the serial console every TICK_MS, the guest's own pulse;
 *   block    one BLOCK_BYTES read of the scratch disk at offset 0 with O_DIRECT, so each
 *            read reaches the device, in a loop: "fault: blk ok MS CRC" with the read's
 *            latency and the CRC-32 of what it read, or "fault: blk error ERRNO";
 *   carrier  "fault: carrier V" whenever eth0's carrier changes, and once at start;
 *   console  "con N" lines to the virtio console port, every TICK_MS; a failed write
 *            prints "fault: con error ERRNO" on the serial console.
 *
 * The harness judges these lines (FaultProbe.observe and FaultProbe.judge); the CRC is the harness's
 * check that a read answered the data it wrote, so the pattern lives only on the host.
 * At FAULT_PROBE_DEADLINE_S the guest powers off, a backstop for a harness that did not
 * end QEMU itself.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/syscall.h>

#if !defined(FAULT_PROBE_DEADLINE_S) || !defined(FAULT_PROBE_TICK_MS) || !defined(FAULT_PROBE_BLOCK_BYTES)
#error "the probe passes the guest's deadline, tick and block size"
#endif

#define TICK_MS		FAULT_PROBE_TICK_MS
#define BLOCK_BYTES	FAULT_PROBE_BLOCK_BYTES
#define DISK		"/dev/vda"
#define CARRIER		"/sys/class/net/eth0/carrier"
#define INTERFACE	"eth0"
#define MODULES		"/modules"
#define MAX_MODULES	16
/* A device a driver has just probed appears within this many tries of TICK_MS. */
#define DEVICE_TRIES	50

static pthread_mutex_t serial = PTHREAD_MUTEX_INITIALIZER;

/* One whole line on the serial console: threads never interleave within a line. */
static void
say(const char *format, ...)
{
	va_list arguments;

	pthread_mutex_lock(&serial);
	va_start(arguments, format);
	vprintf(format, arguments);
	va_end(arguments);
	putchar('\n');
	fflush(stdout);
	pthread_mutex_unlock(&serial);
}

static int64_t
monotonic_ms(void)
{
	struct timespec now = { 0 };

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static void
pause_ms(long ms)
{
	const struct timespec pause = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };

	nanosleep(&pause, NULL);
}

/* The CRC-32 of IEEE 802.3, reflected, as zlib's crc32 computes it. */
static uint32_t
crc32(const unsigned char *bytes, size_t length)
{
	uint32_t crc = 0xffffffffu;

	for (size_t i = 0; i < length; i++) {
		crc ^= bytes[i];
		for (int bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
	}
	return (~crc);
}

/* Opens path, retrying while the device its driver probes has not appeared yet. */
static int
open_device(const char *path, int flags)
{
	int fd = -1;

	for (int try = 0; try < DEVICE_TRIES && (fd = open(path, flags)) < 0; try++)
		pause_ms(TICK_MS);
	return (fd);
}

/*
 * Loads every module in MODULES, in passes until a pass loads nothing more, so a module
 * whose dependency loads later in the same pass loads in the next: the order is nobody's
 * fact to keep. A module still not loaded is reported with the error of its last try.
 */
static void
load_modules(void)
{
	char names[MAX_MODULES][NAME_MAX + 1];
	int errors[MAX_MODULES] = { 0 };
	bool loaded[MAX_MODULES] = { false };
	struct dirent *entry;
	size_t count = 0;
	bool progress = true;
	DIR *directory;

	if ((directory = opendir(MODULES)) == NULL) {
		say("fault: setup modules %d", errno);
		return;
	}
	while ((entry = readdir(directory)) != NULL && count < MAX_MODULES)
		if (entry->d_name[0] != '.')
			snprintf(names[count++], sizeof(names[0]), "%s", entry->d_name);
	closedir(directory);
	while (progress) {
		progress = false;
		for (size_t i = 0; i < count; i++) {
			char path[sizeof(MODULES) + NAME_MAX + 1];
			int fd;

			if (loaded[i])
				continue;
			snprintf(path, sizeof(path), "%s/%s", MODULES, names[i]);
			if ((fd = open(path, O_RDONLY | O_CLOEXEC)) >= 0 &&
			    (syscall(SYS_finit_module, fd, "", 0) == 0 || errno == EEXIST))
				loaded[i] = progress = true;
			else
				errors[i] = errno;
			if (fd >= 0)
				close(fd);
		}
	}
	for (size_t i = 0; i < count; i++)
		if (!loaded[i])
			say("fault: setup module %d", errors[i]);
}

static void *
tick(void *unused)
{
	(void)unused;
	for (unsigned long n = 0;; n++) {
		say("fault: tick %lu", n);
		pause_ms(TICK_MS);
	}
	return (NULL);
}

static void *
block(void *unused)
{
	unsigned char *buffer = NULL;
	int disk, error;

	(void)unused;
	if ((disk = open_device(DISK, O_RDONLY | O_DIRECT)) < 0) {
		say("fault: setup block %d", errno);
		return (NULL);
	}
	if ((error = posix_memalign((void **)&buffer, BLOCK_BYTES, BLOCK_BYTES)) != 0) {
		say("fault: setup block %d", error);
		return (NULL);
	}
	for (;;) {
		const int64_t started = monotonic_ms();
		const ssize_t got = pread(disk, buffer, BLOCK_BYTES, 0);

		if (got == BLOCK_BYTES)
			say("fault: blk ok %lld %08x", (long long)(monotonic_ms() - started),
			    (unsigned)crc32(buffer, BLOCK_BYTES));
		else
			say("fault: blk error %d", got < 0 ? errno : EIO);
		pause_ms(TICK_MS / 2);
	}
	return (NULL);
}

/* eth0's carrier, 0 or 1, or -1 when sysfs does not say. */
static int
carrier_now(void)
{
	char value = 0;
	int fd;
	ssize_t got;

	if ((fd = open(CARRIER, O_RDONLY)) < 0)
		return (-1);
	got = read(fd, &value, 1);
	close(fd);
	return (got == 1 && (value == '0' || value == '1') ? value - '0' : -1);
}

static void *
carrier(void *unused)
{
	int last = -2;

	(void)unused;
	for (;;) {
		const int now = carrier_now();

		if (now != last)
			say("fault: carrier %d", now);
		last = now;
		pause_ms(TICK_MS / 2);
	}
	return (NULL);
}

static void *
console(void *unused)
{
	static const char *const ports[] = { "/dev/hvc0", "/dev/hvc1" };
	char line[32];
	int port = -1;

	(void)unused;
	for (size_t i = 0; i < sizeof(ports) / sizeof(ports[0]) && port < 0; i++)
		port = open_device(ports[i], O_WRONLY | O_NOCTTY);
	if (port < 0) {
		say("fault: setup console %d", errno);
		return (NULL);
	}
	for (unsigned long n = 0;; n++) {
		const int length = snprintf(line, sizeof(line), "con %lu\n", n);

		if (write(port, line, (size_t)length) != length)
			say("fault: con error %d", errno);
		pause_ms(TICK_MS);
	}
	return (NULL);
}

/* Brings eth0 up, so sysfs reports its carrier. */
static int
interface_up(void)
{
	struct ifreq request = { 0 };
	int fd, result = -1;

	if ((fd = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
		return (-1);
	strncpy(request.ifr_name, INTERFACE, IFNAMSIZ - 1);
	for (int try = 0; try < DEVICE_TRIES && (result = ioctl(fd, SIOCGIFFLAGS, &request)) != 0; try++)
		pause_ms(TICK_MS);
	if (result == 0) {
		request.ifr_flags |= IFF_UP;
		result = ioctl(fd, SIOCSIFFLAGS, &request);
	}
	close(fd);
	return (result);
}

int
main(void)
{
	void *(*const threads[])(void *) = { tick, block, carrier, console };
	pthread_t thread;

	if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) != 0 && errno != EBUSY)
		say("fault: setup devtmpfs %d", errno);
	if (mount("sysfs", "/sys", "sysfs", 0, NULL) != 0)
		say("fault: setup sysfs %d", errno);
	load_modules();
	if (interface_up() != 0)
		say("fault: setup eth0 %d", errno);
	say("fault: ready");
	for (size_t i = 0; i < sizeof(threads) / sizeof(threads[0]); i++)
		if (pthread_create(&thread, NULL, threads[i], NULL) != 0)
			say("fault: setup thread %zu", i);
	sleep(FAULT_PROBE_DEADLINE_S);
	say("fault: deadline");
	sync();
	reboot(RB_POWER_OFF);
	return (0);
}
