/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The hosted backend of the kernel interface's log: one macOS process, which
 * is one space, runs the kernel's own dispatch and log cores and provides
 * their effects. Standard error is its console, and every record goes there
 * as it is written, as during a real kernel's boot. erx_hosted_log_sink is the
 * one writer of log bytes in this backend (the hosted-log-sink check). It receives
 * the lines erx_log_render made and text this backend built itself, never bytes a
 * caller of the function API supplied.
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "erx/log.h"
#include "liberx/backend/hosted/generated/calls.h"
#include "liberx/backend/hosted/internal.h"
#include "liberx/backend/hosted/log.h"

static void erx_hosted_log_sink(const char *, size_t);

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
 * Writes one line, retrying a short write. A console that fails drops the
 * rest of the line, as the real early console drops a byte its UART will not
 * take: the record stays in the ring, and the caller's status does not depend
 * on the console. Standard error is a development tool's own console, so a
 * full pipe holding up the process is what a developer asked for.
 */
static void
erx_hosted_log_sink(const char *line, size_t length)
{
	ssize_t written;

	while (length > 0) {
		written = write(STDERR_FILENO, line, length);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			return;
		line += written;
		length -= (size_t)written;
	}
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

/* The kernel clock's stand-in; a clock that fails reads as time zero. */
uint64_t
erx_effect_clock_ns(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		return (0);
	return ((uint64_t)now.tv_sec * UINT64_C(1000000000) +
	    (uint64_t)now.tv_nsec);
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
