/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The part of Plan 9's <libc.h> erXos's copy of libmemdraw uses
 * (ORIGIN.md). Errors are reported by return value alone: werrstr keeps
 * no message, since a per-process error string would be state shared
 * between schedulers, and nothing in the copy prints.
 */
#ifndef ERX_LIBMEMDRAW_LIBC_H
#define ERX_LIBMEMDRAW_LIBC_H

#include <assert.h>
#include <stdlib.h>
#include <string.h>

/* The lock and format types draw.h names in structures and prototypes
 * the copy never uses. */
typedef struct Fmt Fmt;
typedef struct Lock { int unused; } Lock;
typedef struct QLock { int unused; } QLock;
typedef struct RWLock { int unused; } RWLock;

#define werrstr(...) ((void)0)

static inline void *
mallocz(size_t n, int clear)
{
	return clear ? calloc(1, n) : malloc(n);
}

#endif
