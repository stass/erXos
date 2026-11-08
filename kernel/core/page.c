/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The page funnel (docs/design-kernel.md, "The reaper"). Each entry is
 * composed from the budget core's reserve steps and moves the pages those
 * steps count: the step and the move are made together under the owner's
 * lock, so a reserve's pooled count is its pool chain's length whenever
 * that lock is free. Every lock is taken through an effect; the decisions
 * between them read only the records in hand.
 *
 * The one order the funnel exists to keep is a release's: retire and
 * append under the list's lock first, refund after. A refund lets a charge
 * be admitted somewhere; that charge's backing may need exactly these
 * pages, and the identity's inequality guarantees it finds them only if
 * they are on the list before the refund is visible.
 */

#include "budget_impl.h"
#include "page_impl.h"

/*
 * Debug and host builds check, wherever the funnel holds an owner's lock,
 * that the reserve's pooled count is its pool chain's length.
 */
#if defined(ERX_HOST) || defined(ERX_KERNEL_DEBUG)
#define PAGE_CHECK_POOL		1
#else
#define PAGE_CHECK_POOL		0
#endif

static void
check_pool(const erx_reserve_t *reserve)
{
	if (PAGE_CHECK_POOL && reserve->pooled != reserve->pool.count)
		__builtin_trap();
}

void
erx_plist_push(erx_plist_t *list, erx_page_t *page)
{
	page->next = NULL;
	if (list->tail == NULL)
		list->head = page;
	else
		list->tail->next = page;
	list->tail = page;
	list->count++;
}

erx_page_t *
erx_plist_pop(erx_plist_t *list)
{
	erx_page_t *page;

	page = list->head;
	if (page == NULL)
		return (NULL);
	list->head = page->next;
	if (list->head == NULL)
		list->tail = NULL;
	list->count--;
	page->next = NULL;
	return (page);
}

/* Moves every page of from to the tail of to, in order. */
static void
plist_splice(erx_plist_t *to, erx_plist_t *from)
{
	if (from->head == NULL)
		return;
	if (to->tail == NULL)
		to->head = from->head;
	else
		to->tail->next = from->head;
	to->tail = from->tail;
	to->count += from->count;
	*from = (erx_plist_t){ 0 };
}

void
erx_released_init(erx_released_t *released, erx_grace_t *tracker)
{
	*released = (erx_released_t){ .tracker = tracker };
}

/*
 * Unlinks up to n pages from the head of the released list onto out,
 * under the list's lock, which the caller holds: any pages, or only mature
 * ones. Raises *newest to the newest stamp taken and returns the count.
 */
static erx_npages_t
released_take(erx_released_t *released, erx_npages_t n,
    erx_released_which_t which, erx_plist_t *out, uint64_t *newest)
{
	erx_page_t *page;
	erx_npages_t taken;

	for (taken = 0; taken < n; taken++) {
		page = released->list.head;
		if (page == NULL || (which == ERX_RELEASED_MATURE &&
		    !erx_grace_mature(released->tracker, page->stamp)))
			break;
		(void)erx_plist_pop(&released->list);
		if (page->stamp > *newest)
			*newest = page->stamp;
		erx_plist_push(out, page);
	}
	return (taken);
}

erx_npages_t
erx_released_free(erx_released_t *released, erx_npages_t n)
{
	erx_plist_t mature = { 0 };
	uint64_t newest = 0;
	erx_npages_t moved;

	/* One part: the list's lock is held for at most ERX_PAGE_PART pages. */
	if (n > ERX_PAGE_PART)
		n = ERX_PAGE_PART;
	erx_effect_released_lock(released);
	moved = released_take(released, n, ERX_RELEASED_MATURE, &mature,
	    &newest);
	if (moved > 0)
		erx_effect_page_free(&mature);
	erx_effect_released_unlock(released);
	return (moved);
}

int
erx_reserve_charge(erx_backing_t *backing, erx_reserve_t *reserve,
    erx_npages_t pages, erx_budget_effects_t *effects)
{
	int error;

	*backing = (erx_backing_t){ .reserve = reserve };
	erx_effect_reserve_lock(reserve);
	error = erx_reserve_admit(reserve, pages, effects);
	erx_effect_reserve_unlock(reserve);
	if (error == 0)
		backing->unselected = pages;
	return (error);
}

/*
 * Takes the next part into the hand, under the list's lock: free pages
 * first, then the oldest released ones. The identity's inequality (the
 * pages admitted and not yet taken never exceed the free and released
 * pages) means the two together always hold the part; finding them short
 * is a broken identity, a kernel bug, and traps.
 */
static void
select_part(erx_released_t *released, erx_backing_t *backing)
{
	erx_npages_t need, got;

	need = backing->unselected < ERX_PAGE_PART ? backing->unselected :
	    ERX_PAGE_PART;
	erx_effect_released_lock(released);
	got = erx_effect_page_alloc(need, &backing->hand);
	if (got < need)
		got += released_take(released, need - got,
		    ERX_RELEASED_ANY, &backing->hand, &backing->newest);
	erx_effect_released_unlock(released);
	if (got != need || backing->hand.count != need)
		__builtin_trap();
	backing->unselected -= need;
}

/*
 * The reserve steps are called here, in the exported function, so the
 * call-graph rules see the one caller each: the hand joins the pool
 * through erx_reserve_fill once its grace period has ended, and a closed
 * backing gives back what it never took through erx_reserve_cancel.
 */
erx_backing_next_t
erx_backing_step(erx_released_t *released, erx_backing_t *backing,
    bool closed, erx_budget_effects_t *effects)
{
	erx_reserve_t *reserve;

	*effects = (erx_budget_effects_t){ 0 };
	reserve = backing->reserve;
	backing->closing |= closed;
	if (backing->hand.count == 0 && !backing->closing &&
	    backing->unselected > 0)
		select_part(released, backing);
	if (backing->hand.count > 0) {
		if (!erx_grace_mature(released->tracker, backing->newest))
			return (ERX_BACKING_WAIT);
		erx_effect_reserve_lock(reserve);
		check_pool(reserve);
		if (erx_reserve_fill(reserve, backing->hand.count) != 0)
			__builtin_trap();
		plist_splice(&reserve->pool, &backing->hand);
		erx_effect_reserve_unlock(reserve);
		backing->newest = 0;
	}
	if (!backing->closing)
		return (backing->unselected > 0 ? ERX_BACKING_MORE :
		    ERX_BACKING_DONE);
	if (backing->unselected > 0) {
		erx_effect_reserve_lock(reserve);
		if (erx_reserve_cancel(reserve, backing->unselected, effects) != 0)
			__builtin_trap();
		erx_effect_reserve_unlock(reserve);
		backing->unselected = 0;
	}
	return (ERX_BACKING_CANCELLED);
}

erx_page_t *
erx_reserve_take(erx_reserve_t *reserve)
{
	erx_page_t *page;

	check_pool(reserve);
	if (erx_reserve_use(reserve) != 0)
		__builtin_trap();
	page = erx_plist_pop(&reserve->pool);
	erx_effect_page_zero(page);
	return (page);
}

/*
 * Appends batch to the released list as one batch stamped by a fresh
 * retire, under the list's lock. The retire is taken under that lock so
 * that batches reach the list in the order of their stamps.
 */
static void
released_append(erx_released_t *released, erx_plist_t *batch)
{
	erx_page_t *page;
	uint64_t stamp;

	erx_effect_released_lock(released);
	stamp = erx_grace_retire(released->tracker);
	for (page = batch->head; page != NULL; page = page->next)
		page->stamp = stamp;
	plist_splice(&released->list, batch);
	erx_effect_released_unlock(released);
}

int
erx_page_release(erx_released_t *released, erx_reserve_t *reserve,
    erx_plist_t *in_use, erx_npages_t from_pool,
    erx_budget_effects_t *effects)
{
	erx_plist_t batch;
	erx_npages_t used, pages, i;

	used = in_use->count;
	if (__builtin_add_overflow(used, from_pool, &pages) ||
	    pages > ERX_PAGE_PART)
		return (ERX_EINVAL);
	erx_effect_reserve_lock(reserve);
	check_pool(reserve);
	if (from_pool > reserve->pooled ||
	    used > reserve->backed - reserve->pooled) {
		erx_effect_reserve_unlock(reserve);
		return (ERX_EINVAL);
	}
	batch = *in_use;
	*in_use = (erx_plist_t){ 0 };
	for (i = 0; i < from_pool; i++)
		erx_plist_push(&batch, erx_plist_pop(&reserve->pool));
	if (pages > 0)
		released_append(released, &batch);
	/* Checked above, so the refund, a decrease, cannot be refused. */
	if (erx_reserve_refund(reserve, used, from_pool, effects) != 0)
		__builtin_trap();
	erx_effect_reserve_unlock(reserve);
	return (0);
}
