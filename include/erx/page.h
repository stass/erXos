/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PAGE_H
#define ERX_PAGE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/budget.h"
#include "erx/cdefs.h"
#include "erx/grace.h"

/*
 * The page funnel (docs/design-kernel.md, "The reaper" and "The interface
 * every implementation's page funnel meets"): the only paths by which a
 * page enters a reserve, comes into use, and leaves it.
 *
 *   erx_reserve_charge, erx_backing_step
 *                       admit n pages at the reserve's budget, then back
 *                       them in parts of at most ERX_PAGE_PART pages:
 *                       free pages first, then pages off the head of the
 *                       released list, each part waiting for the grace
 *                       period of what it took before the pages join the
 *                       reserve's pool;
 *   erx_reserve_take    moves one pooled page into use, zeroed;
 *   erx_page_release    retires pages the reserve holds, appends them to
 *                       the released list as one stamped batch, and only
 *                       then refunds their charge, in one part;
 *   erx_released_free   the reaper's free step: moves mature pages from
 *                       the head of the released list to the free lists
 *                       in one hold of the list's lock, so no page is
 *                       ever between the two. It and the backing are
 *                       the only unlinks from the released list.
 *
 * Between parts every page of the root budget's guarantee is in exactly
 * one place: held by a reserve, in use or pooled; in the hand of a
 * backing, taken and waiting for its grace period; on the released list;
 * or on the page allocator's free lists. The released list is in append
 * order and its stamps never decrease along it, so its head matures first.
 *
 * Each composed call takes the locks it needs through the effects below,
 * in one order: the reserve owner's lock, then the released list's, then
 * the tracker's (inside erx_grace_retire); the backing takes the list's
 * and, inside erx_effect_page_alloc, the allocator's, and the owner's lock
 * only after it has released both. The budget chain's locks are taken
 * inside the reserve steps of kernel/core/budget.c, under the owner's
 * lock. erx_reserve_take alone runs under an owner's lock its caller
 * holds, since a fault holds it across the take and the mapping.
 *
 * The page record and the released list are opaque outside the funnel:
 * their definitions are in kernel/core/page_impl.h, which only
 * kernel/core/page.c and its host tests include. A chain's members are
 * written only by the functions below.
 */

/* The most pages one part of a backing or one release handles. */
#define ERX_PAGE_PART	64

typedef struct erx_page erx_page_t;
typedef struct erx_released erx_released_t;
typedef struct erx_plist erx_plist_t;
typedef struct erx_backing erx_backing_t;

/*
 * A chain of page records through their link, in order: a reserve's pool,
 * a batch being released, a backing's hand. Only kernel/core/page.c reads
 * or writes the members; an all-zero chain is empty.
 */
struct erx_plist {
	erx_page_t	*head;
	erx_page_t	*tail;
	erx_npages_t	 count;
};

/*
 * A charge being backed: what was admitted and is not yet selected, and
 * the hand, the pages selected and waiting for their grace period. Only
 * kernel/core/page.c reads or writes the members.
 */
struct erx_backing {
	erx_reserve_t	*reserve;
	erx_npages_t	 unselected;	/* admitted, not yet taken */
	erx_plist_t	 hand;		/* taken, not yet in the pool */
	uint64_t	 newest;	/* the newest stamp in the hand */
	bool		 closing;	/* an existence lock was found closed */
};

/*
 * What a backing's caller does next. MORE and WAIT ask the same of it, a
 * preemption point and another step; WAIT says that the hand's grace
 * period is what the backing waits for.
 */
typedef enum erx_backing_next {
	ERX_BACKING_DONE = 1,	/* every admitted page is in the pool */
	ERX_BACKING_MORE,	/* pass a preemption point, then step again */
	ERX_BACKING_WAIT,	/* the hand's grace period has not ended:
				 * pass a preemption point, then step again */
	ERX_BACKING_CANCELLED	/* closed: what was taken is in the pool, the
				 * rest is cancelled; the call fails with
				 * ERX_ESTALE */
} erx_backing_next_t;

/* Which pages an unlink from the released list may take. */
typedef enum erx_released_which {
	ERX_RELEASED_ANY = 1,	/* the backing, which waits itself */
	ERX_RELEASED_MATURE	/* the free step: only those whose grace
				 * period has ended */
} erx_released_which_t;

/*
 * The effects a host of the funnel provides. The owner's lock serialises a
 * reserve's steps; the list's lock is a ticket lock (K13).
 * erx_effect_page_alloc takes up to n free pages from the page allocator,
 * under the allocator's lock, appending each with erx_plist_push, and
 * returns how many it took; erx_effect_page_free puts every page of a
 * chain on the free lists, under the allocator's lock, and empties it.
 * Only kernel/core/page.c calls either. erx_effect_page_zero zeroes a
 * page.
 */
void	erx_effect_reserve_lock(erx_reserve_t *);
void	erx_effect_reserve_unlock(erx_reserve_t *);
void	erx_effect_released_lock(erx_released_t *);
void	erx_effect_released_unlock(erx_released_t *);
erx_npages_t erx_effect_page_alloc(erx_npages_t n, erx_plist_t *out);
void	erx_effect_page_free(erx_plist_t *);
void	erx_effect_page_zero(erx_page_t *);

/* An empty released list, whose batches are stamped by tracker. */
void	erx_released_init(erx_released_t *, erx_grace_t *tracker);

/*
 * Appends a page that is on no chain to the tail of list, or takes the
 * head off it (NULL when the list is empty).
 */
void	erx_plist_push(erx_plist_t *, erx_page_t *);
erx_page_t *erx_plist_pop(erx_plist_t *);

/*
 * Admits n pages at the reserve's budget, under the owner's lock, and
 * starts backing them; the caller holds the owner's existence lock from
 * here until the backing ends. A refused admission returns its error
 * (ERX_ENOMEM, ERX_ESTALE, ERX_EINVAL) and takes nothing.
 */
int	erx_reserve_charge(erx_backing_t *, erx_reserve_t *, erx_npages_t,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

/*
 * One part of a backing. closed is whether the caller found any existence
 * lock its thread holds closed since the last part; once it has, the
 * backing takes nothing more, puts what it took into the pool once mature,
 * and cancels the rest. A part selects up to ERX_PAGE_PART pages under the
 * list's lock, free pages first and then the released list's oldest, and
 * puts them in the pool under the owner's lock once their grace period has
 * ended. effects holds what a cancellation's refund leaves to do, and is
 * empty otherwise.
 */
erx_backing_next_t erx_backing_step(erx_released_t *, erx_backing_t *,
	    bool closed, erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Moves one page of the reserve's pool into use, zeroed, under the owner's
 * lock, which the caller holds. Between calls the pool holds a page for
 * every promise not in use, so an empty pool is a kernel bug and traps.
 */
erx_page_t *erx_reserve_take(erx_reserve_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Releases the pages of in_use, which the reserve holds in use, and
 * from_pool pages of its pool, at most ERX_PAGE_PART in all: under the
 * owner's lock and then the list's, retires them through the tracker and
 * appends them to the released list as one batch with that stamp, and
 * only then refunds their charge through the budget's chain, so a charge
 * the refund admits finds them on the list already. in_use is left empty.
 * ERX_EINVAL, with nothing changed, for more pages than a part or than the
 * reserve holds.
 */
int	erx_page_release(erx_released_t *, erx_reserve_t *, erx_plist_t *in_use,
	    erx_npages_t from_pool, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * The reaper's free step: under the list's lock, and the allocator's
 * inside it, moves up to n mature pages, and never more than one part of
 * ERX_PAGE_PART, from the head of the released list to the free lists, and
 * returns how many it moved. It stops at the first
 * page whose grace period has not ended; the list's stamps never
 * decrease, so every page behind it is immature too.
 */
erx_npages_t erx_released_free(erx_released_t *, erx_npages_t n);

#endif /* ERX_PAGE_H */
