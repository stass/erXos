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
 * frame with the generated erx_prog_check_notice and keeps it.  A doorbell
 * "bind" gives a label is the group's: its ring queues the label, and the
 * driver's executor thread takes each and calls erx_pipe_doorbell, as the
 * event executor does.  erx_umtx_wait and erx_umtx_wake are a futex over
 * one mutex and condition variable.  Worker threads, up to WORKERS, make
 * the liberx calls that wait.
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
 *   bind CAP LABEL         a ring of doorbell CAP comes up as LABEL
 *   fdread FD N            erx_prog_fd_read of at most N bytes: COUNT TEXT
 *   fdwrite FD TEXT        erx_prog_fd_write of TEXT ("-" for no bytes): COUNT
 *   spawn T fdread FD N    worker T makes the call; "spawned"
 *   spawn T fdwrite FD TEXT
 *   spawn T fdwriten FD N  one erx_prog_fd_write of N bytes, each its offset's
 *   spawn T fdreadn FD N   reads until N bytes came, each its offset's: COUNT,
 *                          or where the first wrong result or byte came
 *   spawn T watch FD FD    worker T watches both ends, as a poll does, sleeps
 *                          until a wake bumps its word, and unwatches both
 *   join T                 worker T's answer, or "stuck" after ten seconds
 *   waiters FD K           waits up to ten seconds for FD's end to list K
 *                          waiters; prints how many it lists
 *   bitswait KIND CAP V    waits up to ten seconds for that word to be V; prints it
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
#include "liberx/program/wake.h"

#define CAPS	512	/* capability values 1 to CAPS - 1 */
#define MAPS	256
#define WORKERS	8
#define LABELS	64

static pthread_mutex_t fake = PTHREAD_MUTEX_INITIALIZER;
static struct cap {
	uint32_t	 alias;		/* the value whose object this one names, or 0 */
	int		 fd;		/* the object's file, or -1 before its first map */
	uint64_t	 size;
	unsigned	 closes;
	unsigned	 rings;
	uint64_t	 label;		/* the label a ring comes up as, or 0 */
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

/* ---------------------------------------------------------------------
 * The group's ready list, its executor, and the futex */

static pthread_mutex_t ready_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cond = PTHREAD_COND_INITIALIZER;
static uint64_t ready[LABELS];
static unsigned nready;

static void
label_queue(uint64_t label)
{
	pthread_mutex_lock(&ready_lock);
	for (unsigned at = 0; at < nready; at++) {
		if (ready[at] == label) {
			pthread_mutex_unlock(&ready_lock);
			return;
		}
	}
	if (nready == LABELS)
		fail("too many labels ready");
	ready[nready++] = label;
	pthread_cond_signal(&ready_cond);
	pthread_mutex_unlock(&ready_lock);
}

static void *
executor_main(void *arg)
{
	(void)arg;
	for (;;) {
		uint64_t label;

		pthread_mutex_lock(&ready_lock);
		while (nready == 0)
			pthread_cond_wait(&ready_cond, &ready_lock);
		label = ready[0];
		memmove(ready, ready + 1, --nready * sizeof(ready[0]));
		pthread_mutex_unlock(&ready_lock);
		if (!erx_pipe_doorbell(label))
			fail("a bound label that is no pipe end's");
	}
	return (NULL);
}

static pthread_mutex_t futex_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t futex_cond = PTHREAD_COND_INITIALIZER;

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	_Atomic uint32_t *const word = (_Atomic uint32_t *)(uintptr_t)addr;

	(void)deadline;
	pthread_mutex_lock(&futex_lock);
	while (atomic_load(word) == expected)
		pthread_cond_wait(&futex_cond, &futex_lock);
	pthread_mutex_unlock(&futex_lock);
	return (ERX_OK);
}

int
erx_umtx_wake(uint64_t addr, uint32_t count)
{
	(void)addr;
	(void)count;
	pthread_mutex_lock(&futex_lock);
	pthread_cond_broadcast(&futex_cond);
	pthread_mutex_unlock(&futex_lock);
	return (ERX_OK);
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
	if (cap_of(irq)->label != 0)
		label_queue(cap_of(irq)->label);
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

/* ---------------------------------------------------------------------
 * Calls through liberx, and its workers */

static void
fd_read(int fd, size_t n, char *answer, size_t size)
{
	char buf[256];
	ssize_t got;

	if (n > sizeof(buf))
		fail("a read past the buffer");
	got = erx_prog_fd_read(fd, buf, n);
	snprintf(answer, size, "%zd%s%.*s", got, got > 0 ? " " : "", got > 0 ? (int)got : 0, buf);
}

static void
fd_write(int fd, const char *text, char *answer, size_t size)
{
	const char *bytes = strcmp(text, "-") == 0 ? "" : text;

	snprintf(answer, size, "%zd", erx_prog_fd_write(fd, bytes, strlen(bytes)));
}

/* The byte at offset at of a long write: a replayed or skipped stretch reads wrong. */
static char
pattern_byte(size_t at)
{
	return ((char)('a' + at % 251 % 26));
}

static void
fd_writen(int fd, size_t n, char *answer, size_t size)
{
	char *bytes = malloc(n);

	if (bytes == NULL)
		fail("malloc");
	for (size_t at = 0; at < n; at++)
		bytes[at] = pattern_byte(at);
	snprintf(answer, size, "%zd", erx_prog_fd_write(fd, bytes, n));
	free(bytes);
}

static void
fd_readn(int fd, size_t n, char *answer, size_t size)
{
	char buf[4096];
	size_t total = 0;

	while (total < n) {
		const ssize_t got = erx_prog_fd_read(fd, buf, sizeof(buf) < n - total ? sizeof(buf) : n - total);

		if (got <= 0) {
			snprintf(answer, size, "%zd after %zu", got, total);
			return;
		}
		for (ssize_t at = 0; at < got; at++) {
			if (buf[at] != pattern_byte(total + (size_t)at)) {
				snprintf(answer, size, "a stray byte after %zu", total + (size_t)at);
				return;
			}
		}
		total += (size_t)got;
	}
	snprintf(answer, size, "%zu", total);
}

/* A poll's registrations, without its readiness: watch both, sleep once, unwatch both. */
static void
watch_two(int fd1, int fd2, char *answer, size_t size)
{
	erx_pipe_end_t *a = end_get(fd1), *b = end_get(fd2);
	const uint32_t seen = atomic_load(erx_prog_wake_word());
	erx_prog_waiter_t wa, wb;

	erx_pipe_watch(a, &wa);
	erx_pipe_watch(b, &wb);
	erx_prog_wake_sleep(seen);
	erx_pipe_unwatch(a, &wa);
	erx_pipe_unwatch(b, &wb);
	erx_prog_obj_put(&a->obj);
	erx_prog_obj_put(&b->obj);
	snprintf(answer, size, "woke");
}

static struct worker {
	pthread_t	 thread;
	char		 call[16];
	int		 fd;
	int		 fd2;
	size_t		 n;
	char		 text[256];
	char		 answer[300];
	_Atomic bool	 done;
} workers[WORKERS];

static void *
worker_main(void *arg)
{
	struct worker *w = arg;

	if (strcmp(w->call, "fdread") == 0)
		fd_read(w->fd, w->n, w->answer, sizeof(w->answer));
	else if (strcmp(w->call, "fdwrite") == 0)
		fd_write(w->fd, w->text, w->answer, sizeof(w->answer));
	else if (strcmp(w->call, "fdwriten") == 0)
		fd_writen(w->fd, w->n, w->answer, sizeof(w->answer));
	else if (strcmp(w->call, "fdreadn") == 0)
		fd_readn(w->fd, w->n, w->answer, sizeof(w->answer));
	else
		watch_two(w->fd, w->fd2, w->answer, sizeof(w->answer));
	atomic_store(&w->done, true);
	return (NULL);
}

static struct worker *
worker_of(unsigned long long t)
{
	if (t >= WORKERS)
		fail("no such worker");
	return (&workers[t]);
}

static void
do_spawn(const char *line)
{
	unsigned long long t, n;
	char call[16], text[256];
	struct worker *w;
	int fd, fd2;

	if (sscanf(line, "%*s %llu %15s", &t, call) != 2)
		fail("spawn T CALL ...");
	w = worker_of(t);
	memset(w, 0, sizeof(*w));
	snprintf(w->call, sizeof(w->call), "%s", call);
	if ((strcmp(call, "fdread") == 0 || strcmp(call, "fdwriten") == 0 || strcmp(call, "fdreadn") == 0) &&
	    sscanf(line, "%*s %*s %*s %d %llu", &fd, &n) == 2) {
		w->fd = fd;
		w->n = (size_t)n;
	} else if (strcmp(call, "fdwrite") == 0 && sscanf(line, "%*s %*s %*s %d %255s", &fd, text) == 2) {
		w->fd = fd;
		snprintf(w->text, sizeof(w->text), "%s", text);
	} else if (strcmp(call, "watch") == 0 && sscanf(line, "%*s %*s %*s %d %d", &fd, &fd2) == 2) {
		w->fd = fd;
		w->fd2 = fd2;
	} else {
		fail("a call no worker makes");
	}
	if (pthread_create(&w->thread, NULL, worker_main, w) != 0)
		fail("pthread_create");
	printf("spawned\n");
}

/* Waits up to ten seconds for cond(arg) to hold, a margin for a loaded host. */
static bool
within_ten_seconds(bool (*cond)(void *), void *arg)
{
	const struct timespec pause = { 0, 5 * 1000 * 1000 };

	for (int tries = 0; tries < 2000; tries++) {
		if (cond(arg))
			return (true);
		nanosleep(&pause, NULL);
	}
	return (cond(arg));
}

static bool
worker_done(void *arg)
{
	return (atomic_load(&((struct worker *)arg)->done));
}

static void
do_join(unsigned long long t)
{
	struct worker *w = worker_of(t);

	if (!within_ten_seconds(worker_done, w)) {
		printf("stuck\n");
		return;
	}
	pthread_join(w->thread, NULL);
	printf("%s\n", w->answer);
}

struct listed {
	erx_pipe_end_t	*e;
	unsigned	 want;
	unsigned	 count;
};

static bool
waiters_listed(void *arg)
{
	struct listed *l = arg;

	pthread_mutex_lock(&l->e->lock);
	l->count = 0;
	for (const erx_prog_waiter_t *w = l->e->waiters.head; w != NULL; w = w->next)
		l->count++;
	pthread_mutex_unlock(&l->e->lock);
	return (l->count == l->want);
}

static void
do_waiters(int fd, unsigned want)
{
	struct listed l = { end_get(fd), want, 0 };

	(void)within_ten_seconds(waiters_listed, &l);
	erx_prog_obj_put(&l.e->obj);
	printf("%u\n", l.count);
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

struct bits_want {
	off_t		 off;
	int		 fd;
	uint64_t	 want;
	uint64_t	 value;
};

static bool
bits_are(void *arg)
{
	struct bits_want *b = arg;

	if (pread(b->fd, &b->value, sizeof(b->value), b->off) != sizeof(b->value))
		fail("pread");
	return (b->value == b->want);
}

static void
do_bitswait(const char *kind, uint64_t cap, uint64_t want)
{
	struct bits_want b = { bits_offset(kind), object_of(cap)->fd, want, 0 };

	(void)within_ten_seconds(bits_are, &b);
	printf("%" PRIx64 "\n", b.value);
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
	pthread_t executor;
	int fd;

	for (uint32_t value = 0; value < CAPS; value++)
		caps[value].fd = -1;
	if (argc != 2 || (requests = fopen(argv[1], "r")) == NULL)
		fail("usage: prog_fd_driver REQUESTS");
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (pthread_create(&executor, NULL, executor_main, NULL) != 0)
		fail("pthread_create");
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
		} else if (strcmp(word, "poll") == 0 && sscanf(line, "%*s %d", &fd) == 1) {
			/* One poll of the end: its POLL* bits, 0 when nothing is ready. */
			erx_pipe_end_t *e = end_get(fd);

			printf("%d\n", erx_pipe_poll(e));
			erx_prog_obj_put(&e->obj);
		} else if (strcmp(word, "bind") == 0 && sscanf(line, "%*s %llu %llu", &a, &b) == 2) {
			cap_of(a)->label = b;
			printf("bound\n");
		} else if (strcmp(word, "fdread") == 0 && sscanf(line, "%*s %d %llu", &fd, &a) == 2) {
			char answer[300];

			fd_read(fd, (size_t)a, answer, sizeof(answer));
			printf("%s\n", answer);
		} else if (strcmp(word, "fdwrite") == 0 && sscanf(line, "%*s %d %s", &fd, arg) == 2) {
			char answer[32];

			fd_write(fd, arg, answer, sizeof(answer));
			printf("%s\n", answer);
		} else if (strcmp(word, "spawn") == 0) {
			do_spawn(line);
		} else if (strcmp(word, "join") == 0 && sscanf(line, "%*s %llu", &a) == 1) {
			do_join(a);
		} else if (strcmp(word, "waiters") == 0 && sscanf(line, "%*s %d %llu", &fd, &a) == 2) {
			do_waiters(fd, (unsigned)a);
		} else if (strcmp(word, "bitswait") == 0 && sscanf(line, "%*s %15s %llu %llx", arg, &a, &b) == 3) {
			do_bitswait(arg, a, b);
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
	/* Workers still stuck in a call end with the process. */
	fflush(stdout);
	_exit(0);
}
