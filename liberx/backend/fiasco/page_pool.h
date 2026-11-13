/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PAGE_POOL_H
#define ERX_FIASCO_PAGE_POOL_H

#include <stdint.h>

#include "erx/abi.h"

/*
 * The pool of free pages (docs/design-stopgap.md, "The pool"). A page's identity
 * is its address in the window, and the free pages are a list threaded through
 * the pages themselves, so the pool costs no memory of its own. A free page
 * holds its link and whatever its last holder left; it is zeroed when taken, so
 * what a taker sees never depends on who held the page before.
 *
 * held_pages counts the pages taken and not yet put back: the budget topic's
 * used (docs/design-stopgap.md, "Reporting a budget"). The service alone calls
 * the pool, one call at a time, so the count needs no lock of its own.
 *
 * This core touches only the pages it is handed, so it builds for the host.
 */
typedef struct erx_fiasco_pool {
	uintptr_t	head;		/* first free page's address, or 0 */
	uint64_t	free_pages;
	uint64_t	held_pages;	/* taken and not put back */
	uint64_t	pages;		/* the pages added as the pool was built: the machine topic's memory_total */
} erx_fiasco_pool_t;

/* Adds one page the pool has never handed out, as the pool is built. */
void		erx_fiasco_pool_add(erx_fiasco_pool_t *, uintptr_t);

/*
 * Gives back one page the pool handed out. No one may hold a mapping of it any more.
 * held_pages stays at 0 rather than wrap, should a page come back that was never taken.
 */
void		erx_fiasco_pool_put(erx_fiasco_pool_t *, uintptr_t);

/* A zeroed page's window address, or 0 when the pool is empty. */
uintptr_t	erx_fiasco_pool_take(erx_fiasco_pool_t *);

/*
 * The contiguous pool (docs/design-stopgap.md, "The pool"): one flexpage's pages,
 * handed out first fit, each run aligned to a page, on the claim, unverified against the
 * architecture's report of its writeback granule (TODO.md), that no cache-writeback
 * granule exceeds a page. A run is never given back: an unconfined device may still write it.
 *
 * The flexpage is as large as the devices' memory the manifest declares: the
 * smallest power of two that holds the total, at least 2 MiB, at most 16 MiB
 * (erx_fiasco_contig_order). Each device's memory is made once, so runs of that
 * total always fit. The packer counts the same figure in what the boot keeps
 * (Manifest::RootStartup.contiguous_pool_bytes in tools/lib/erx/manifest.rb, which
 * copies the two orders).
 */
#define ERX_FIASCO_CONTIG_MIN_ORDER	21u
#define ERX_FIASCO_CONTIG_MAX_ORDER	24u
/* The pages of the largest pool. */
#define ERX_FIASCO_CONTIG_PAGES	((uint32_t)((UINT64_C(1) << ERX_FIASCO_CONTIG_MAX_ORDER) / ERX_PAGE_SIZE))
#define ERX_FIASCO_CONTIG_NONE	UINT32_MAX

typedef struct erx_fiasco_contig {
	uint32_t	pages;					/* the pool's pages, at most ERX_FIASCO_CONTIG_PAGES */
	uint64_t	used[ERX_FIASCO_CONTIG_PAGES / 64];	/* bit n: page n is held */
} erx_fiasco_contig_t;

/*
 * The order of the flexpage a pool for this many declared bytes takes: the smallest
 * power of two at least bytes, and at least ERX_FIASCO_CONTIG_MIN_ORDER; 0 when that
 * is past ERX_FIASCO_CONTIG_MAX_ORDER.
 */
unsigned	erx_fiasco_contig_order(uint64_t bytes);

/*
 * How many of a pool's first pages, the pool starting at physical address physical and
 * holding pages pages, lie wholly inside CPU addresses first through last: the limit
 * erx_fiasco_contig_take takes for a device that reaches only those. 0 when the window starts above the pool's first
 * page, so such a device gets nothing rather than a run the take cannot place; the pool
 * is the lowest RAM sigma0 has free, and no supported board's window starts above it.
 */
uint32_t	erx_fiasco_contig_reach(uint64_t physical, uint32_t pages, uint64_t first, uint64_t last);

/* The first page of a run of this length wholly below page limit, or ERX_FIASCO_CONTIG_NONE. */
uint32_t	erx_fiasco_contig_take(erx_fiasco_contig_t *, uint32_t pages, uint32_t limit);

#endif /* ERX_FIASCO_PAGE_POOL_H */
