/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/log.h"

#define FUZZ_ESCAPE_INPUT_MAX	4096
#define FUZZ_TOKEN_BYTES	4
#define FUZZ_STRING_MAX		255

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void fuzz_escape(const uint8_t *, size_t, size_t);
static void fuzz_operations(const uint8_t *, size_t);
static void fuzz_read(uint64_t, size_t);
static void fuzz_window(const uint8_t *, size_t);
static bool line_safe(const char *, size_t);
static bool passes(uint8_t);

static erx_log_t fuzz_log;
static uint8_t fuzz_read_window[2 * ERX_LOG_RECORD_MAX];
static char fuzz_text[ERX_LOG_TEXT_MAX];
static char fuzz_line[ERX_LOG_LINE_MAX];

/* The escaper's byte class, written apart from the generated table. */
static bool
passes(uint8_t byte)
{
	return (byte == '\t' || (byte >= 0x20 && byte <= 0x7e));
}

/* A record's text or a rendered line: nothing outside the class. */
static bool
line_safe(const char *bytes, size_t length)
{
	for (size_t index = 0; index < length; index++) {
		if (!passes((uint8_t)bytes[index]))
			return (false);
	}
	return (true);
}

/*
 * The escaper on any bytes and any room. Undoing the tokens gives back exactly
 * the bytes it consumed, so no token was cut and nothing was changed, and it
 * stopped only because the next byte's form did not fit, so nothing was lost.
 */
static void
fuzz_escape(const uint8_t *bytes, size_t length, size_t capacity)
{
	static const char hex[] = "0123456789ABCDEF";
	static char output[FUZZ_TOKEN_BYTES * FUZZ_ESCAPE_INPUT_MAX];
	erx_log_escape_result_t result;
	size_t in, out;

	if (length > FUZZ_ESCAPE_INPUT_MAX)
		length = FUZZ_ESCAPE_INPUT_MAX;
	if (capacity > sizeof(output))
		capacity = sizeof(output);
	result = erx_log_escape(bytes, length, output, capacity);
	if (result.consumed > length || result.written > capacity ||
	    !line_safe(output, result.written))
		abort();

	out = 0;
	for (in = 0; in < result.consumed; in++) {
		if (passes(bytes[in])) {
			if (out >= result.written || (uint8_t)output[out] != bytes[in])
				abort();
			out++;
			continue;
		}
		if (result.written - out < FUZZ_TOKEN_BYTES || output[out] != '\\' ||
		    output[out + 1] != 'x' ||
		    output[out + 2] != hex[bytes[in] >> 4] ||
		    output[out + 3] != hex[bytes[in] & 0xf])
			abort();
		out += FUZZ_TOKEN_BYTES;
	}
	if (out != result.written)
		abort();
	if (result.consumed < length &&
	    capacity - result.written >= (passes(bytes[result.consumed]) ? 1 : FUZZ_TOKEN_BYTES))
		abort();
}

/*
 * The reader on any window: it ends or refuses within the bytes, never steps
 * backward, and renders every accepted record to a clean line.
 */
static void
fuzz_window(const uint8_t *bytes, size_t length)
{
	erx_log_view_t view;
	size_t offset, previous, rendered;

	offset = 0;
	for (;;) {
		previous = offset;
		switch (erx_log_next_record(bytes, length, &offset, fuzz_text, &view)) {
		case ERX_LOG_NEXT_RECORD:
			if (offset <= previous || offset > length ||
			    view.length > ERX_LOG_TEXT_MAX ||
			    !line_safe(view.text, view.length))
				abort();
			rendered = erx_log_render(&view, fuzz_line, sizeof(fuzz_line));
			if (rendered == 0 || fuzz_line[rendered - 1] != '\n' ||
			    !line_safe(fuzz_line, rendered - 1))
				abort();
			break;
		case ERX_LOG_NEXT_END:
		case ERX_LOG_NEXT_CORRUPT:
			if (offset != previous)
				abort();
			return;
		}
	}
}

/*
 * A read from the cursor: it reports a loss exactly when the cursor is older
 * than the ring, starts at the cursor or the oldest record, and shows whole,
 * clean records in sequence up to the cursor it returns.
 */
static void
fuzz_read(uint64_t cursor, size_t window_size)
{
	erx_log_copy_result_t copied;
	erx_log_view_t view;
	uint64_t expected;
	size_t offset, rendered;

	copied = erx_log_copy(&fuzz_log, cursor, fuzz_read_window, window_size);
	if (window_size < ERX_LOG_RECORD_MAX || cursor > fuzz_log.next_seq) {
		if (copied.status != ERX_EINVAL || copied.next_cursor != cursor ||
		    copied.written != 0)
			abort();
		return;
	}
	if (copied.status != ERX_OK || copied.written > window_size ||
	    copied.lost != (cursor < fuzz_log.oldest_seq ?
	    fuzz_log.oldest_seq - cursor : 0))
		abort();

	expected = cursor + copied.lost;
	offset = 0;
	while (erx_log_next_record(fuzz_read_window, copied.written, &offset,
	    fuzz_text, &view) == ERX_LOG_NEXT_RECORD) {
		rendered = erx_log_render(&view, fuzz_line, sizeof(fuzz_line));
		if (view.seq != expected++ || rendered == 0 ||
		    !line_safe(view.text, view.length) ||
		    !line_safe(fuzz_line, rendered - 1))
			abort();
	}
	if (offset != copied.written || expected != copied.next_cursor)
		abort();
	if (copied.records != copied.next_cursor - cursor - copied.lost)
		abort();
}

/*
 * A log driven by what a domain and a reader control, each operation one byte
 * and its own fields, so the input's framing is the operations':
 *
 *   0 LEN(2) N BYTES(N)  a debug line of LEN bytes; the UTCB holds BYTES, then
 *                        zeros, so a short operation can make a long line
 *   1 LEVEL N BYTES(N)   a kernel line with those bytes as string arguments
 *   2 LAG(2) WINDOW(2)   a read LAG behind the newest (below 0 past it)
 *   3 DELTA              the clock moves DELTA * 2^24 ns: 256 of them, 4 s
 *
 * Long lines of zeros escape four times over, so a few dozen operations wrap
 * the ring, and a clock that stands still keeps the rate limit in play.
 */
static void
fuzz_operations(const uint8_t *bytes, size_t length)
{
	static erx_utcb_t utcb;
	erx_log_rate_t rate;
	erx_utcb_length_t len;
	char string[FUZZ_STRING_MAX + 1];
	uint64_t now_ns, word, cursor;
	size_t at, count, window_size;
	erx_status_t status;
	uint8_t level;
	int lag;

	memset(&fuzz_log, 0, sizeof(fuzz_log));
	memset(&rate, 0, sizeof(rate));
	now_ns = 0;
	at = 0;
	while (at < length) {
		switch (bytes[at++] % 4) {
		case 0:
			if (length - at < 3)
				return;
			len.raw = (uint32_t)bytes[at] | (uint32_t)bytes[at + 1] << 8;
			count = bytes[at + 2];
			at += 3;
			if (length - at < count)
				return;
			for (size_t index = 0; index < ERX_MSG_WORDS; index++) {
				word = 0;
				if (index * sizeof(word) < count)
					memcpy(&word, bytes + at + index * sizeof(word),
					    count - index * sizeof(word) < sizeof(word) ?
					    count - index * sizeof(word) : sizeof(word));
				if (!erx_utcb_mr_store(&utcb, index, word))
					abort();
			}
			at += count;
			if (erx_log_debug(&fuzz_log, &rate, 7, now_ns, &utcb, len) !=
			    (len.raw > ERX_UTCB_BYTES_MAX ? ERX_EINVAL : ERX_OK))
				abort();
			break;
		case 1:
			if (length - at < 2)
				return;
			level = bytes[at];
			count = bytes[at + 1];
			at += 2;
			if (length - at < count)
				return;
			memcpy(string, bytes + at, count);
			string[count] = '\0';
			at += count;
			status = ERX_LOG_FORMAT(&fuzz_log, level, now_ns,
			    "%s %s %.*s %c %d %llx", string, string, (int)count,
			    string, level, (int)level, (unsigned long long)now_ns);
			if (status != (level >= ERX_LOG_LEVEL_ERROR &&
			    level <= ERX_LOG_LEVEL_DEBUG ? ERX_OK : ERX_EINVAL))
				abort();
			break;
		case 2:
			if (length - at < 4)
				return;
			lag = (int)((uint32_t)bytes[at] | (uint32_t)bytes[at + 1] << 8) - 8;
			window_size = (size_t)bytes[at + 2] | (size_t)bytes[at + 3] << 8;
			window_size = window_size * 2 % (sizeof(fuzz_read_window) + 1);
			at += 4;
			cursor = lag < 0 || (uint64_t)lag <= fuzz_log.next_seq ?
			    fuzz_log.next_seq - (uint64_t)lag : 0;
			fuzz_read(cursor, window_size);
			break;
		default:
			if (length - at < 1)
				return;
			now_ns += (uint64_t)bytes[at++] << 24;
			break;
		}
		if (fuzz_log.head - fuzz_log.tail > ERX_LOG_RING_BYTES)
			abort();
	}
}

/*
 * The first byte picks a target. The escaper's room is the next two bytes; the
 * window reader takes the rest as a window. libFuzzer's exact-length buffer
 * lets AddressSanitizer catch a read past either's input.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	if (length < 3)
		return (0);
	switch (bytes[0] % 3) {
	case 0:
		fuzz_escape(bytes + 3, length - 3,
		    (size_t)bytes[1] | (size_t)bytes[2] << 8);
		break;
	case 1:
		fuzz_window(bytes + 1, length - 1);
		break;
	default:
		fuzz_operations(bytes + 1, length - 1);
		break;
	}
	return (0);
}
