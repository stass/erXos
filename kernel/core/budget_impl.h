/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BUDGET_IMPL_H
#define ERX_BUDGET_IMPL_H

/*
 * The budget core's records. Only kernel/core/budget.c includes this
 * file (and the core's host test driver), with kernel/core/page.c, which
 * moves a reserve's pool chain and nothing else; the budget-records-private
 * chokepoint enforces it, so every write of a counter is in budget.c, the
 * record cache's pages among them: a page's charge and its pin are counters.
 */

#include <stdatomic.h>
#include <stdbool.h>

#include "erx/budget.h"
#include "erx/page.h"

/*
 * A cache page of kernel records: this header at the start of the page,
 * then its records, each 64-byte aligned. A page with a free record is on
 * its cache's list; a full page is on none.
 */
struct erx_kcache_page {
	struct erx_kcache_page *prev;	/* on its cache's list of pages with a
					 * free record; NULL at either end */
	struct erx_kcache_page *next;
	erx_budget_t	*owner;		/* the budget whose cache it is; fixed */
	uint64_t	 taken;		/* bit i: record i is taken */
	uint64_t	 kept;		/* bit i: record i is kept for the boot,
					 * never freed; any bit pins the page */
	erx_kcache_kind_t kind;		/* fixed when the page joins its cache */
};

/* One kind's cache: the pages a budget carves that kind's records from. */
typedef struct erx_kcache {
	struct erx_kcache_page *partial; /* the pages with a free record */
	erx_npages_t	 npages;	/* every page of this cache: charged to
					 * the budget's used */
} erx_kcache_t;

struct erx_budget {
	erx_budget_t	*parent;	/* NULL for the root; fixed */
	struct erx_irq	*watch;		/* the IRQ object of the watch; NULL for none */
	erx_npages_t	 guarantee;	/* pages carved from the parent: its floor */
	erx_npages_t	 cap;		/* pages its tree may spend: its ceiling;
					 * never below guarantee, equal to it for
					 * a wall */
	erx_npages_t	 used;		/* pages charged here and not released;
					 * at a dead budget, what still names it */
	erx_npages_t	 carved;	/* its live children's guarantees */
	erx_npages_t	 lent;		/* what its live children borrow */
	erx_npages_t	 pinned;	/* pages its tree holds for the boot */
	erx_npages_t	 threshold;	/* spending at which the watch fires; 0 unarmed */
	uint32_t	 depth;		/* 0 for the root; below ERX_BUDGET_DEPTH_MAX */
	erx_budget_kind_t kind;		/* fixed at carving */
	erx_kcache_slot_t home;		/* its own record in its parent's cache;
					 * no slot for the root; fixed */
	erx_kcache_t	 caches[ERX_KCACHE_NKINDS]; /* its records' pages, by
					 * kind; under its lock */
	_Atomic bool	 dead;		/* closed: takes no charge, and its spending
					 * is counted in its parent's used; written
					 * under the lock, read without it by
					 * erx_budget_dead */
};

struct erx_reserve {
	erx_budget_t	*budget;	/* who pays; fixed */
	erx_npages_t	 charged;	/* promises admitted at the budget */
	erx_npages_t	 backed;	/* pages held, in use or pooled */
	erx_npages_t	 pooled;	/* backed pages not yet in use */
	erx_plist_t	 pool;		/* those pages, chained through their
					 * page records; only kernel/core/page.c
					 * moves them, under the owner's lock of
					 * the step that counts them */
};

#endif /* ERX_BUDGET_IMPL_H */
