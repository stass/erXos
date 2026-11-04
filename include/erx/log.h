/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LOG_H
#define ERX_LOG_H

/*
 * The kernel log's core: the ring of records, the one escaping function
 * that text enters it through, the limit on what one space may write, and
 * the reader and renderer of what leaves it (docs/design-kernel.md,
 * "Console, log and panic"). The core reads no clock and writes no device;
 * its host passes the time in, holds one lock around every call that takes
 * an erx_log_t and a space's erx_log_rate_t, and writes rendered lines to its
 * console.
 *
 * Every byte of a record's text passes erx_log_escape on its way in, the
 * kernel's own format strings included, so a record's text holds only
 * printable ASCII and a record cannot span lines.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/* A record's header and longest text; every read window holds at least one. */
#define ERX_LOG_RECORD_MAX	(ERX_LOG_RECORD_SIZE + ERX_LOG_TEXT_MAX)
/* The longest line erx_log_render writes, its newline included. */
#define ERX_LOG_LINE_MAX	(ERX_LOG_TEXT_MAX + 72)

/*
 * The log. All zeros is the empty log, so a zeroed static one needs no
 * initialization. The raw_ members hold the text and the records; only
 * kernel/core/log.c names them, which the log-raw-private check enforces.
 * head and tail are byte positions that only grow; a position's offset in
 * the ring is its low bits.
 */
typedef struct erx_log {
	uint64_t	next_seq;	/* the next record's sequence number */
	uint64_t	oldest_seq;	/* the oldest record's in the ring */
	uint64_t	head;		/* where the next record goes */
	uint64_t	tail;		/* where the oldest record starts */
	char		raw_text[ERX_LOG_TEXT_MAX];	/* the text being built */
	_Alignas(8) uint8_t raw_ring[ERX_LOG_RING_BYTES];
} erx_log_t;

/* How much of the input one call of erx_log_escape used and produced. */
typedef struct erx_log_escape_result {
	size_t	consumed;	/* input bytes wholly written */
	size_t	written;	/* output bytes; no terminator follows them */
} erx_log_escape_result_t;

/*
 * What one space's erx_debug_log lines cost in the current one-second
 * window, and how many it has lost since its last line. All zeros is a
 * space that has written nothing. The kernel keeps one in each space.
 */
typedef struct erx_log_rate {
	uint64_t	window_start_ns;
	uint64_t	dropped;
	uint32_t	window_bytes;
} erx_log_rate_t;

/* The decision on one line: the state to keep, and whether the line is kept. */
typedef struct erx_log_rate_step {
	erx_log_rate_t	next;
	bool		admit;
} erx_log_rate_step_t;

/* What one call of erx_log_copy did. */
typedef struct erx_log_copy_result {
	erx_status_t	status;
	uint64_t	next_cursor;	/* pass this to the next read */
	uint64_t	lost;		/* records overwritten before they were read */
	size_t		written;	/* bytes of whole records in the window */
	uint32_t	records;	/* how many records those are */
} erx_log_copy_result_t;

/* One checked record of a read window; text is the reader's own copy. */
typedef struct erx_log_view {
	uint64_t		seq;
	uint64_t		time_ns;
	erx_log_level_t		level;
	erx_log_record_flags_t	flags;
	const char		*text;
	size_t			length;
} erx_log_view_t;

/* What erx_log_next_record found at the offset. */
typedef enum erx_log_next {
	ERX_LOG_NEXT_RECORD,	/* a whole, valid record; the offset moved past it */
	ERX_LOG_NEXT_END,	/* the window ends exactly at the offset */
	ERX_LOG_NEXT_CORRUPT	/* anything else; the offset did not move */
} erx_log_next_t;

/*
 * The one escaping function of the kernel log: copies text to dst, writing
 * printable ASCII as themselves and every other byte, tabs, newlines,
 * escape sequences and every byte of a multi-byte character included, as
 * \xNN. It stops before the first byte whose whole form does not fit, so
 * no token is ever cut. It loads each input byte once; a caller holding
 * bytes another party can rewrite still copies them out first, because a
 * compiler may load plain memory again.
 */
erx_log_escape_result_t erx_log_escape(const void *text, size_t length,
    char *dst, size_t capacity);

/*
 * Charges a line of cost bytes against the window that holds now_ns, and
 * either keeps the line or counts it as dropped. Pure.
 */
erx_log_rate_step_t erx_log_rate_admit(const erx_log_rate_t *rate,
    uint64_t now_ns, uint32_t cost);

/*
 * erx_debug_log's work: logs len bytes of the UTCB's message words, each
 * word loaded once, as one debug-level line that opens with the caller's
 * space and how many lines it lost before this one. A line beyond the
 * space's rate is dropped and counted, and the call still returns ERX_OK.
 * A length beyond the UTCB is ERX_EINVAL; a log with no sequence number
 * left is ERX_ELIMIT. Neither touches the log or the rate.
 */
erx_status_t erx_log_debug(erx_log_t *log, erx_log_rate_t *rate, uint64_t space,
    uint64_t now_ns, const erx_utcb_t *utcb, erx_utcb_length_t len);

/*
 * The kernel's own lines. It understands %%, %s, %.*s, %c and %d, %u and %x
 * with no size or with l, ll or z, and escapes everything it writes, the
 * format's own text included. Text past the record's end is cut and the
 * record flagged ERX_LOG_RECORD_TRUNCATED. Any other conversion, or a
 * negative precision, ends the text there with a mark, flagged the same,
 * and nothing further is read from the arguments. An unknown level is
 * ERX_EINVAL; a log with no sequence number left is ERX_ELIMIT.
 *
 * Every caller writes ERX_LOG_FORMAT, the log-format-literal check keeps the
 * function's own name out of every other file: joining "" to the format
 * makes anything but a string literal fail to compile, so text from outside
 * the kernel can never be a format.
 */
erx_status_t erx_log_format(erx_log_t *log, erx_log_level_t level,
    uint64_t now_ns, const char *format, ...)
    __attribute__((__format__(__printf__, 4, 5)));

#define ERX_LOG_FORMAT(log, level, now_ns, ...) \
	erx_log_format((log), (level), (now_ns), "" __VA_ARGS__)

/*
 * erx_log_read's work: copies whole records from the cursor into the
 * window, as many as fit, and advances the cursor past them. A cursor
 * older than the ring starts at the oldest record and reports how many
 * were lost. A cursor at the newest position copies nothing. A cursor past
 * it, or a window shorter than ERX_LOG_RECORD_MAX, so that any record
 * fits, is ERX_EINVAL with the cursor returned unchanged. The log is not
 * changed, and the padding the window receives is zero.
 */
erx_log_copy_result_t erx_log_copy(const erx_log_t *log, uint64_t cursor,
    uint8_t *window, size_t window_size);

/*
 * Reads the record at *offset of a window of window_size bytes, trusting
 * none of them: the window is memory another party may have written. A
 * record is whole, inside the window and 8-byte aligned, with a known
 * level and flags, zero reserved and padding bytes, and text of only the
 * bytes erx_log_escape passes. The text is copied to the caller's text, of
 * ERX_LOG_TEXT_MAX bytes, and checked there, so what the view points at
 * cannot change once it is checked. On anything but ERX_LOG_NEXT_RECORD the
 * view is untouched and text holds nothing to use.
 */
erx_log_next_t erx_log_next_record(const uint8_t *window, size_t window_size,
    size_t *offset, char *text, erx_log_view_t *view);

/*
 * Whether the counters could be the ring's: at most one minimal record per
 * record's worth of ring, and no more bytes than the ring holds. Every point
 * of an append that a stopped CPU leaves passes. A reader that cannot trust the
 * log, the crash record's at a panic, treats a log that fails as having no
 * lines, which also bounds how far erx_log_copy's cursor can walk.
 */
bool erx_log_counters_plausible(const erx_log_t *log);

/*
 * Writes a record as one line, "#SEQ SECONDS.MICROSECONDS LEVEL TEXT" and
 * a newline, with " [truncated]" before the newline when the record says
 * so. Everything but the newline passes erx_log_escape, so no view of any
 * bytes can put a control byte in the line. Returns the line's length, or 0
 * with nothing to use when the line does not fit in capacity;
 * ERX_LOG_LINE_MAX always holds a checked record.
 */
size_t erx_log_render(const erx_log_view_t *view, char *dst, size_t capacity);

#endif /* ERX_LOG_H */
