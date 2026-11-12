/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of test/host/prog_fd_test.rb: a program's descriptor table
 * and pipe ends (liberx/program/fd.h, liberx/program/pipe.h) over a fake
 * backend.  A memory object is an unlinked temporary file, made the first
 * time a capability value naming it is mapped and grown to fit every
 * mapping; two capability values name one object after "alias", as two
 * installs of one object do.  erx_vm_reserve is an anonymous PROT_NONE
 * mapping, erx_vm_map a MAP_FIXED|MAP_SHARED mapping of the file over it,
 * erx_vm_release its munmap.  erx_cap_close and erx_irq_trigger count per
 * value, and a second close, a ring of a closed doorbell or a release of
 * memory never reserved fails the run.  The channel's send checks each
 * frame with the generated erx_prog_check_notice and keeps it.
 *
 * It reads requests, one a line, from the file its argument names, and
 * prints one answer a line:
 *
 *   alias CAP OTHER        CAP names OTHER's object
 *   failmap N              the Nth erx_vm_map from now fails
 *   start HEX              plan the startup message and set the table up
 *   report HEX             read a report and apply it, as the executor does
 *   locked FD HEX          apply a report while a worker holds FD's end lock
 *   dup FD | close FD      the table's operations
 *   hold FD | drop         take and drop one counted reference
 *   state FD               the end FD holds, as the reports left it
 *   write FD TEXT          a write of TEXT through the end's core
 *   read FD N              a read of at most N bytes; WAIT when it would wait
 *   setbits KIND CAP V     store V in a lock page's waiters or reader page's sleepers
 *   bits KIND CAP          print that word
 *   notices | caps | maps  what was sent, closed and rung, and the live mappings
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/lane.h"
#include "erx/pipe.h"
#include "erx/pipe_run.h"
#include "erx/prog_profile.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"
#include "liberx/program/fd.h"
#include "liberx/program/inbound.h"
#include "liberx/program/pipe.h"
#include "liberx/program/startup.h"

#define CAPS	512	/* capability values 1 to CAPS - 1 */
#define MAPS	256

static pthread_mutex_t fake = PTHREAD_MUTEX_INITIALIZER;
static struct cap {
	uint32_t	 alias;		/* the value whose object this one names, or 0 */
	int		 fd;		/* the object's file, or -1 before its first map */
	uint64_t	 size;
	unsigned	 closes;
	unsigned	 rings;
} caps[CAPS];
static unsigned failmap;	/* maps until one fails, or 0 */
static struct map {
	uint64_t	 addr;
	uint64_t	 size;
} maps[MAPS];

static _Noreturn void
fail(const char *why)
{
	printf("FAIL %s\n", why);
	fflush(stdout);
	exit(1);
}

static struct cap *
cap_of(uint64_t value)
{
	if (value == 0 || value >= CAPS)
		fail("a capability value outside the fake's table");
	return (&caps[value]);
}

/* The capability whose object value names. */
static struct cap *
object_of(uint64_t value)
{
	struct cap *c = cap_of(value);

	return (c->alias != 0 ? cap_of(c->alias) : c);
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	void *p;

	(void)space;
	(void)addr;
	(void)flags;
	p = mmap(NULL, size, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
	if (p == MAP_FAILED)
		return (ERX_ENOMEM);
	pthread_mutex_lock(&fake);
	for (int at = 0; at < MAPS; at++) {
		if (maps[at].size == 0) {
			maps[at] = (struct map){ (uint64_t)(uintptr_t)p, size };
			pthread_mutex_unlock(&fake);
			*reserved = (uint64_t)(uintptr_t)p;
			return (ERX_OK);
		}
	}
	fail("too many mappings");
	return (ERX_ENOMEM);
}

int
erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	return (mprotect((void *)(uintptr_t)addr, size, PROT_READ | PROT_WRITE) == 0 ? ERX_OK : ERX_ENOMEM);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	struct cap *c, *o;
	int status = ERX_OK;

	(void)space;
	pthread_mutex_lock(&fake);
	c = cap_of(mem);
	o = object_of(mem);
	if (c->closes != 0)
		fail("a map of a closed capability");
	if (failmap != 0 && --failmap == 0) {
		pthread_mutex_unlock(&fake);
		return (ERX_ENOMEM);
	}
	if (o->fd < 0) {
		char path[] = "/tmp/erx-prog-fd-XXXXXX";

		if ((o->fd = mkstemp(path)) < 0 || unlink(path) != 0)
			fail("mkstemp");
	}
	if (o->size < offset + size) {
		if (ftruncate(o->fd, (off_t)(offset + size)) != 0)
			fail("ftruncate");
		o->size = offset + size;
	}
	if (mmap((void *)(uintptr_t)addr, size, prot == ERX_PROT_R ? PROT_READ : PROT_READ | PROT_WRITE,
	    MAP_FIXED | MAP_SHARED, o->fd, (off_t)offset) == MAP_FAILED)
		status = ERX_ENOMEM;
	pthread_mutex_unlock(&fake);
	return (status);
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	pthread_mutex_lock(&fake);
	for (int at = 0; at < MAPS; at++) {
		if (maps[at].addr == addr && maps[at].size == size) {
			maps[at] = (struct map){ 0, 0 };
			pthread_mutex_unlock(&fake);
			return (munmap((void *)(uintptr_t)addr, size) == 0 ? ERX_OK : ERX_EINVAL);
		}
	}
	fail("a release of memory never reserved, or of another size");
	return (ERX_EINVAL);
}

int
erx_cap_close(uint64_t cap)
{
	pthread_mutex_lock(&fake);
	if (cap_of(cap)->closes++ != 0)
		fail("a capability closed twice");
	pthread_mutex_unlock(&fake);
	return (ERX_OK);
}

int
erx_irq_trigger(uint64_t irq)
{
	pthread_mutex_lock(&fake);
	if (cap_of(irq)->closes != 0)
		fail("a ring of a closed doorbell");
	cap_of(irq)->rings++;
	pthread_mutex_unlock(&fake);
	return (ERX_OK);
}

uint64_t
erx_clock_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec);
}

/* The channel's send: each frame checked by the generated notice check, then kept as a line. */
static char notices[4096];

int
erx_prog_channel_send(const erx_lane_iov_t *iov, size_t iovcnt)
{
	static uint8_t scratch[4096];
	uint8_t frame[256];
	erx_profile_refusal_t refusal;
	erx_prog_notice_t notice;
	size_t len = 0;
	char line[64];

	for (size_t at = 0; at < iovcnt; at++) {
		if (len + iov[at].len > sizeof(frame))
			fail("a notice too large");
		memcpy(frame + len, iov[at].base, iov[at].len);
		len += iov[at].len;
	}
	pthread_mutex_lock(&fake);
	if (erx_prog_scratch_bytes(len) > sizeof(scratch) ||
	    !erx_prog_check_notice(frame, len, scratch, sizeof(scratch), &notice, &refusal))
		fail("a notice the profile refuses");
	switch (notice.which) {
	case ERX_PROG_NOTICE_CLOSED:
		snprintf(line, sizeof(line), " closed:%" PRIu32 ":%" PRIu32, notice.u.closed.pipe_id,
		    notice.u.closed.end_id);
		break;
	default:
		snprintf(line, sizeof(line), " drained:%" PRIu32 ":%" PRIu32 ":%" PRIu32,
		    notice.u.drained.pipe_id, notice.u.drained.end_id, notice.u.drained.wend);
		break;
	}
	if (strlen(notices) + strlen(line) >= sizeof(notices))
		fail("too many notices");
	strcat(notices, line);
	pthread_mutex_unlock(&fake);
	return (ERX_OK);
}

/* ---------------------------------------------------------------------
 * Requests */

static size_t
unhex(const char *hex, uint8_t **out)
{
	size_t len = strlen(hex) / 2;
	uint8_t *bytes = malloc(len + 1);

	for (size_t at = 0; at < len; at++) {
		unsigned byte;

		if (sscanf(hex + 2 * at, "%2x", &byte) != 1)
			fail("bad hex");
		bytes[at] = (uint8_t)byte;
	}
	*out = bytes;
	return (len);
}

/* The end slot fd refers to, with a counted reference the caller drops. */
static erx_pipe_end_t *
end_get(int fd)
{
	erx_prog_obj_t *obj = erx_prog_fd_get(fd);

	if (obj == NULL || obj->kind != ERX_PROG_OBJ_PIPE)
		fail("no pipe end at that descriptor");
	return (erx_pipe_end_of(obj));
}

static void
do_start(const char *hex)
{
	erx_prog_startup_t plan;
	uint8_t *frame, *scratch;
	size_t len = unhex(hex, &frame);

	scratch = malloc(erx_prog_scratch_bytes(len));
	if (erx_prog_startup_plan(frame, len, scratch, erx_prog_scratch_bytes(len), &plan) != 0)
		printf("refused %d %u\n", (int)plan.cause, plan.fd);
	else
		printf("setup %d\n", erx_prog_fd_setup(plan.fds));
	free(scratch);
	free(frame);
}

static bool
report_parse(const char *hex, erx_prog_report_t *report)
{
	static uint8_t scratch[8192];
	uint8_t *frame;
	size_t len = unhex(hex, &frame);
	bool ok = erx_prog_scratch_bytes(len) <= sizeof(scratch) &&
	    erx_prog_report_read(frame, len, scratch, sizeof(scratch), report);

	free(frame);
	return (ok);
}

static void
do_report(const char *hex)
{
	erx_prog_report_t report;

	if (!report_parse(hex, &report))
		fail("a report the profile refuses");
	erx_pipe_report(&report);
	printf("applied\n");
}

static _Atomic bool locked_done;

static void *
locked_apply(void *arg)
{
	erx_pipe_report(arg);
	atomic_store(&locked_done, true);
	return (NULL);
}

/*
 * A worker holds the end's lock while the executor applies a report: the
 * report must wait for the lock, so it is applied only once the worker lets
 * go.  "waited" when it did, "early" when it finished under the worker.
 */
static void
do_locked(int fd, const char *hex)
{
	erx_prog_report_t report;
	erx_pipe_end_t *e = end_get(fd);
	struct timespec pause = { 0, 100 * 1000 * 1000 };
	pthread_t thread;
	bool early;

	if (!report_parse(hex, &report))
		fail("a report the profile refuses");
	atomic_store(&locked_done, false);
	pthread_mutex_lock(&e->lock);
	pthread_create(&thread, NULL, locked_apply, &report);
	nanosleep(&pause, NULL);
	early = atomic_load(&locked_done);
	pthread_mutex_unlock(&e->lock);
	pthread_join(thread, NULL);
	erx_prog_obj_put(&e->obj);
	printf("%s\n", early ? "early" : "waited");
}

static erx_prog_obj_t *held;

static void
do_state(int fd)
{
	erx_pipe_end_t *e = end_get(fd);
	uint64_t peers = 0;

	pthread_mutex_lock(&e->lock);
	for (uint32_t rix = 0; rix < ERX_PIPE_READERS_MAX; rix++)
		if (e->peers[rix] != ERX_CAP_NULL)
			peers |= UINT64_C(1) << rix;
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		printf("write %u %u refs=%u readers=%u lost=%d size=%" PRIu64 " peers=%" PRIx64 "\n",
		    e->pipe, e->end, e->obj.refs - 1, e->u.w.st.readers, e->u.w.st.lost, e->u.w.st.size, peers);
		break;
	case ERX_PIPE_READ:
		printf("read %u %u refs=%u rix=%u known=%u lost=%d peers=%" PRIx64 " lanes=", e->pipe, e->end,
		    e->obj.refs - 1, e->u.r.st.rix, e->u.r.st.known, e->u.r.st.lost, peers);
		for (uint32_t at = 0; at < e->u.r.st.nlanes; at++)
			printf("%s%u:%s:%" PRIu64, at == 0 ? "" : ",", e->u.r.st.lanes[at].wend,
			    e->u.r.st.lanes[at].writer == ERX_PIPE_WRITER_OPEN ? "open" : "gone",
			    e->u.r.lanes[at].bell);
		printf("\n");
		break;
	}
	pthread_mutex_unlock(&e->lock);
	erx_prog_obj_put(&e->obj);
}

static uint64_t
fx_clock(void *ctx)
{
	(void)ctx;
	return (erx_clock_ns());
}

static void
fx_ring_reader(void *ctx, uint32_t rix)
{
	erx_pipe_end_t *e = ctx;

	if (rix < ERX_PIPE_READERS_MAX && e->peers[rix] != ERX_CAP_NULL)
		(void)erx_irq_trigger(e->peers[rix]);
}

static void
fx_ring_writer(void *ctx, uint32_t lane)
{
	(void)ctx;
	(void)lane;
}

static void
fx_lane(void *ctx, uint32_t lane)
{
	(void)ctx;
	(void)lane;
}

static void
fx_broken(void *ctx, uint32_t lane, uint64_t fault)
{
	(void)ctx;
	(void)lane;
	(void)fault;
}

static void
print_act(erx_pipe_act_t act)
{
	if (act.op == ERX_PIPE_OP_WAIT)
		printf("WAIT");
	else
		printf("%" PRId64, act.result);
}

static void
do_write(int fd, const char *text)
{
	erx_pipe_end_t *e = end_get(fd);
	erx_pipe_fx_t fx = { e, fx_clock, fx_ring_reader, fx_ring_writer, fx_lane, fx_broken };

	if (e->kind != ERX_PIPE_WRITE)
		fail("a write of a read end");
	pthread_mutex_lock(&e->lock);
	erx_pipe_wstart(&e->u.w.st, strlen(text));
	print_act(erx_pipe_wrun(&e->u.w.st, &e->u.w.map, text, &fx));
	printf("\n");
	pthread_mutex_unlock(&e->lock);
	erx_prog_obj_put(&e->obj);
}

static void
do_read(int fd, size_t n)
{
	erx_pipe_end_t *e = end_get(fd);
	erx_pipe_fx_t fx = { e, fx_clock, fx_ring_reader, fx_ring_writer, fx_lane, fx_broken };
	char buf[256];
	erx_pipe_act_t act;

	if (e->kind != ERX_PIPE_READ || n > sizeof(buf))
		fail("a read of a write end, or past the buffer");
	pthread_mutex_lock(&e->lock);
	erx_pipe_rstart(&e->u.r.st, n);
	act = erx_pipe_rrun(&e->u.r.st, e->u.r.maps, e->u.r.lockpage, buf, &fx);
	print_act(act);
	if (act.op == ERX_PIPE_OP_DONE && act.result > 0)
		printf(" %.*s", (int)act.result, buf);
	printf("\n");
	pthread_mutex_unlock(&e->lock);
	erx_prog_obj_put(&e->obj);
}

/* The offset of a bits word: a lock page's waiters or a reader page's sleepers. */
static off_t
bits_offset(const char *kind)
{
	if (strcmp(kind, "waiters") == 0)
		return (ERX_PIPE_LOCK_OFF_WAITERS);
	if (strcmp(kind, "sleepers") == 0)
		return (ERX_PIPE_RPAGE_OFF_SLEEPERS);
	fail("no such bits word");
	return (0);
}

static void
do_setbits(const char *kind, uint64_t cap, uint64_t value)
{
	struct cap *o = object_of(cap);

	if (o->fd < 0) {
		char path[] = "/tmp/erx-prog-fd-XXXXXX";

		if ((o->fd = mkstemp(path)) < 0 || unlink(path) != 0 ||
		    ftruncate(o->fd, ERX_PAGE_SIZE) != 0)
			fail("mkstemp");
		o->size = ERX_PAGE_SIZE;
	}
	if (pwrite(o->fd, &value, sizeof(value), bits_offset(kind)) != sizeof(value))
		fail("pwrite");
	printf("set\n");
}

static void
do_bits(const char *kind, uint64_t cap)
{
	uint64_t value;

	if (pread(object_of(cap)->fd, &value, sizeof(value), bits_offset(kind)) != sizeof(value))
		fail("pread");
	printf("%" PRIx64 "\n", value);
}

static void
do_caps(void)
{
	bool any = false;

	for (uint32_t value = 1; value < CAPS; value++) {
		if (caps[value].closes != 0 || caps[value].rings != 0) {
			printf("%s%u:%u:%u", any ? " " : "", value, caps[value].closes, caps[value].rings);
			any = true;
		}
	}
	printf("%s\n", any ? "" : "none");
}

static void
do_maps(void)
{
	unsigned live = 0;

	for (int at = 0; at < MAPS; at++)
		live += maps[at].size != 0;
	printf("%u\n", live);
}

int
main(int argc, char **argv)
{
	static char line[1 << 17], arg[1 << 17];
	char word[16];
	unsigned long long a, b;
	FILE *requests;
	int fd;

	for (uint32_t value = 0; value < CAPS; value++)
		caps[value].fd = -1;
	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		fail("usage: prog_fd_driver REQUESTS");
	setvbuf(stdout, NULL, _IOLBF, 0);
	while (fgets(line, sizeof(line), requests) != NULL) {
		if (sscanf(line, "%15s", word) != 1)
			continue;
		if (strcmp(word, "alias") == 0 && sscanf(line, "%*s %llu %llu", &a, &b) == 2) {
			cap_of(a)->alias = (uint32_t)b;
			printf("alias\n");
		} else if (strcmp(word, "failmap") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			failmap = (unsigned)a;
			printf("armed\n");
		} else if (strcmp(word, "start") == 0 && sscanf(line, "%*s %s", arg) == 1) {
			do_start(arg);
		} else if (strcmp(word, "report") == 0 && sscanf(line, "%*s %s", arg) == 1) {
			do_report(arg);
		} else if (strcmp(word, "locked") == 0 && sscanf(line, "%*s %d %s", &fd, arg) == 2) {
			do_locked(fd, arg);
		} else if (strcmp(word, "dup") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			printf("%d\n", erx_prog_fd_dup(fd));
		} else if (strcmp(word, "close") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			printf("%d\n", erx_prog_fd_close(fd));
		} else if (strcmp(word, "hold") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			erx_prog_obj_t *got = erx_prog_fd_get(fd);

			if (got != NULL)
				held = got;
			printf("%s\n", got != NULL ? "held" : "none");
		} else if (strcmp(word, "drop") == 0) {
			erx_prog_obj_put(held);
			held = NULL;
			printf("dropped\n");
		} else if (strcmp(word, "state") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			do_state(fd);
		} else if (strcmp(word, "write") == 0 && sscanf(line, "%*s %d %s", &fd, arg) == 2) {
			do_write(fd, arg);
		} else if (strcmp(word, "read") == 0 && sscanf(line, "%*s %d %llu", &fd, &a) == 2) {
			do_read(fd, (size_t)a);
		} else if (strcmp(word, "setbits") == 0 && sscanf(line, "%*s %15s %llu %llx", arg, &a, &b) == 3) {
			do_setbits(arg, a, b);
		} else if (strcmp(word, "bits") == 0 && sscanf(line, "%*s %15s %llu", arg, &a) == 2) {
			do_bits(arg, a);
		} else if (strcmp(word, "notices") == 0) {
			printf("%s\n", notices[0] != '\0' ? notices + 1 : "none");
		} else if (strcmp(word, "caps") == 0) {
			do_caps();
		} else if (strcmp(word, "maps") == 0) {
			do_maps();
		} else {
			fail(line);
		}
	}
	return (0);
}
