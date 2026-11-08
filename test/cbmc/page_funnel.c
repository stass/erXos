/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: the page funnel (kernel/core/page.c). The funnel's
 * promise is that a released page is reused only after its grace period:
 * it reaches the free lists or a reserve's pool only once its stamp has
 * matured, and a page is always in exactly one place.
 *
 * Bounds: FUNNEL_PAGES = 4 page records; FUNNEL_STEPS = 5
 * calls, each a charge, a backing step (closed or not), a take, a release
 * of everything in use plus any part of the pool, a reaper's free, or the
 * end of grace periods. Loops unwound FUNNEL_PAGES + 2 times,
 * the harness's own FUNNEL_STEPS + 1.
 *
 * Assumptions: the grace tracker is a stub of erx/grace.h's contract: a
 * retirement stamps the next count, and a stamp matures once the
 * completed count, which only rises and never passes the newest stamp,
 * reaches it. The runner checks one core per harness; the tracker's own
 * promise is the grace_tracker harness's. The reserve steps of the
 * budget core are modelled by stubs that keep erx/budget.h's contract for
 * one reserve: each refuses a count the reserve does not hold, and an
 * admission is refused, at random or when it would promise more pages
 * than exist, which is the budget core's rule for the machine:
 * pages admitted and not yet taken never exceed the free and released
 * pages. The page allocator is a stub
 * over the harness's free list that hands out what was asked, or every
 * free page when fewer are free. One backing at a time; lock effects
 * check their own pairing and the order (an owner's lock before the
 * released list's); one thread.
 *
 * Checked, after every call: every page is on exactly one of the free
 * list, the released list, the backing's hand, the pool and the in-use
 * list; the pooled count is the pool's length and the backed count the
 * pool's and the in-use list's; stamps never decrease along the released
 * list; every pooled page's stamp has matured; and, inside the free
 * effect, every page freed has a mature stamp. ERX_KERNEL_DEBUG keeps the
 * funnel's own pool check, whose trap fails a property.
 */

#include "cbmc_harness.h"
#include "page.c"

#ifndef FUNNEL_PAGES
#define FUNNEL_PAGES	4
#endif
#ifndef FUNNEL_STEPS
#define FUNNEL_STEPS	5
#endif

static erx_page_t pages[FUNNEL_PAGES];
static erx_plist_t free_list, in_use;
static uint64_t tracker_storage;
#define TRACKER		((erx_grace_t *)&tracker_storage)
/* The tracker stub's counts: the newest stamp and the newest completed. */
static uint64_t stamped, completed;
static erx_released_t released;
static erx_reserve_t reserve;
static erx_backing_t backing;
static bool reserve_locked, released_locked;

uint64_t
erx_grace_retire(erx_grace_t *held)
{
	__CPROVER_assert(held == TRACKER && released_locked,
	    "a batch is stamped under the released list's lock");
	return (++stamped);
}

bool
erx_grace_mature(const erx_grace_t *held, uint64_t stamp)
{
	__CPROVER_assert(held == TRACKER, "the funnel asks its own tracker");
	return (completed >= stamp);
}

void
erx_effect_reserve_lock(erx_reserve_t *held)
{
	__CPROVER_assert(held == &reserve && !reserve_locked &&
	    !released_locked, "an owner's lock is taken once, before the list's");
	reserve_locked = true;
}

void
erx_effect_reserve_unlock(erx_reserve_t *held)
{
	__CPROVER_assert(held == &reserve && reserve_locked,
	    "an owner's lock is released only when held");
	reserve_locked = false;
}

void
erx_effect_released_lock(erx_released_t *held)
{
	__CPROVER_assert(held == &released && !released_locked,
	    "the released list's lock is taken once");
	released_locked = true;
}

void
erx_effect_released_unlock(erx_released_t *held)
{
	__CPROVER_assert(held == &released && released_locked,
	    "the released list's lock is released only when held");
	released_locked = false;
}

erx_npages_t
erx_effect_page_alloc(erx_npages_t n, erx_plist_t *out)
{
	erx_npages_t got = n < free_list.count ? n : free_list.count;

	__CPROVER_assert(released_locked,
	    "the allocator is reached under the released list's lock");
	for (erx_npages_t i = 0; i < got; i++)
		erx_plist_push(out, erx_plist_pop(&free_list));
	return (got);
}

void
erx_effect_page_free(erx_plist_t *list)
{
	erx_page_t *page;

	__CPROVER_assert(released_locked,
	    "pages are freed under the released list's lock");
	for (page = list->head; page != NULL; page = page->next)
		__CPROVER_assert(erx_grace_mature(TRACKER, page->stamp),
		    "a page is freed only after its grace period");
	while ((page = erx_plist_pop(list)) != NULL)
		erx_plist_push(&free_list, page);
}

void
erx_effect_page_zero(erx_page_t *page)
{
	__CPROVER_assert(page != NULL, "a page taken into use exists");
}

/* The reserve steps, as erx/budget.h states them for one reserve. */

int
erx_reserve_admit(erx_reserve_t *r, erx_npages_t n, erx_budget_effects_t *e)
{
	(void)e;
	if (nondet_bool() || n > FUNNEL_PAGES - r->charged)
		return (ERX_ENOMEM);
	r->charged += n;
	return (0);
}

int
erx_reserve_fill(erx_reserve_t *r, erx_npages_t k)
{
	if (k > r->charged - r->backed)
		return (ERX_EINVAL);
	r->backed += k;
	r->pooled += k;
	return (0);
}

int
erx_reserve_cancel(erx_reserve_t *r, erx_npages_t k, erx_budget_effects_t *e)
{
	(void)e;
	if (k > r->charged - r->backed)
		return (ERX_EINVAL);
	r->charged -= k;
	return (0);
}

int
erx_reserve_use(erx_reserve_t *r)
{
	if (r->pooled == 0)
		return (ERX_EINVAL);
	r->pooled--;
	return (0);
}

int
erx_reserve_refund(erx_reserve_t *r, erx_npages_t used, erx_npages_t pooled,
    erx_budget_effects_t *e)
{
	(void)e;
	if (pooled > r->pooled || used > r->backed - r->pooled)
		return (ERX_EINVAL);
	r->backed -= used + pooled;
	r->pooled -= pooled;
	r->charged -= used + pooled;
	return (0);
}

/* Whether page is on list; each list is at most FUNNEL_PAGES long. */
static bool
on(const erx_plist_t *list, const erx_page_t *page)
{
	const erx_page_t *at;

	for (at = list->head; at != NULL; at = at->next)
		if (at == page)
			return (true);
	return (false);
}

static erx_npages_t
length(const erx_plist_t *list)
{
	const erx_page_t *at;
	erx_npages_t n = 0;

	for (at = list->head; at != NULL; at = at->next)
		n++;
	return (n);
}

static void
check_funnel(void)
{
	const erx_page_t *at;
	uint64_t last = 0;
	int places;

	__CPROVER_assert(!reserve_locked && !released_locked,
	    "every call releases its locks");
	for (int i = 0; i < FUNNEL_PAGES; i++) {
		places = on(&free_list, &pages[i]) + on(&released.list, &pages[i]) +
		    on(&backing.hand, &pages[i]) + on(&reserve.pool, &pages[i]) +
		    on(&in_use, &pages[i]);
		__CPROVER_assert(places == 1, "every page is in exactly one place");
	}
	__CPROVER_assert(length(&reserve.pool) == reserve.pool.count &&
	    length(&released.list) == released.list.count &&
	    length(&backing.hand) == backing.hand.count,
	    "each chain's count is its length");
	__CPROVER_assert(reserve.pooled == reserve.pool.count,
	    "the pooled count is the pool's length");
	__CPROVER_assert(reserve.backed == reserve.pool.count + in_use.count,
	    "the backed count is the pool's and the in-use pages");
	for (at = released.list.head; at != NULL; at = at->next) {
		__CPROVER_assert(at->stamp >= last,
		    "stamps never decrease along the released list");
		last = at->stamp;
	}
	for (at = reserve.pool.head; at != NULL; at = at->next)
		__CPROVER_assert(erx_grace_mature(TRACKER, at->stamp),
		    "a page joins a pool only after its grace period");
}

void
harness(void)
{
	erx_budget_effects_t effects;
	erx_backing_next_t next;
	bool active = false;
	uint32_t step, op;
	erx_npages_t n, from_pool;
	erx_page_t *page;

	erx_released_init(&released, TRACKER);
	for (int i = 0; i < FUNNEL_PAGES; i++)
		erx_plist_push(&free_list, &pages[i]);

	for (step = 0; step < FUNNEL_STEPS; step++) {
		op = nondet_u32();
		n = nondet_u64();
		switch (op) {
		case 0:
			__CPROVER_assume(!active && n >= 1 && n <= FUNNEL_PAGES);
			active = erx_reserve_charge(&backing, &reserve, n,
			    &effects) == 0;
			break;
		case 1:
			__CPROVER_assume(active);
			next = erx_backing_step(&released, &backing, nondet_bool(),
			    &effects);
			active = next == ERX_BACKING_MORE || next == ERX_BACKING_WAIT;
			break;
		case 2:
			__CPROVER_assume(reserve.pooled > 0);
			erx_effect_reserve_lock(&reserve);
			page = erx_reserve_take(&reserve);
			erx_effect_reserve_unlock(&reserve);
			erx_plist_push(&in_use, page);
			break;
		case 3:
			from_pool = nondet_u64();
			__CPROVER_assume(from_pool <= reserve.pooled);
			__CPROVER_assert(erx_page_release(&released, &reserve,
			    &in_use, from_pool, &effects) == 0,
			    "a release of what the reserve holds succeeds");
			break;
		case 4:
			(void)erx_released_free(&released, n);
			break;
		default:
			/* Grace periods end, up to any stamp issued. */
			__CPROVER_assume(n >= completed && n <= stamped);
			completed = n;
			break;
		}
		check_funnel();
	}
}
