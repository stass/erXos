/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The crash frame's reader over a serial log. Every byte of the log is
 * untrusted: a line is only ever a span of the log, the header line bounds what
 * the record can hold before a payload line is read, and every line's length is
 * known before it is decoded. Its own file, so a kernel that links the writer
 * links no reader.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/crash.h"

#define ERX_CRASH_LENGTH_DIGITS	5	/* the digits of ERX_CRASH_SIZE */

_Static_assert(ERX_CRASH_SIZE < 100000, "the header's length has five digits");

/* One line of the log: terminated says a newline ended it. */
typedef struct erx_crash_line {
	const uint8_t	*bytes;
	size_t		 length;
	size_t		 next;
	bool		 terminated;
} erx_crash_line_t;

typedef struct erx_crash_header {
	uint32_t	form;
	uint32_t	length;
} erx_crash_header_t;

static bool erx_crash_bytes_equal(const uint8_t *, const void *, size_t);
static bool erx_crash_line_is(const erx_crash_line_t *, const char *, size_t);
static bool erx_crash_line_is_header(const erx_crash_line_t *);
static erx_crash_line_t erx_crash_line_next(const uint8_t *, size_t, size_t);
static int erx_crash_read_base64_value(uint8_t);
static bool erx_crash_read_decode(const erx_crash_line_t *, uint32_t, uint8_t *);
static erx_crash_read_t erx_crash_read_frame(const uint8_t *, size_t,
    erx_crash_line_t, size_t, uint8_t *);
static bool erx_crash_read_header(const erx_crash_line_t *, erx_crash_header_t *);
static bool erx_crash_read_number(const uint8_t *, size_t, uint32_t *);
static erx_crash_read_t erx_crash_read_done(erx_crash_read_t,
    erx_crash_read_status_t, erx_crash_read_reason_t, size_t);

/* The cores link no memcmp, and nothing here is secret. */
static bool
erx_crash_bytes_equal(const uint8_t *bytes, const void *other, size_t length)
{
	const uint8_t *expected;

	expected = other;
	for (size_t index = 0; index < length; index++) {
		if (bytes[index] != expected[index])
			return (false);
	}
	return (true);
}

static erx_crash_line_t
erx_crash_line_next(const uint8_t *log, size_t length, size_t start)
{
	erx_crash_line_t line;
	size_t index;

	for (index = start; index < length && log[index] != '\n'; index++)
		continue;
	line.bytes = log + start;
	line.length = index - start;
	line.terminated = index < length;
	line.next = line.terminated ? index + 1 : length;
	if (line.terminated && line.length > 0 && log[index - 1] == '\r')
		line.length--;
	return (line);
}

static bool
erx_crash_line_is(const erx_crash_line_t *line, const char *text, size_t length)
{
	return (line->length == length &&
	    erx_crash_bytes_equal(line->bytes, text, length));
}

/* The marker alone, or the marker and a space; anything else is ordinary text. */
static bool
erx_crash_line_is_header(const erx_crash_line_t *line)
{
	if (line->length < ERX_CRASH_FRAME_BEGIN_SIZE ||
	    !erx_crash_bytes_equal(line->bytes, ERX_CRASH_FRAME_BEGIN_STRING,
	    ERX_CRASH_FRAME_BEGIN_SIZE))
		return (false);
	return (line->length == ERX_CRASH_FRAME_BEGIN_SIZE ||
	    line->bytes[ERX_CRASH_FRAME_BEGIN_SIZE] == ' ');
}

/* Decimal with no leading zero, in at most ERX_CRASH_LENGTH_DIGITS digits. */
static bool
erx_crash_read_number(const uint8_t *bytes, size_t length, uint32_t *value)
{
	uint32_t result;

	if (length == 0 || length > ERX_CRASH_LENGTH_DIGITS ||
	    (bytes[0] == '0' && length > 1))
		return (false);
	result = 0;
	for (size_t index = 0; index < length; index++) {
		if (bytes[index] < '0' || bytes[index] > '9')
			return (false);
		result = result * 10 + (uint32_t)(bytes[index] - '0');
	}
	*value = result;
	return (true);
}

/* "--erx-crash-begin FORM LENGTH", where FORM fixes what LENGTH may be. */
static bool
erx_crash_read_header(const erx_crash_line_t *line, erx_crash_header_t *header)
{
	static const char brief[] = "brief ", full[] = "full ";
	const uint8_t *rest;
	size_t left;

	if (line->length <= ERX_CRASH_FRAME_BEGIN_SIZE + 1)
		return (false);
	rest = line->bytes + ERX_CRASH_FRAME_BEGIN_SIZE + 1;
	left = line->length - ERX_CRASH_FRAME_BEGIN_SIZE - 1;
	if (left > sizeof(brief) - 1 &&
	    erx_crash_bytes_equal(rest, brief, sizeof(brief) - 1)) {
		header->form = ERX_CRASH_FORM_BRIEF;
		rest += sizeof(brief) - 1;
		left -= sizeof(brief) - 1;
	} else if (left > sizeof(full) - 1 &&
	    erx_crash_bytes_equal(rest, full, sizeof(full) - 1)) {
		header->form = ERX_CRASH_FORM_FULL;
		rest += sizeof(full) - 1;
		left -= sizeof(full) - 1;
	} else {
		return (false);
	}
	if (!erx_crash_read_number(rest, left, &header->length))
		return (false);
	if (header->form == ERX_CRASH_FORM_BRIEF)
		return (header->length == ERX_CRASH_BRIEF_SIZE);
	return (header->length >= ERX_CRASH_RECORD_SIZE &&
	    header->length <= ERX_CRASH_SIZE);
}

static int
erx_crash_read_base64_value(uint8_t byte)
{
	if (byte >= 'A' && byte <= 'Z')
		return (byte - 'A');
	if (byte >= 'a' && byte <= 'z')
		return (byte - 'a' + 26);
	if (byte >= '0' && byte <= '9')
		return (byte - '0' + 52);
	if (byte == '+')
		return (62);
	if (byte == '/')
		return (63);
	return (-1);
}

/*
 * Decodes one line of exactly the length raw bytes take. Padding appears only
 * where raw says it must, and the bits it hides are zero, so one record has
 * one encoding.
 */
static bool
erx_crash_read_decode(const erx_crash_line_t *line, uint32_t raw, uint8_t *out)
{
	const uint8_t *in;
	uint32_t group, have, written;
	int value;

	in = line->bytes;
	written = 0;
	for (size_t index = 0; index < line->length; index += 4) {
		have = raw - written < 3 ? raw - written : 3;
		group = 0;
		for (uint32_t digit = 0; digit < 4; digit++) {
			if (digit > have) {
				if (in[index + digit] != '=')
					return (false);
				group <<= 6;
				continue;
			}
			value = erx_crash_read_base64_value(in[index + digit]);
			if (value < 0)
				return (false);
			group = (group << 6) | (uint32_t)value;
		}
		if ((have < 3 && (group & 0xff) != 0) ||
		    (have < 2 && (group & 0xff00) != 0))
			return (false);
		out[written++] = (uint8_t)(group >> 16);
		if (have > 1)
			out[written++] = (uint8_t)(group >> 8);
		if (have > 2)
			out[written++] = (uint8_t)group;
	}
	return (true);
}

static erx_crash_read_t
erx_crash_read_done(erx_crash_read_t result, erx_crash_read_status_t status,
    erx_crash_read_reason_t reason, size_t frame_end)
{
	result.status = status;
	result.reason = reason;
	result.frame_end = frame_end;
	return (result);
}

/* Reads the frame whose header line is first, at offset start of the log. */
static erx_crash_read_t
erx_crash_read_frame(const uint8_t *log, size_t length, erx_crash_line_t line,
    size_t start, uint8_t *record)
{
	erx_crash_read_t result;
	erx_crash_header_t header;
	uint32_t lines, offset, raw;
	size_t expected, cursor;
	uint32_t index;

	result = (erx_crash_read_t){ .frame_start = start, .frame_end = line.next };
	if (!line.terminated)
		return (erx_crash_read_done(result, ERX_CRASH_READ_TRUNCATED,
		    ERX_CRASH_REASON_CUT, line.next));
	if (!erx_crash_read_header(&line, &header))
		return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
		    ERX_CRASH_REASON_HEADER, line.next));
	result.length = header.length;

	lines = erx_crash_frame_line_count(header.length) - 2;
	cursor = line.next;
	for (index = 0; index < lines; index++) {
		line = erx_crash_line_next(log, length, cursor);
		cursor = line.next;
		if (!line.terminated)
			return (erx_crash_read_done(result, ERX_CRASH_READ_TRUNCATED,
			    ERX_CRASH_REASON_CUT, cursor));
		if (erx_crash_line_is(&line, ERX_CRASH_FRAME_END_STRING,
		    ERX_CRASH_FRAME_END_SIZE))
			return (erx_crash_read_done(result, ERX_CRASH_READ_TRUNCATED,
			    ERX_CRASH_REASON_EARLY_END, cursor));
		if (erx_crash_line_is_header(&line))
			return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
			    ERX_CRASH_REASON_SECOND_HEADER, cursor));
		offset = index * ERX_CRASH_FRAME_RAW;
		raw = header.length - offset < ERX_CRASH_FRAME_RAW ?
		    header.length - offset : ERX_CRASH_FRAME_RAW;
		expected = (raw + 2) / 3 * 4;
		if (line.length != expected)
			return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
			    ERX_CRASH_REASON_LINE_LENGTH, cursor));
		if (!erx_crash_read_decode(&line, raw, record + offset))
			return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
			    ERX_CRASH_REASON_BASE64, cursor));
	}

	line = erx_crash_line_next(log, length, cursor);
	cursor = line.next;
	if (!line.terminated)
		return (erx_crash_read_done(result, ERX_CRASH_READ_TRUNCATED,
		    ERX_CRASH_REASON_CUT, cursor));
	if (erx_crash_line_is_header(&line))
		return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
		    ERX_CRASH_REASON_SECOND_HEADER, cursor));
	if (!erx_crash_line_is(&line, ERX_CRASH_FRAME_END_STRING,
	    ERX_CRASH_FRAME_END_SIZE))
		return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
		    ERX_CRASH_REASON_NO_END, cursor));

	/* The record's own form and length equal the frame's. */
	result.check = erx_crash_check(record, header.length);
	if (result.check == ERX_CRASH_CHECK_OK &&
	    !erx_crash_bytes_equal(record + ERX_CRASH_BRIEF_OFF_FORM, &header.form,
	    sizeof(header.form)))
		result.check = ERX_CRASH_CHECK_FORM;
	if (result.check == ERX_CRASH_CHECK_OK &&
	    !erx_crash_bytes_equal(record + ERX_CRASH_BRIEF_OFF_LENGTH, &header.length,
	    sizeof(header.length)))
		result.check = ERX_CRASH_CHECK_LENGTH;
	if (result.check != ERX_CRASH_CHECK_OK)
		return (erx_crash_read_done(result, ERX_CRASH_READ_CORRUPT,
		    ERX_CRASH_REASON_RECORD, cursor));
	return (erx_crash_read_done(result, ERX_CRASH_READ_VALID,
	    ERX_CRASH_REASON_NONE, cursor));
}

erx_crash_read_t
erx_crash_frame_read(const uint8_t *log, size_t length, uint8_t *record)
{
	erx_crash_read_t result;
	erx_crash_line_t line;
	size_t cursor;

	__builtin_memset(record, 0, ERX_CRASH_SIZE);
	result = (erx_crash_read_t){ .status = ERX_CRASH_READ_ABSENT };
	for (cursor = 0; cursor < length; cursor = line.next) {
		line = erx_crash_line_next(log, length, cursor);
		if (erx_crash_line_is_header(&line)) {
			result = erx_crash_read_frame(log, length, line, cursor, record);
			break;
		}
	}
	if (result.status != ERX_CRASH_READ_VALID)
		__builtin_memset(record, 0, ERX_CRASH_SIZE);
	return (result);
}
