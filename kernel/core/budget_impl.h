/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BUDGET_IMPL_H
#define ERX_BUDGET_IMPL_H

/*
 * The budget core's records. Only kernel/core/budget.c includes this
 * file (and the core's host test driver), which the budget-records-private
 * chokepoint enforces, so every write of a counter is in budget.c.
 */

#include "erx/budget.h"

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
	bool		 dead;		/* closed: takes no charge, and its spending
					 * is counted in its parent's used */
};

struct erx_reserve {
	erx_budget_t	*budget;	/* who pays; fixed */
	erx_npages_t	 charged;	/* promises admitted at the budget */
	erx_npages_t	 backed;	/* pages held, in use or pooled */
	erx_npages_t	 pooled;	/* backed pages not yet in use */
};

#endif /* ERX_BUDGET_IMPL_H */
