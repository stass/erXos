/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The line gather of line_gather.h. A newline ends a line and is not passed on, since
 * the debug log ends each record's line itself; the carriage returns ERTS puts before it
 * (erts_printf_add_cr_to_stderr) go with it, as the console adds its own. So a carriage
 * return is only counted until the next byte shows whether a newline follows: a line
 * that fills the buffer exactly and then ends in CR-LF is one record, not two.
 */

#include <stddef.h>

#include "liberx/backend/core/line_gather.h"

static void	line_gather_put(erx_line_gather_t *, char, erx_line_gather_emit_t *, void *);
static void	line_gather_flush(erx_line_gather_t *, erx_line_gather_emit_t *, void *);

void
erx_line_gather_write(erx_line_gather_t *gather, const void *bytes, size_t length,
    erx_line_gather_emit_t *emit, void *context)
{
	const char *const text = bytes;

	for (size_t at = 0; at < length; at++) {
		switch (text[at]) {
		case '\n':
			gather->returns = 0;
			line_gather_flush(gather, emit, context);
			break;
		case '\r':
			gather->returns++;
			break;
		default:
			/* The carriage returns were inside the line, so they are part of it. */
			for (; gather->returns > 0; gather->returns--)
				line_gather_put(gather, '\r', emit, context);
			line_gather_put(gather, text[at], emit, context);
			break;
		}
	}
}

/* Adds one byte of the line, handing on a full buffer first. */
static void
line_gather_put(erx_line_gather_t *gather, char byte, erx_line_gather_emit_t *emit, void *context)
{
	if (gather->length == sizeof(gather->bytes))
		line_gather_flush(gather, emit, context);
	gather->bytes[gather->length++] = byte;
}

/* Hands on what is held, a whole line or a full buffer's piece, and starts empty. */
static void
line_gather_flush(erx_line_gather_t *gather, erx_line_gather_emit_t *emit, void *context)
{
	emit(context, gather->bytes, gather->length);
	gather->length = 0;
}
