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
#include "erx/object.h"

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
 * watches to trigger and the tombstones whose put is due, is returned in
 * erx_budget_effects_t.
 *
 * The records are opaque outside the core: their definitions are in
 * kernel/core/budget_impl.h, which only kernel/core/budget.c includes, so
 * no other code can write a counter.
 */

typedef uint64_t erx_npages_t;

typedef struct erx_budget erx_budget_t;
typedef struct erx_budget_counters erx_budget_counters_t;
typedef struct erx_budget_effects erx_budget_effects_t;
typedef struct erx_reserve erx_reserve_t;
typedef struct erx_reserve_counts erx_reserve_counts_t;
typedef struct erx_kcache_slot erx_kcache_slot_t;

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
	/*
	 * Dead budgets whose spending reached zero: queue the put of the
	 * counted reference each one's object holds for its counters.
	 */
	erx_budget_t	*tombstone[ERX_BUDGET_DEPTH_MAX];
	uint32_t	 nfire;
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
 * The record cache (docs/design-kernel.md, "The record cache" in
 * Budgets): each budget carves the kernel records charged to it from
 * cache pages of its own, one cache per record kind, under its lock. A
 * cache page is charged whole to its budget, through the chain plan, from
 * the take that adds it until the free that empties it; a record is freed
 * only by the reaper's record free, after its object's grace period and
 * last counted reference, so its page stays charged through that grace
 * period. Each record is its object's header area, then the type's body
 * (erx_object_body). The pilot's one kind is the budget record.
 *
 * A taken record is named by its slot, the page and the record's index
 * on it, which the record's owner keeps for the free.
 */
typedef enum erx_kcache_kind {
	ERX_KCACHE_BUDGET = 0,		/* a child budget's record */
	ERX_KCACHE_NKINDS
} erx_kcache_kind_t;

struct erx_kcache_slot {
	struct erx_kcache_page *page;	/* NULL: no slot */
	uint32_t	 index;		/* the record's place on the page */
};

/*
 * The bytes and alignment of the memory a cache page is made from: one
 * page of the page allocator's, aligned to its size.
 */
#define ERX_KCACHE_PAGE_BYTES	4096u

/* How many records of a kind one cache page holds; at most 64. */
uint32_t erx_kcache_capacity(erx_kcache_kind_t);

/*
 * Takes a free record of the kind from the budget's cache into *slot.
 * When no page has a free record, page, ERX_KCACHE_PAGE_BYTES of memory
 * the caller took from the page allocator, becomes a new cache page,
 * charged to the budget's used through the chain plan in the same hold,
 * and *page_taken says so; the caller returns an untaken page to the
 * allocator. Refuses with ERX_ESTALE a dead budget, which takes no new
 * record; with ERX_ELIMIT when no page has a free record and page is
 * NULL; with ERX_ENOMEM, naming the level, when the chain cannot cover
 * the new page; and with ERX_EINVAL a kind outside the table. Nothing
 * changes on a refusal.
 */
int	erx_kcache_take(erx_budget_t *, erx_kcache_kind_t, void *page,
	    erx_kcache_slot_t *slot, bool *page_taken, erx_budget_effects_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * The record a slot names, its object's header first: aligned to 64
 * bytes, its kind's size.
 */
void	*erx_kcache_record(const erx_kcache_slot_t *);

/*
 * Returns a record to the budget's cache that it was taken from, live or
 * dead. When its page then holds no record, the page leaves the cache and
 * is refunded through the chain plan in the same hold, a decrease that
 * never fails, and *page_out names it for the caller to release through
 * the page funnel; otherwise *page_out is NULL. A record kept for the
 * boot is never freed: ERX_EBUSY. ERX_EINVAL for a slot with no page,
 * a page of another budget's cache or kind, an index off its page or a
 * record not taken.
 */
int	erx_kcache_free(erx_budget_t *, erx_kcache_kind_t,
	    const erx_kcache_slot_t *, void **page_out,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Carves a child from parent with the given kind, guarantee and cap, in
 * one chain plan under one hold of the parent's lock: the child's record
 * from the parent's cache of budget records and the guarantee to the
 * parent's carved, taken together or not at all. When the cache has no
 * free record, page, ERX_KCACHE_PAGE_BYTES the caller took from the page
 * allocator, becomes a new cache page charged to the parent's used in
 * the same plan, and *page_taken says so; the caller returns an untaken
 * page. Refuses with ERX_EINVAL a kind other than a wall or elastic, a
 * cap below the guarantee, or for a wall a cap other than the guarantee;
 * with ERX_ELIMIT a parent at depth ERX_BUDGET_DEPTH_MAX - 1, or a cache
 * with no free record and page NULL; with ERX_ESTALE a dead parent; and
 * with ERX_ENOMEM, naming the level, a record and guarantee the parent's
 * chain cannot cover. Nothing changes on a refusal.
 *
 * *child is the record's body; its object header, at erx_object_of,
 * is the caller's to make (erx_object_init, ERX_K_BUDGET, paid for by
 * parent), to put on the parent's att_charged through
 * erx_attach_budget_charged, and to give one more counted reference, the
 * one its counters hold until its tombstone's put. The child is reachable
 * by no one until then.
 */
int	erx_budget_carve(erx_budget_t *, void *page, erx_budget_kind_t,
	    erx_npages_t, erx_npages_t, erx_budget_t **child, bool *page_taken,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

/*
 * The free of a dead child budget's own record, at its object's last
 * put, the record's one release event, which comes after its tombstone's
 * put and every walk's and destroy's: erx_kcache_free on the parent's
 * cache at the slot the carve recorded. ERX_EINVAL for the root or a live budget, ERX_EBUSY for a
 * budget that still has something charged to it, or whose pinned is not
 * zero, which is kept for the boot.
 */
int	erx_budget_free_record(erx_budget_t *, void **page_out,
	    erx_budget_effects_t *) ERX_WARN_UNUSED_RESULT;

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

/*
 * Raises pinned at the budget and every ancestor, dead ones included. In
 * the same plan, each level whose pinned rises from zero is kept for the
 * boot, since its used will never reach zero, and so is its record: the
 * first record kept on a cache page pins that page too, one more page at
 * the page's budget, the level's parent, and at every ancestor above it.
 */
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
 * The budget's list of charged objects, att_charged: the objects charged
 * to it, child budgets included, that no destroy has closed yet. Its
 * one insert is erx_attach_budget_charged; it loses an object at the
 * object's close, by the destroy's drain or the budget-death walk of the
 * deletion core, whichever takes the budget's lock first. Read and
 * written under the budget's lock, the caller's. Membership means the
 * walk still has to close the object, never that it lives: a dead
 * budget's tombstone waits for its records through used, not the list.
 */
erx_charged_list_t *erx_budget_charged(erx_budget_t *);

/*
 * A reserve's accounting. Every step is made under the reserve's owner's
 * lock, which serialises the step's read and write of the counts; the
 * owner of a budget's cache reserve is the cache, whose lock is its own
 * and never the budget's, since each step takes the budget's chain.
 * erx_reserve_charge,
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
