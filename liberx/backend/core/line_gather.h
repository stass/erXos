/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_LINE_GATHER_H
#define ERX_BACKEND_LINE_GATHER_H

/*
 * Gathers a runtime's C output into whole lines (docs/design-runtime.md, "The console
 * and standard I/O"). ERTS writes standard error a fragment or a byte at a time, so each
 * write is a piece of a line; the gather holds the pieces until a newline ends the line
 * or the buffer fills, and only then hands the line on, so a line reaches the debug log
 * as one record rather than as a call per byte, and a line no longer than the buffer
 * reaches the console's sink whole.
 *
 * Pure over the gather it is handed: the caller owns the gather, one per thread, and the
 * emit function is the only effect.
 */

#include <stddef.h>

#include "erx/abi.h"

/* A line longer than one debug log call carries is handed on in pieces of this size. */
#define ERX_LINE_GATHER_BYTES	ERX_UTCB_BYTES_MAX

typedef struct erx_line_gather {
	size_t	length;				/* bytes held, all of one unfinished line */
	size_t	returns;			/* carriage returns after them, not yet known to end the line */
	char	bytes[ERX_LINE_GATHER_BYTES];
} erx_line_gather_t;

/*
 * Receives one line, without its newline and the carriage returns just before it, or a
 * full buffer's piece of a longer line. length is at most ERX_LINE_GATHER_BYTES, and may
 * be 0 for an empty line.
 */
typedef void erx_line_gather_emit_t(void *context, const char *line, size_t length);

/* Adds length bytes, calling emit for each line they finish and each buffer they fill. */
void	erx_line_gather_write(erx_line_gather_t *gather, const void *bytes, size_t length,
	    erx_line_gather_emit_t *emit, void *context);

#endif /* ERX_BACKEND_LINE_GATHER_H */
