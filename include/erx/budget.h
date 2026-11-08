/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BUDGET_H
#define ERX_BUDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The budget core: the accounting of kernel memory as a tree of budgets
 * (docs/design-kernel.md, "Budgets"). Each budget has a guarantee carved
 * from its parent, a cap on what its tree may spend, and counters of what
 * is charged to it. Its spending is used + carved + lent; what spending
 * exceeds the guarantee by is what it borrows, and its parent counts
 * exactly that in lent. Every count is in pages.
 *
 * Every change of a budget's counters goes through erx_budget_adjust or
 * one of the operations below it serves (carve, resize, close, pin,
 * watch). Each plans the change along the budget's chain of ancestors,
 * taking their locks descendant first through erx_effect_budget_lock, and
 * applies it whole or not at all; a refused change leaves every counter
 * as it was. What the caller must do after the locks are dropped, the
 * watches to trigger, the records to pin and the tombstones whose put is
 * due, is returned in erx_budget_effects_t.
 *
 * The records are opaque outside the core: their definitions are in
 * kernel/core/budget_impl.h, which only kernel/core/budget.c includes, so
 * no other code can write a counter.
 */

typedef uint64_t erx_npages_t;

typedef struct erx_budget erx_budget_t;
typedef struct erx_budget_counters erx_budget_counters_t;
typedef struct erx_budget_effects erx_budget_effects_t;
typedef struct erx_budget_walk erx_budget_walk_t;
typedef struct erx_reserve erx_reserve_t;
typedef struct erx_reserve_counts erx_reserve_counts_t;

/* The IRQ object a watch triggers; the core only carries the pointer. */
struct erx_irq;

/*
 * What an adjustment leaves for its caller to do after every lock is
 * dropped and before its next preemption point. A chain holds at most
 * ERX_BUDGET_DEPTH_MAX budgets, so each list has room for every level.
 * A dead budget's tombstone is reported when its spending reaches zero,
 * which happens once because each child budget's record is charged to
 * its parent's cache until the child's own record is freed.
 */
struct erx_budget_effects {
	/* The level that refused the change; NULL when it was applied. */
	erx_budget_t	*refused;
	/* IRQ objects whose watch the adjustment crossed and disarmed. */
	struct erx_irq	*fire[ERX_BUDGET_DEPTH_MAX];
	/* Budgets whose pinned rose from zero: their records are kept. */
	erx_budget_t	*first_pin[ERX_BUDGET_DEPTH_MAX];
	/* Dead budgets whose spending reached zero: queue their puts. */
	erx_budget_t	*tombstone[ERX_BUDGET_DEPTH_MAX];
	uint32_t	 nfire;
	uint32_t	 nfirst_pin;
	uint32_t	 ntombstone;
};

/* A snapshot of one budget, as erx_object_info reports it. */
struct erx_budget_counters {
	erx_budget_kind_t kind;
	uint32_t	 depth;
	bool		 dead;
	erx_npages_t	 guarantee;
	erx_npages_t	 cap;
	erx_npages_t	 used;
	erx_npages_t	 carved;
	erx_npages_t	 lent;
	erx_npages_t	 pinned;
	erx_npages_t	 threshold;
};

/*
 * A reserve's counts. charged is what its budget's used counts for it;
 * backed the pages it holds, in use or in its pool; pooled the backed
 * pages not yet in use. Between calls charged equals backed, so the pool
 * holds a page for every promise not in use.
 */
struct erx_reserve_counts {
	erx_npages_t	charged;
	erx_npages_t	backed;
	erx_npages_t	pooled;
};

/*
 * The effects a host of the core provides: the budget's lock, a ticket
 * lock in the kernel's order. The core takes a chain's locks descendant
 * first and releases them before it returns.
 */
void	erx_effect_budget_lock(erx_budget_t *);
void	erx_effect_budget_unlock(erx_budget_t *);

/* Size and alignment of a budget record, for the cache that holds it. */
size_t	erx_budget_record_size(void);
size_t	erx_budget_record_align(void);
size_t	erx_reserve_record_size(void);
size_t	erx_reserve_record_align(void);

/*
 * The root budget: every page the page allocator holds, as its guarantee
 * and its cap. It is a wall at depth 0 and is never resized or closed.
 * Refuses with ERX_EINVAL more than INT64_MAX pages, so that no live
 * spending, which never exceeds the root's, needs more than a signed
 * 64-bit change.
 */
int	erx_budget_init_root(erx_budget_t *, erx_npages_t)
	    ERX_WARN_UNUSED_RESULT;

/*
 * Carves child from parent with the given kind, guarantee and cap, and
 * charges the guarantee to the parent's carved. Refuses with ERX_EINVAL a
 * kind other than a wall or elastic, a cap below the guarantee or, for a
 * wall, a cap other than the guarantee; with ERX_ELIMIT a parent at depth
 * ERX_BUDGET_DEPTH_MAX - 1; with ERX_ESTALE a dead parent; and with
 * ERX_ENOMEM a guarantee the parent's chain cannot cover. child is not
 * reachable by anyone until the call returns 0. The record's own cache
 * page is a separate charge, made by the cache.
 */
int	erx_budget_carve(erx_budget_t *, erx_budget_t *, erx_budget_kind_t,
	    erx_npages_t, erx_npages_t, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * The one function that charges or refunds a budget: used changes by the
 * given pages, positive for a charge. A carved or a lent change is made
 * only by the core itself, as it passes a child's change up the chain, so
 * no caller can free room a child's guarantee or borrowing holds. A
 * charge that raises a live level's spending above its cap is refused
 * with ERX_ENOMEM, naming the level in effects->refused; a charge of a
 * dead budget is refused with ERX_ESTALE; a refund never fails.
 * ERX_EINVAL means used would fall below zero: a caller's accounting
 * error, refused with nothing changed.
 */
int	erx_budget_adjust(erx_budget_t *, int64_t, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/* Raises pinned at the budget and every ancestor, dead ones included. */
int	erx_budget_pin(erx_budget_t *, erx_npages_t, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * Sets a budget's guarantee and cap in one step; the caller has checked
 * DESTROY on the capability. Refuses with ERX_EINVAL the root, a cap below
 * the guarantee, or a wall's cap other than its guarantee; with ERX_ESTALE
 * a dead budget; and with ERX_ENOMEM a growth the parent's chain cannot
 * cover. A shrink never fails, even below the spending: what the smaller
 * guarantee no longer covers becomes borrowing, and a cap below the
 * spending refuses every charge that would raise it.
 */
int	erx_budget_resize(erx_budget_t *, erx_npages_t, erx_npages_t,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Closes a budget for its destroy: marks it dead and, in the same
 * adjustment, moves its spending to its parent's used, whose carved loses
 * the guarantee and whose lent loses what the budget borrowed. Never
 * raises the parent's spending, so it fails only with ERX_ESTALE for a
 * budget already dead and ERX_EINVAL for the root.
 */
int	erx_budget_close(erx_budget_t *, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * Arms the budget's one watch: the first adjustment that takes its
 * spending from below threshold to at or above it fires irq once and
 * disarms the watch. Arming at or above the threshold fires at once
 * (*fire set) and leaves it disarmed. irq NULL disarms and forgets the IRQ
 * object. Refuses with ERX_EBUSY while another IRQ object is the watch,
 * and with ERX_ESTALE a dead budget.
 */
int	erx_budget_watch(erx_budget_t *, struct erx_irq *, erx_npages_t,
	    bool *) ERX_WARN_UNUSED_RESULT;

/* Clears the watch only if it still names irq; true when it did. */
bool	erx_budget_watch_detach(erx_budget_t *, struct erx_irq *);

void	erx_budget_read(erx_budget_t *, erx_budget_counters_t *);

/*
 * Whether the budget's destroy has closed it, read without its lock, as
 * the capability lookup reads it for the object a budget pays for. A dead
 * budget never lives again.
 */
bool	erx_budget_dead(const erx_budget_t *);
erx_budget_t *erx_budget_parent(const erx_budget_t *);

/*
 * The destroy's walk over a closed budget's tree, iterative and without a
 * stack: the cursor descends into each child budget it meets on a list of
 * charged objects and climbs back through the child's parent when the
 * child's list is empty, so its state is two pointers whatever the depth.
 * The caller reports what heads the cursor's list; the walk names the
 * next step:
 *
 *   ERX_BUDGET_WALK_DESTROY  destroy the head object, as a deletion would;
 *   ERX_BUDGET_WALK_ENTER    the head is the child budget in walk->subject:
 *                            close it, then walk its list (the cursor);
 *   ERX_BUDGET_WALK_LEAVE    walk->subject's list is empty: take it off
 *                            its parent's list, now the cursor's;
 *   ERX_BUDGET_WALK_DONE     the top budget's list is empty.
 */
typedef enum erx_budget_head {
	ERX_BUDGET_HEAD_EMPTY = 1,
	ERX_BUDGET_HEAD_OBJECT = 2,
	ERX_BUDGET_HEAD_BUDGET = 3
} erx_budget_head_t;

/*
 * ERX_BUDGET_WALK_INVALID: the reported head is not a budget whose parent
 * is the cursor, or not a head at all; the list is corrupt and the walk
 * moves nothing.
 */
typedef enum erx_budget_walk_action {
	ERX_BUDGET_WALK_DESTROY = 1,
	ERX_BUDGET_WALK_ENTER = 2,
	ERX_BUDGET_WALK_LEAVE = 3,
	ERX_BUDGET_WALK_DONE = 4,
	ERX_BUDGET_WALK_INVALID = 5
} erx_budget_walk_action_t;

struct erx_budget_walk {
	erx_budget_t	*top;		/* the destroyed budget, closed */
	erx_budget_t	*cursor;	/* the budget whose list is walked */
	erx_budget_t	*subject;	/* the budget an ENTER or LEAVE names */
};

void	erx_budget_walk_begin(erx_budget_walk_t *, erx_budget_t *);
/* head_budget is the head when it is a budget and is ignored otherwise. */
erx_budget_walk_action_t erx_budget_walk_next(erx_budget_walk_t *,
	    erx_budget_head_t, erx_budget_t *);

/*
 * A reserve's accounting. Every step is made under the reserve's owner's
 * lock, which serialises the step's read and write of the counts; the
 * owner of a budget's cache reserve is the cache, whose lock is its own
 * and never the budget's, since each step takes the budget's chain. An
 * ENTER whose close finds the child already dead (its own destroy got
 * there first) waits for that destroy, as the drain of any existence lock
 * does, before it walks on. erx_reserve_charge,
 * erx_reserve_take and erx_page_release of the page core are made of
 * these steps:
 *
 *   erx_reserve_admit   admits n promises at the reserve's budget;
 *   erx_reserve_fill    k backed pages joined the pool, k <= unbacked;
 *   erx_reserve_cancel  gives back k promises a backing did not back;
 *   erx_reserve_use     one pooled page came into use;
 *   erx_reserve_refund  pages released from use and from the pool leave
 *                       the reserve, and their charge is refunded.
 *
 * Each refuses with ERX_EINVAL a count the reserve does not hold, so a
 * double refund or a take beyond the pool changes nothing.
 */
void	erx_reserve_init(erx_reserve_t *, erx_budget_t *);
erx_budget_t *erx_reserve_budget(const erx_reserve_t *);
void	erx_reserve_read(const erx_reserve_t *, erx_reserve_counts_t *);
int	erx_reserve_admit(erx_reserve_t *, erx_npages_t,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;
int	erx_reserve_fill(erx_reserve_t *, erx_npages_t) ERX_WARN_UNUSED_RESULT;
int	erx_reserve_cancel(erx_reserve_t *, erx_npages_t,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;
int	erx_reserve_use(erx_reserve_t *) ERX_WARN_UNUSED_RESULT;
int	erx_reserve_refund(erx_reserve_t *, erx_npages_t, erx_npages_t,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_BUDGET_H */
