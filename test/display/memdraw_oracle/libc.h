/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The part of Plan 9's <libc.h> and <pool.h> that 9front's libmemdraw
 * and libdraw use, for the 9front build: the unmodified sources compiled
 * for the host as the oracle of erx_memdraw (docs/design-display.md, "The
 * pixel primitives"; test/display/memdraw_shapes.c). Nothing here
 * changes what the sources compute: the image pool is calloc, which only
 * makes row padding deterministic, and printing, format verbs and the
 * caller's pc do nothing.
 */
#ifndef ERX_ORACLE_LIBC_H
#define ERX_ORACLE_LIBC_H

#include <assert.h>
#include <stdlib.h>
#include <string.h>

typedef struct Fmt Fmt;
typedef struct Lock { int unused; } Lock;
typedef struct QLock { int unused; } QLock;
typedef struct RWLock { int unused; } RWLock;

typedef struct Pool {
	char *name;
	void (*move)(void *, void *);
} Pool;

#define werrstr(...) ((void)0)
#define print(...) ((void)0)
#define fmtinstall(c, f) ((void)(c), (void)(f))
#define getcallerpc(x) ((uintptr)0)
#define poolalloc(pool, n) calloc(1, (n))
#define poolfree(pool, p) free(p)
#define abs(x) ((x) < 0 ? -(x) : (x))

static inline void *
mallocz(size_t n, int clear)
{
	return clear ? calloc(1, n) : malloc(n);
}

/* The oracle runs on one thread. */
static inline int
_tas(int *p)
{
	int old = *p;

	*p = 1;
	return old;
}

/*
 * Plan 9's type model, ILP32: long is 32 bits, as ulong is, which
 * the sources assume (fillpoly.c's sign tests cast long through
 * ulong). Defined after the host's headers, so it reaches only
 * the Plan 9 sources and headers that follow.
 */
#define long int

#endif
