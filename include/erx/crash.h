/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CRASH_H
#define ERX_CRASH_H

/*
 * The crash record's checker and the crash frame's codec
 * (docs/design-kernel.md, "The root task"). A record read back after a reset
 * and bytes from a serial port are both untrusted: the checker and the reader
 * bound every field before they use it and refuse with a status, and neither
 * prints. What they accept holds text that is printable ASCII or a newline;
 * a caller still shows it only through its terminal's one escaping function.
 *
 * The writer's side, which a kernel's end path calls, is erx/core/crash.h.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/crash.h"

/* One frame line and its newline; the header line is shorter than a full one. */
#define ERX_CRASH_FRAME_LINE_BYTES	(ERX_CRASH_FRAME_LINE + 1)
/* The record bytes a full line holds. */
#define ERX_CRASH_FRAME_RAW		(ERX_CRASH_FRAME_LINE / 4 * 3)

/* The first thing wrong with a record, in the order the checker looks. */
typedef enum erx_crash_check {
	ERX_CRASH_CHECK_OK = 0,
	ERX_CRASH_CHECK_SHORT,		/* fewer bytes than the record's length */
	ERX_CRASH_CHECK_MAGIC,
	ERX_CRASH_CHECK_VERSION,
	ERX_CRASH_CHECK_FORM,
	ERX_CRASH_CHECK_LENGTH,		/* outside what the form admits */
	ERX_CRASH_CHECK_CRC,
	ERX_CRASH_CHECK_CAUSE,
	ERX_CRASH_CHECK_CPU,
	ERX_CRASH_CHECK_BOOT,		/* boot value and slot are no allowed pair */
	ERX_CRASH_CHECK_PADDING,
	ERX_CRASH_CHECK_NFRAMES,
	ERX_CRASH_CHECK_FAULT,		/* the fault record contradicts the cause */
	ERX_CRASH_CHECK_REGS,		/* registers where the cause has none */
	ERX_CRASH_CHECK_FRAMES,		/* frames past nframes */
	ERX_CRASH_CHECK_TEXT		/* a byte neither printable nor a newline */
} erx_crash_check_t;

typedef enum erx_crash_read_status {
	ERX_CRASH_READ_ABSENT = 1,	/* no header line in the log */
	ERX_CRASH_READ_VALID,		/* record holds a checked record */
	ERX_CRASH_READ_TRUNCATED,	/* the frame stops before its end line */
	ERX_CRASH_READ_CORRUPT
} erx_crash_read_status_t;

typedef enum erx_crash_read_reason {
	ERX_CRASH_REASON_NONE = 0,
	ERX_CRASH_REASON_CUT,		/* the log stops inside the frame */
	ERX_CRASH_REASON_EARLY_END,	/* the end line came before the last line */
	ERX_CRASH_REASON_HEADER,	/* the header line breaks the frame's rules */
	ERX_CRASH_REASON_SECOND_HEADER,
	ERX_CRASH_REASON_LINE_LENGTH,
	ERX_CRASH_REASON_BASE64,
	ERX_CRASH_REASON_NO_END,	/* another line where the end line belongs */
	ERX_CRASH_REASON_RECORD		/* the record fails; see check */
} erx_crash_read_reason_t;

/*
 * What erx_crash_frame_read found. frame_start and frame_end are the offsets
 * in the log of the frame's lines, for a report that keeps them; both are
 * zero when status is ABSENT. length is the header's, zero until it parses.
 */
typedef struct erx_crash_read {
	erx_crash_read_status_t status;
	erx_crash_read_reason_t reason;
	erx_crash_check_t check;
	uint32_t	length;
	size_t		frame_start;
	size_t		frame_end;
} erx_crash_read_t;

/*
 * Checks the record at bytes, of which available can be read: everything the
 * design's reader checks, and that no byte the writer leaves zero is set.
 * bytes need no alignment and no other party may write them during the call:
 * a caller reading shared memory checks a private copy.
 */
erx_crash_check_t erx_crash_check(const void *bytes, size_t available);

/* What a check status means, for a diagnostic. Static text; never NULL. */
const char *erx_crash_check_reason(erx_crash_check_t status);

/* CRC-32C of length bytes, as the record's crc field holds it. */
uint32_t erx_crash_crc32c(const void *bytes, size_t length);

/* How many lines a frame of a record of length bytes has, header and end. */
uint32_t erx_crash_frame_line_count(uint32_t length);

/*
 * Writes line index of the frame of the record's first length bytes to line,
 * of ERX_CRASH_FRAME_LINE_BYTES, newline included, and returns its length.
 * Pure. Returns 0 with nothing to use when form and length are outside the
 * frame's rules or index is past the frame's last line.
 */
size_t erx_crash_frame_line(const uint8_t *record, uint32_t form,
    uint32_t length, uint32_t index, char *line);

/*
 * Finds the first frame in the log's length bytes and decodes it into record,
 * of ERX_CRASH_SIZE bytes, which stays all zero unless status is VALID. Lines
 * end in a newline, with one carriage return before it allowed, and a line
 * with no newline at the end of the log is a cut one. A caller that must skip
 * what comes before the banner passes the log from there.
 */
erx_crash_read_t erx_crash_frame_read(const uint8_t *log, size_t length,
    uint8_t *record);

#endif /* ERX_CRASH_H */
