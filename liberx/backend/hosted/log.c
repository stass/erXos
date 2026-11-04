/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The hosted backend's kernel log: erx_debug_log inside one macOS process,
 * which is one space. The process holds the kernel's ring and rate state,
 * runs the kernel's core over them under one lock, and plays the early
 * console: standard error is its console, and every record goes there as it
 * is written, as during a real kernel's boot. erx_hosted_log_sink is the one
 * writer of log bytes in this backend (the hosted-log-sink check), and it
 * only ever receives lines erx_log_render made.
 */

#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/log.h"
#include "liberx/backend/hosted/generated/calls.h"
#include "liberx/backend/hosted/log.h"

static void erx_hosted_log_drain(void);
static uint64_t erx_hosted_log_now(void);
static void erx_hosted_log_sink(const char *, size_t);

static pthread_mutex_t erx_hosted_log_lock = PTHREAD_MUTEX_INITIALIZER;

/* Guarded by erx_hosted_log_lock. */
static erx_log_t erx_hosted_log;
static erx_log_rate_t erx_hosted_log_rate;
static uint64_t erx_hosted_log_cursor;
static uint8_t erx_hosted_log_window[ERX_LOG_RECORD_MAX];
static char erx_hosted_log_text[ERX_LOG_TEXT_MAX];
static char erx_hosted_log_line[ERX_LOG_LINE_MAX];

/* Each thread's UTCB; nothing but the thread itself reaches it here. */
static _Thread_local erx_utcb_t erx_hosted_utcb;

erx_utcb_t *
erx_utcb_self(void)
{
	return (&erx_hosted_utcb);
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

/* Writes every record the console has not yet had, one window at a time. */
static void
erx_hosted_log_drain(void)
{
	erx_log_copy_result_t copied;
	erx_log_view_t view;
	size_t length, offset;

	for (;;) {
		copied = erx_log_copy(&erx_hosted_log, erx_hosted_log_cursor,
		    erx_hosted_log_window, sizeof(erx_hosted_log_window));
		if (copied.status != ERX_OK || copied.records == 0)
			return;
		erx_hosted_log_cursor = copied.next_cursor;

		offset = 0;
		while (erx_log_next_record(erx_hosted_log_window, copied.written,
		    &offset, erx_hosted_log_text, &view) == ERX_LOG_NEXT_RECORD) {
			length = erx_log_render(&view, erx_hosted_log_line,
			    sizeof(erx_hosted_log_line));
			erx_hosted_log_sink(erx_hosted_log_line, length);
		}
	}
}

/* The kernel clock's stand-in; a clock that fails reads as time zero. */
static uint64_t
erx_hosted_log_now(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		return (0);
	return ((uint64_t)now.tv_sec * UINT64_C(1000000000) +
	    (uint64_t)now.tv_nsec);
}

erx_status_t
erx_hosted_debug_log(erx_utcb_length_t len)
{
	erx_status_t status;

	(void)pthread_mutex_lock(&erx_hosted_log_lock);
	status = erx_log_debug(&erx_hosted_log, &erx_hosted_log_rate,
	    (uint64_t)getpid(), erx_hosted_log_now(), &erx_hosted_utcb, len);
	if (status == ERX_OK)
		erx_hosted_log_drain();
	(void)pthread_mutex_unlock(&erx_hosted_log_lock);
	return (status);
}
