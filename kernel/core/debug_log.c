/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_debug_log's handler and the kernel log it writes (docs/design-kernel.md,
 * "Console, log and panic"). The log core decides everything about a line;
 * this file owns the one ring and carries each new record to the early
 * console, which only ever receives lines erx_log_render made.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/effects.h"
#include "erx/log.h"
#include "abi_calls.h"
#include "dispatch_impl.h"
#include "erx/core/debug_log.h"

_Static_assert(sizeof(erx_log_rate_t) == ERX_LOG_RATE_STATE_BYTES,
    "a space's opaque log rate state");
_Static_assert(_Alignof(erx_log_rate_t) == ERX_LOG_RATE_STATE_ALIGN,
    "a space's opaque log rate alignment");

static void erx_debug_log_drain(void);
static size_t erx_debug_log_lost_line(uint64_t, char *, size_t);

/*
 * Guarded by erx_effect_log_lock. The console's buffers live here rather than
 * on a kernel stack: a record's text is about 2 KiB, and one drain runs at a
 * time.
 */
static erx_log_t erx_debug_log_ring;
static uint64_t erx_debug_log_cursor;	/* where what has been taken ends */
static bool erx_debug_log_for_reader;
static uint8_t erx_debug_log_window[ERX_LOG_RECORD_MAX];
static char erx_debug_log_text[ERX_LOG_TEXT_MAX];
static char erx_debug_log_line[ERX_LOG_LINE_MAX];

/*
 * The console's line for records the ring overwrote before anyone took them, which no
 * record can say for itself: "erx: N log records lost" and a newline. Returns its length.
 */
static size_t
erx_debug_log_lost_line(uint64_t lost, char *line, size_t capacity)
{
	static const char head[] = "erx: ", tail[] = " log records lost\n";
	char digits[20];
	size_t count = 0, length = 0;

	do {
		digits[count++] = (char)('0' + lost % 10);
		lost /= 10;
	} while (lost != 0);
	if (sizeof(head) - 1 + count + sizeof(tail) - 1 > capacity)
		return (0);
	for (size_t index = 0; index < sizeof(head) - 1; index++)
		line[length++] = head[index];
	while (count > 0)
		line[length++] = digits[--count];
	for (size_t index = 0; index < sizeof(tail) - 1; index++)
		line[length++] = tail[index];
	return (length);
}

/* Writes every record the console has not yet had, one window at a time. */
static void
erx_debug_log_drain(void)
{
	erx_log_copy_result_t copied;
	erx_log_view_t view;
	size_t length, offset;

	for (;;) {
		copied = erx_log_copy(&erx_debug_log_ring, erx_debug_log_cursor,
		    erx_debug_log_window, sizeof(erx_debug_log_window));
		if (copied.status != ERX_OK || (copied.records == 0 && copied.lost == 0))
			return;
		erx_debug_log_cursor = copied.next_cursor;
		if (copied.lost != 0) {
			length = erx_debug_log_lost_line(copied.lost, erx_debug_log_line, sizeof(erx_debug_log_line));
			erx_effect_console_write(erx_debug_log_line, length);
		}

		offset = 0;
		while (erx_log_next_record(erx_debug_log_window, copied.written,
		    &offset, erx_debug_log_text, &view) ==
		    ERX_LOG_NEXT_RECORD) {
			length = erx_log_render(&view, erx_debug_log_line,
			    sizeof(erx_debug_log_line));
			erx_effect_console_write(erx_debug_log_line, length);
		}
	}
}

erx_status_t
erx_sys_debug_log(erx_sys_context_t *context,
    const erx_sys_debug_log_args_t *arguments)
{
	const erx_sys_caller_t *caller = context->caller;
	erx_status_t status;

	erx_effect_log_lock();
	status = erx_log_debug(&erx_debug_log_ring,
	    (erx_log_rate_t *)caller->log_rate, caller->space,
	    erx_effect_clock_ns(), (const erx_utcb_t *)caller->utcb,
	    arguments->len);
	if (status == ERX_OK && !erx_debug_log_for_reader)
		erx_debug_log_drain();
	erx_effect_log_unlock();
	return (status);
}

void
erx_debug_log_hand_to_reader(void)
{
	erx_effect_log_lock();
	erx_debug_log_for_reader = true;
	erx_effect_log_unlock();
}

void
erx_debug_log_take_back(void)
{
	erx_effect_log_lock();
	erx_debug_log_for_reader = false;
	erx_debug_log_drain();
	erx_effect_log_unlock();
}

erx_log_copy_result_t
erx_debug_log_read(uint64_t cursor, uint8_t *window, size_t window_size)
{
	erx_log_copy_result_t copied;

	erx_effect_log_lock();
	if (cursor > erx_debug_log_cursor) {
		erx_effect_log_unlock();
		return ((erx_log_copy_result_t){ .status = ERX_EINVAL, .next_cursor = cursor });
	}
	copied = erx_log_copy(&erx_debug_log_ring, erx_debug_log_cursor, window, window_size);
	if (copied.status == ERX_OK)
		erx_debug_log_cursor = copied.next_cursor;
	erx_effect_log_unlock();
	return (copied);
}
