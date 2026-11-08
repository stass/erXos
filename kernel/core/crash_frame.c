/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The crash frame's writer: the record in base64 between a header line and an
 * end line (docs/design-kernel.md, "The root task"). erx_crash_frame_line is
 * pure; erx_crash_frame_write only hands its lines to the console effect, whose
 * bounded poll drops what a hung UART cannot take. A UART that stays hung leaves
 * a truncated frame; one that loses bytes mid-line leaves a corrupt one.
 * A flatline goes ahead of the frame, for the person at the console, when
 * the machine goes down; a task's fault the machine survives gets none.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/effects.h"
#include "erx/crash.h"

_Static_assert(ERX_CRASH_FRAME_RAW / 3 * 4 == ERX_CRASH_FRAME_LINE,
    "a full line is 57 bytes of base64");
_Static_assert(ERX_CRASH_FRAME_RAW % 3 == 0, "only the last line pads");
_Static_assert((ERX_CRASH_SIZE + ERX_CRASH_FRAME_RAW - 1) / ERX_CRASH_FRAME_RAW ==
    ERX_CRASH_FRAME_LINES_MAX, "the longest record fills the frame's lines");

/*
 * A heart monitor's flatline, and the captain's log that introduces the
 * record below it. Printable ASCII, at most 36 columns, so it fits a phone's
 * web console, and at most 12 lines, up to four of them empty, with no blank
 * at a line's end. No line starts with "--", so neither marker can begin one
 * and a reader looking for the header line passes over it; no line names
 * "erx" or "crash", so no harness pattern meets it (test/host/crash_test.rb
 * holds it to these rules).
 */
static const char erx_crash_frame_art[] =
    "   _      _\n"
    "__/ \\  /\\/ \\______________________\n"
    "     \\/\n"
    "            He's dead, Jim.\n"
    "\n"
    "\n"
    "\n"
    "CAPTAIN'S LOG, SUPPLEMENTAL.\n"
    "\n"
    "The ship was destroyed:\n";

static void erx_crash_frame_art_write(void);
static size_t erx_crash_frame_encode(const uint8_t *, size_t, char *);
static size_t erx_crash_frame_header(uint32_t, uint32_t, char *);
static bool erx_crash_frame_legal(uint32_t, uint32_t);
static size_t erx_crash_frame_put(char *, const char *, size_t);

/* The header line alone bounds what follows. */
static bool
erx_crash_frame_legal(uint32_t form, uint32_t length)
{
	if (form == ERX_CRASH_FORM_BRIEF)
		return (length == ERX_CRASH_BRIEF_SIZE);
	return (form == ERX_CRASH_FORM_FULL && length >= ERX_CRASH_RECORD_SIZE &&
	    length <= ERX_CRASH_SIZE);
}

uint32_t
erx_crash_frame_line_count(uint32_t length)
{
	uint32_t lines;

	lines = length / ERX_CRASH_FRAME_RAW;
	if (length % ERX_CRASH_FRAME_RAW != 0)
		lines++;
	return (lines + 2);
}

static size_t
erx_crash_frame_put(char *line, const char *text, size_t length)
{
	__builtin_memcpy(line, text, length);
	return (length);
}

/* "--erx-crash-begin FORM LENGTH\n", which the frame's rules keep short. */
static size_t
erx_crash_frame_header(uint32_t form, uint32_t length, char *line)
{
	static const char brief[] = " brief ", full[] = " full ";
	char digits[10];
	size_t used, count;

	used = erx_crash_frame_put(line, ERX_CRASH_FRAME_BEGIN_STRING,
	    ERX_CRASH_FRAME_BEGIN_SIZE);
	if (form == ERX_CRASH_FORM_BRIEF)
		used += erx_crash_frame_put(line + used, brief, sizeof(brief) - 1);
	else
		used += erx_crash_frame_put(line + used, full, sizeof(full) - 1);
	count = 0;
	do {
		digits[count++] = (char)('0' + length % 10);
		length /= 10;
	} while (length != 0);
	while (count > 0)
		line[used++] = digits[--count];
	line[used++] = '\n';
	return (used);
}

/* One group of three bytes at a time; RFC 4648 with padding. */
static size_t
erx_crash_frame_encode(const uint8_t *in, size_t length, char *out)
{
	static const char alphabet[] =
	    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t used;
	uint32_t group, have;

	used = 0;
	for (size_t index = 0; index < length; index += 3) {
		have = length - index < 3 ? (uint32_t)(length - index) : 3;
		group = (uint32_t)in[index] << 16;
		if (have > 1)
			group |= (uint32_t)in[index + 1] << 8;
		if (have > 2)
			group |= in[index + 2];
		out[used++] = alphabet[(group >> 18) & 0x3f];
		out[used++] = alphabet[(group >> 12) & 0x3f];
		out[used++] = have > 1 ? alphabet[(group >> 6) & 0x3f] : '=';
		out[used++] = have > 2 ? alphabet[group & 0x3f] : '=';
	}
	return (used);
}

size_t
erx_crash_frame_line(const uint8_t *record, uint32_t form, uint32_t length,
    uint32_t index, char *line)
{
	uint32_t count, offset, raw;
	size_t used;

	if (!erx_crash_frame_legal(form, length))
		return (0);
	count = erx_crash_frame_line_count(length);
	if (index >= count)
		return (0);
	if (index == 0)
		return (erx_crash_frame_header(form, length, line));
	if (index == count - 1) {
		used = erx_crash_frame_put(line, ERX_CRASH_FRAME_END_STRING,
		    ERX_CRASH_FRAME_END_SIZE);
	} else {
		offset = (index - 1) * ERX_CRASH_FRAME_RAW;
		raw = length - offset < ERX_CRASH_FRAME_RAW ? length - offset :
		    ERX_CRASH_FRAME_RAW;
		used = erx_crash_frame_encode(record + offset, raw, line);
	}
	line[used++] = '\n';
	return (used);
}

/*
 * One line a write, as the frame's own lines go: the console sends each short
 * write whole, so this writer never leaves a line half written and a second
 * writer's header line still begins a line. Every line ends in a newline.
 */
static void
erx_crash_frame_art_write(void)
{
	size_t start;

	start = 0;
	for (size_t last = 0; last < sizeof(erx_crash_frame_art) - 1; last++) {
		if (erx_crash_frame_art[last] != '\n')
			continue;
		erx_effect_console_write(erx_crash_frame_art + start,
		    last + 1 - start);
		start = last + 1;
	}
}

void
erx_crash_frame_write(const void *buffer, erx_crash_end_t end)
{
	erx_crash_brief_t header;
	char line[ERX_CRASH_FRAME_LINE_BYTES];
	size_t used;
	uint32_t count;

	__builtin_memcpy(&header, buffer, sizeof(header));
	if (!erx_crash_frame_legal(header.form, header.length))
		return;
	erx_effect_console_write("\n", 1);
	/* No default: a new kind of end that states no case fails to build. */
	switch (end) {
	case ERX_CRASH_END_MACHINE:
		erx_crash_frame_art_write();
		break;
	case ERX_CRASH_END_TASK:
		break;
	}
	count = erx_crash_frame_line_count(header.length);
	for (uint32_t index = 0; index < count; index++) {
		used = erx_crash_frame_line(buffer, header.form, header.length, index,
		    line);
		erx_effect_console_write(line, used);
	}
}
