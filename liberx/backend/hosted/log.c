/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The hosted backend of the kernel interface's log: one macOS process, which
 * is one space, runs the kernel's own dispatch and log cores and provides
 * their effects. Standard error is its console, and every record goes there
 * as it is written, as during a real kernel's boot. erx_hosted_log_sink, through
 * erx_hosted_log_put, is the one writer of log bytes in this backend (the
 * hosted-log-sink check). It receives the lines erx_log_render made and text
 * this backend built itself, never bytes a caller of the function API supplied.
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/core/debug_log.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "erx/log.h"
#include "liberx/backend/api.h"
#include "liberx/backend/hosted/generated/calls.h"
#include "liberx/backend/hosted/internal.h"
#include "liberx/backend/hosted/log.h"

static void erx_hosted_log_sink(const char *, size_t);
static int erx_hosted_log_result(const erx_log_copy_result_t *, erx_log_read_result_t *);

static pthread_mutex_t erx_hosted_log_lock = PTHREAD_MUTEX_INITIALIZER;

/* The process's one space's log rate; the cores guard it with the log lock. */
static erx_log_rate_t erx_hosted_log_rate;

/* Each thread's UTCB; nothing but the thread itself reaches it here. */
static _Thread_local erx_utcb_t erx_hosted_utcb;

erx_utcb_t *
erx_utcb_self(void)
{
	/* The block holds its own address, as natively; storing it each time is simplest. */
	atomic_store_explicit(&erx_hosted_utcb.self, (uint64_t)(uintptr_t)&erx_hosted_utcb, memory_order_relaxed);
	return (&erx_hosted_utcb);
}

void
erx_effect_log_lock(void)
{
	(void)pthread_mutex_lock(&erx_hosted_log_lock);
}

void
erx_effect_log_unlock(void)
{
	(void)pthread_mutex_unlock(&erx_hosted_log_lock);
}

/*
 * Writes bytes to standard error, retrying a short write, and says whether
 * all of them went out. A console that fails drops the rest, as the real
 * early console drops a byte its UART will not take: the record stays in the
 * ring, and the caller's status does not depend on the console. Standard
 * error is a development tool's own console, so a full pipe holding up the
 * process is what a developer asked for.
 */
static bool
erx_hosted_log_put(const char *bytes, size_t length)
{
	ssize_t written;

	while (length > 0) {
		written = write(STDERR_FILENO, bytes, length);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			return (false);
		bytes += written;
		length -= (size_t)written;
	}
	return (true);
}

/*
 * Whether standard error is a terminal, decided once: nothing in the
 * process redirects it, and the check leaves errno as it found it.
 */
static pthread_once_t erx_hosted_log_once = PTHREAD_ONCE_INIT;
static bool erx_hosted_log_terminal;

static void
erx_hosted_log_probe(void)
{
	int saved = errno;

	erx_hosted_log_terminal = isatty(STDERR_FILENO) == 1;
	errno = saved;
}

/*
 * Writes one line in one write, so no other writer's bytes land inside it.
 * On a terminal each newline goes out as CR-LF, as FreeBSD's kernel console
 * writes it: the runtime's stdio puts the terminal in raw mode, where a bare
 * newline would leave the next line starting mid-row. A pipe or a file gets
 * the line's bytes unchanged. A rendered line fits the buffer whole; longer
 * text goes out in buffer-sized pieces.
 */
static void
erx_hosted_log_sink(const char *line, size_t length)
{
	char out[ERX_LOG_LINE_MAX + 2];
	size_t used = 0;

	(void)pthread_once(&erx_hosted_log_once, erx_hosted_log_probe);
	if (!erx_hosted_log_terminal) {
		(void)erx_hosted_log_put(line, length);
		return;
	}
	for (size_t at = 0; at < length; at++) {
		/* Room for the byte and the CR that may precede it. */
		if (used + 2 > sizeof(out)) {
			if (!erx_hosted_log_put(out, used))
				return;
			used = 0;
		}
		if (line[at] == '\n')
			out[used++] = '\r';
		out[used++] = line[at];
	}
	(void)erx_hosted_log_put(out, used);
}

void
erx_hosted_note(const char *line)
{
	size_t length = 0;

	while (line[length] != '\0')
		length++;
	erx_hosted_log_sink(line, length);
}

_Noreturn void
erx_hosted_fatal(const char *why)
{
	erx_hosted_note(why);
	abort();
}

void
erx_effect_console_write(const char *line, size_t length)
{
	erx_hosted_log_sink(line, length);
}

/*
 * The kernel clock's stand-in, and the clock stock OTP takes on the host. On macOS it is
 * the raw counter: CLOCK_MONOTONIC would not do there, since macOS derives it from the
 * wall clock, so it can step back. Stock OTP takes CLOCK_UPTIME on FreeBSD and
 * CLOCK_MONOTONIC on Linux, neither of which steps back. The hosted backend builds only
 * on macOS (tools/lib/erx/runtime.rb), so the other branches are not yet compiled.
 */
uint64_t
erx_effect_clock_ns(void)
{
#ifdef __APPLE__
	return (clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
#else
	struct timespec now;

#ifdef __FreeBSD__
	(void)clock_gettime(CLOCK_UPTIME, &now);
#else
	(void)clock_gettime(CLOCK_MONOTONIC, &now);
#endif
	return ((uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec);
#endif
}

void
erx_hosted_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_sys_caller_t caller = {
		.utcb = &erx_hosted_utcb,
		.log_rate = &erx_hosted_log_rate,
		.space = (uint64_t)getpid(),
		.executor = false,
	};

	erx_dispatch(&caller, number, args, results);
}

erx_status_t
erx_hosted_debug_log(erx_utcb_length_t len)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { (uint64_t)len.raw };
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	uint32_t raw_status;

	erx_hosted_call(ERX_CALL_DEBUG_LOG, args, results);
	raw_status = (uint32_t)results[0];
	return (raw_status <= UINT32_C(2147483647) ? (int32_t)raw_status :
	    -INT32_C(1) - (int32_t)(UINT32_C(4294967295) - raw_status));
}

/*
 * erx_log_read and erx_log_take: the process is one space, so the window is the caller's
 * own and the core reads straight into it. Nothing here hands the log to the console, so
 * standard error takes every record as it is written: a take finds nothing, and a read from
 * 0 sees what standard error already showed, as dmesg does.
 */
static int
erx_hosted_log_result(const erx_log_copy_result_t *copied, erx_log_read_result_t *result)
{
	if (copied->status != ERX_OK)
		return (copied->status);
	*result = (erx_log_read_result_t){ .next_cursor = copied->next_cursor, .lost = copied->lost,
	    .written = copied->written };
	return (ERX_OK);
}

int
erx_log_read(uint64_t res, uint64_t cursor, void *window, uint64_t size, erx_log_read_result_t *result)
{
	erx_log_copy_result_t copied;

	(void)res;
	if (window == NULL || result == NULL)
		return (ERX_EINVAL);
	copied = erx_debug_log_read(cursor, window, (size_t)size);
	return (erx_hosted_log_result(&copied, result));
}

int
erx_log_take(uint64_t res, void *window, uint64_t size, erx_log_read_result_t *result)
{
	erx_log_copy_result_t copied;

	(void)res;
	if (window == NULL || result == NULL)
		return (ERX_EINVAL);
	copied = erx_debug_log_take(window, (size_t)size);
	return (erx_hosted_log_result(&copied, result));
}
