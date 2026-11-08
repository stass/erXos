/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The budget core (docs/design-kernel.md, "Budgets"). One rule decides
 * every change, level by level up a budget's chain:
 *
 * - At a live budget the change gives a new spending. A rise above the
 *   cap is refused there; otherwise the change in what the budget borrows,
 *   max(0, spending - guarantee), passes to the parent as a change of its
 *   lent.
 * - At a dead budget the whole change in spending passes to the parent as
 *   a change of its used, since the parent counts a dead budget's spending
 *   in its own used.
 * - A pin passes up to the root, and grows by one page at the parent of
 *   each level whose pinned rises from zero when that level's record is
 *   the first kept on its cache page: the page is then pinned too.
 *
 * The record cache is here too, since a cache page's charge and its pin
 * are counter changes: a page joins a cache in the hold that charges it
 * and leaves in the hold that refunds it.
 *
 * The chain ends where nothing passes up. An operation plans the whole
 * chain under its locks before it writes anything, then applies the same
 * plan, so a refusal at any level changes nothing at any level.
 */

#include <stdalign.h>

#include "budget_impl.h"

/*
 * What a level does with a budget that is dead. The level an operation
 * charges directly refuses a rise of a dead budget's spending, since a
 * dead budget takes no charge; carving refuses a dead parent outright;
 * the levels above pass whatever reaches them.
 */
typedef enum budget_dead_rule {
	BUDGET_DEAD_PASSES,
	BUDGET_DEAD_TAKES_NO_RISE,
	BUDGET_DEAD_REFUSED
} budget_dead_rule_t;

/*
 * A change of one budget's counters, in pages. Callers change used (a
 * charge or refund) and pinned (a pin, which never falls); carved and
 * lent change only as the core passes a child's change up the chain.
 */
typedef struct budget_delta {
	int64_t		used;
	int64_t		carved;
	int64_t		lent;
	int64_t		pinned;
	/*
	 * The child, below the level this change reaches, whose pinned rose
	 * from zero: its record, in this level's cache, is now kept, and the
	 * level's apply sets its bit in the page's kept mask. NULL for none
	 * and always at the level an operation starts from.
	 */
	erx_budget_t	*keep;
} budget_delta_t;

/* One level's share of a change: its counters after it, and what passes up. */
typedef struct budget_step {
	erx_npages_t		used;
	erx_npages_t		carved;
	erx_npages_t		lent;
	erx_npages_t		pinned;
	erx_npages_t		old_spending;
	erx_npages_t		new_spending;
	budget_delta_t	up;
} budget_step_t;

/* value + delta into *out, refused when it would wrap or fall below zero. */
static bool
add_delta(erx_npages_t value, int64_t delta, erx_npages_t *out)
{
	erx_npages_t magnitude;

	if (delta >= 0)
		return (!__builtin_add_overflow(value, (erx_npages_t)delta, out));
	/* -(delta + 1) + 1 is |delta| without negating INT64_MIN. */
	magnitude = (erx_npages_t)(-(delta + 1)) + 1;
	if (magnitude > value)
		return (false);
	*out = value - magnitude;
	return (true);
}

/* to - from as a signed delta, refused when it does not fit. */
static bool
difference(erx_npages_t to, erx_npages_t from, int64_t *out)
{
	if (to >= from) {
		if (to - from > (erx_npages_t)INT64_MAX)
			return (false);
		*out = (int64_t)(to - from);
		return (true);
	}
	if (from - to > (erx_npages_t)INT64_MAX)
		return (false);
	*out = -(int64_t)(from - to);
	return (true);
}

static bool
spending(erx_npages_t used, erx_npages_t carved, erx_npages_t lent,
    erx_npages_t *out)
{
	erx_npages_t sum;

	return (!__builtin_add_overflow(used, carved, &sum) &&
	    !__builtin_add_overflow(sum, lent, out));
}

static erx_npages_t
borrowing(erx_npages_t spent, erx_npages_t guarantee)
{
	return (spent > guarantee ? spent - guarantee : 0);
}

static bool
delta_is_zero(const budget_delta_t *delta)
{
	return (delta->used == 0 && delta->carved == 0 && delta->lent == 0 &&
	    delta->pinned == 0 && delta->keep == NULL);
}

/*
 * Whether keeping child's record pins its cache page: the first record
 * kept on a page pins it. Read under the lock of the page's budget, the
 * child's parent, which the plan holds when the change reaches it.
 */
static bool
keep_pins_page(const erx_budget_t *child)
{
	return (child != NULL && child->home.page->kept == 0);
}

/*
 * The pure decision at one level: budget's counters under delta. Returns
 * 0 with the level's new counters and the change for its parent in *step,
 * or the status that refuses the whole change.
 */
static int
budget_step(const erx_budget_t *budget, const budget_delta_t *delta,
    budget_dead_rule_t dead_rule, budget_step_t *step)
{
	erx_npages_t new_borrowing, old_borrowing;
	int64_t pinned = delta->pinned;

	if (pinned < 0)
		return (ERX_EINVAL);
	if (keep_pins_page(delta->keep)) {
		if (pinned == INT64_MAX)
			return (ERX_EINVAL);
		pinned++;
	}
	if (!add_delta(budget->used, delta->used, &step->used) ||
	    !add_delta(budget->carved, delta->carved, &step->carved) ||
	    !add_delta(budget->lent, delta->lent, &step->lent) ||
	    !add_delta(budget->pinned, pinned, &step->pinned))
		return (ERX_EINVAL);
	if (!spending(budget->used, budget->carved, budget->lent,
	    &step->old_spending) ||
	    !spending(step->used, step->carved, step->lent,
	    &step->new_spending))
		return (ERX_EINVAL);

	step->up = (budget_delta_t){ .pinned = pinned };
	if (budget->pinned == 0 && step->pinned != 0 &&
	    budget->home.page != NULL)
		step->up.keep = (erx_budget_t *)(uintptr_t)budget;
	if (budget->dead) {
		if (dead_rule == BUDGET_DEAD_REFUSED ||
		    (dead_rule == BUDGET_DEAD_TAKES_NO_RISE &&
		    step->new_spending > step->old_spending))
			return (ERX_ESTALE);
		if (!difference(step->new_spending, step->old_spending,
		    &step->up.used))
			return (ERX_EINVAL);
		return (0);
	}

	/* A cap below the spending refuses only what would raise it. */
	if (step->new_spending > step->old_spending &&
	    step->new_spending > budget->cap)
		return (ERX_ENOMEM);
	old_borrowing = borrowing(step->old_spending, budget->guarantee);
	new_borrowing = borrowing(step->new_spending, budget->guarantee);
	if (!difference(new_borrowing, old_borrowing, &step->up.lent))
		return (ERX_EINVAL);
	return (0);
}

/*
 * Plans delta at budget and up its chain, taking each level's lock as the
 * plan reaches it, descendant first. On return *nlocked levels are locked,
 * from budget up, whatever the status; *refused names the level that
 * refused.
 */
static int
chain_plan(erx_budget_t *budget, budget_delta_t delta,
    budget_dead_rule_t dead_rule, uint32_t *nlocked, erx_budget_t **refused)
{
	budget_step_t step;
	erx_budget_t *level;
	int error;

	*nlocked = 0;
	for (level = budget; level != NULL; level = level->parent) {
		if (*nlocked == ERX_BUDGET_DEPTH_MAX)
			return (ERX_EINVAL);
		erx_effect_budget_lock(level);
		(*nlocked)++;
		error = budget_step(level, &delta, dead_rule, &step);
		if (error != 0) {
			*refused = level;
			return (error);
		}
		if (delta_is_zero(&step.up))
			break;
		delta = step.up;
		dead_rule = BUDGET_DEAD_PASSES;
	}
	return (0);
}

/* Whether this level's change crosses its armed watch's threshold. */
static bool
watch_crossed(const erx_budget_t *level, const budget_step_t *step)
{
	return (!level->dead && level->threshold != 0 &&
	    step->old_spending < level->threshold &&
	    step->new_spending >= level->threshold);
}

/* Lists what the caller must do once the locks drop. */
static void
note_effects(erx_budget_t *level, const budget_step_t *step,
    erx_budget_effects_t *effects)
{
	if (watch_crossed(level, step) && level->watch != NULL)
		effects->fire[effects->nfire++] = level->watch;
	if (level->dead && step->old_spending != 0 &&
	    step->new_spending == 0 && step->pinned == 0)
		effects->tombstone[effects->ntombstone++] = level;
}

/*
 * Writes one level's accepted step, under its lock: its counters, the
 * kept record of the child the change came from, and its effects.
 */
static void
level_apply(erx_budget_t *level, const budget_delta_t *delta,
    const budget_step_t *step, erx_budget_effects_t *effects)
{
	note_effects(level, step, effects);
	if (watch_crossed(level, step))
		level->threshold = 0;	/* the watch fires once */
	if (delta->keep != NULL)
		delta->keep->home.page->kept |= UINT64_C(1) <<
		    delta->keep->home.index;
	level->used = step->used;
	level->carved = step->carved;
	level->lent = step->lent;
	level->pinned = step->pinned;
}

/*
 * Applies the plan chain_plan accepted over the same nlocked levels. Each
 * step is recomputed rather than stored, since sixteen stored steps would
 * not fit the stack proof's frame cap, and the recomputation is the plan:
 * budget_step reads only the level's counters, the change from below and
 * the kept mask of the page holding that change's keep, every level is
 * still locked, and applying a level writes nothing a level above reads.
 * The one write outside the level's record, the kept bit, lands on a page
 * of this level's own cache after this level's step; every page has one
 * owner, so the level above reads a page of its own cache, never this one.
 */
static void
chain_apply(erx_budget_t *budget, budget_delta_t delta,
    budget_dead_rule_t dead_rule, uint32_t nlocked,
    erx_budget_effects_t *effects)
{
	budget_step_t step;
	erx_budget_t *level;
	uint32_t i;

	level = budget;
	for (i = 0; i < nlocked; i++) {
		/* chain_plan accepted this very step under the same locks. */
		(void)budget_step(level, &delta, dead_rule, &step);
		level_apply(level, &delta, &step, effects);
		delta = step.up;
		dead_rule = BUDGET_DEAD_PASSES;
		level = level->parent;
	}
}

static void
chain_unlock(erx_budget_t *budget, uint32_t nlocked)
{
	erx_budget_t *level;
	uint32_t i;

	level = budget;
	for (i = 0; i < nlocked; i++) {
		erx_effect_budget_unlock(level);
		level = level->parent;
	}
}

/* Plans, applies on acceptance, and unlocks: one whole change. */
static int
chain_change(erx_budget_t *budget, const budget_delta_t *delta,
    budget_dead_rule_t dead_rule, erx_budget_effects_t *effects)
{
	uint32_t nlocked;
	int error;

	error = chain_plan(budget, *delta, dead_rule, &nlocked,
	    &effects->refused);
	if (error == 0) {
		effects->refused = NULL;
		chain_apply(budget, *delta, dead_rule, nlocked, effects);
	}
	chain_unlock(budget, nlocked);
	return (error);
}

static void
effects_clear(erx_budget_effects_t *effects)
{
	effects->refused = NULL;
	effects->nfire = 0;
	effects->ntombstone = 0;
}

static bool
npages_delta(erx_npages_t pages, int64_t *out)
{
	return (difference(pages, 0, out));
}

size_t
erx_budget_record_size(void)
{
	return (sizeof(erx_budget_t));
}

size_t
erx_budget_record_align(void)
{
	return (alignof(erx_budget_t));
}

size_t
erx_reserve_record_size(void)
{
	return (sizeof(erx_reserve_t));
}

size_t
erx_reserve_record_align(void)
{
	return (alignof(erx_reserve_t));
}

int
erx_budget_init_root(erx_budget_t *root, erx_npages_t pages)
{
	if (pages > (erx_npages_t)INT64_MAX)
		return (ERX_EINVAL);
	*root = (erx_budget_t){
		.guarantee = pages,
		.cap = pages,
		.kind = ERX_BUDGET_WALL,
	};
	return (0);
}

/*
 * The record cache. A page is its header, then its records at
 * KCACHE_RECORDS_AT, each kcache_record_bytes[kind] long, 64-byte aligned.
 */
#define KCACHE_RECORDS_AT	64u
#define KCACHE_BITS		64u

_Static_assert(sizeof(struct erx_kcache_page) <= KCACHE_RECORDS_AT,
    "a cache page's header fits before its first record");
/* A record is its object's header area, then the type's own body. */
#define KCACHE_RECORD_BYTES(body) \
	((ERX_OBJECT_HEADER_BYTES + sizeof(body) + 63u) & ~(size_t)63u)

_Static_assert(KCACHE_RECORD_BYTES(erx_budget_t) <=
    ERX_KCACHE_PAGE_BYTES - KCACHE_RECORDS_AT,
    "a cache page holds at least one budget record");

static const size_t kcache_record_bytes[ERX_KCACHE_NKINDS] = {
	[ERX_KCACHE_BUDGET] = KCACHE_RECORD_BYTES(erx_budget_t),
};

uint32_t
erx_kcache_capacity(erx_kcache_kind_t kind)
{
	size_t n;

	if ((uint32_t)kind >= ERX_KCACHE_NKINDS)
		return (0);
	n = (ERX_KCACHE_PAGE_BYTES - KCACHE_RECORDS_AT) /
	    kcache_record_bytes[kind];
	return (n < KCACHE_BITS ? (uint32_t)n : KCACHE_BITS);
}

/* The taken mask of a full page of the kind. */
static uint64_t
kcache_full(erx_kcache_kind_t kind)
{
	uint32_t n = erx_kcache_capacity(kind);

	return (n == KCACHE_BITS ? UINT64_MAX : (UINT64_C(1) << n) - 1);
}

void *
erx_kcache_record(const erx_kcache_slot_t *slot)
{
	return ((unsigned char *)slot->page + KCACHE_RECORDS_AT +
	    (size_t)slot->index * kcache_record_bytes[slot->page->kind]);
}

static void
kcache_unlink(erx_kcache_t *cache, struct erx_kcache_page *page)
{
	if (page->prev != NULL)
		page->prev->next = page->next;
	else
		cache->partial = page->next;
	if (page->next != NULL)
		page->next->prev = page->prev;
	page->prev = page->next = NULL;
}

static void
kcache_push(erx_kcache_t *cache, struct erx_kcache_page *page)
{
	page->prev = NULL;
	page->next = cache->partial;
	if (page->next != NULL)
		page->next->prev = page;
	cache->partial = page;
}

/*
 * Takes the lowest free record of a page on the partial list, under the
 * budget's lock; a page that fills leaves the list.
 */
static void
kcache_take_from(erx_kcache_t *cache, struct erx_kcache_page *page,
    erx_kcache_slot_t *slot)
{
	uint32_t index = (uint32_t)__builtin_ctzll(~page->taken);

	page->taken |= UINT64_C(1) << index;
	if (page->taken == kcache_full(page->kind))
		kcache_unlink(cache, page);
	*slot = (erx_kcache_slot_t){ .page = page, .index = index };
}

/*
 * One change at budget, whose lock the caller holds: the budget's own
 * step, then its parent's chain for what passes up, as resize and close
 * do, applied whole or not at all. A decrease never fails.
 */
static int
held_change(erx_budget_t *budget, const budget_delta_t *delta,
    budget_dead_rule_t dead_rule, erx_budget_effects_t *effects)
{
	budget_step_t step;
	int error;

	error = budget_step(budget, delta, dead_rule, &step);
	if (error == 0 && !delta_is_zero(&step.up))
		error = chain_change(budget->parent, &step.up,
		    BUDGET_DEAD_PASSES, effects);
	else if (error != 0)
		effects->refused = budget;
	if (error == 0)
		level_apply(budget, delta, &step, effects);
	return (error);
}

/*
 * Takes the lowest free record of the cache's first listed page or,
 * when no page has one, of page, which becomes a new cache page of
 * budget's. The caller holds budget's lock and has charged the new page
 * in the same hold.
 */
static void
kcache_place(erx_budget_t *budget, erx_kcache_kind_t kind, void *page,
    erx_kcache_slot_t *slot)
{
	erx_kcache_t *cache = &budget->caches[kind];
	struct erx_kcache_page *fresh;

	if (cache->partial == NULL) {
		fresh = page;
		*fresh = (struct erx_kcache_page){ .owner = budget,
		    .kind = kind };
		kcache_push(cache, fresh);
		cache->npages++;
	}
	kcache_take_from(cache, cache->partial, slot);
}

int
erx_kcache_take(erx_budget_t *budget, erx_kcache_kind_t kind, void *page,
    erx_kcache_slot_t *slot, bool *page_taken, erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	int error;

	effects_clear(effects);
	*page_taken = false;
	*slot = (erx_kcache_slot_t){ .page = NULL, .index = 0 };
	if ((uint32_t)kind >= ERX_KCACHE_NKINDS)
		return (ERX_EINVAL);

	erx_effect_budget_lock(budget);
	delta.used = budget->caches[kind].partial == NULL ? 1 : 0;
	if (budget->dead)
		error = ERX_ESTALE;
	else if (delta.used != 0 && page == NULL)
		error = ERX_ELIMIT;
	else
		error = held_change(budget, &delta, BUDGET_DEAD_TAKES_NO_RISE,
		    effects);
	if (error == 0) {
		kcache_place(budget, kind, page, slot);
		*page_taken = delta.used != 0;
	}
	erx_effect_budget_unlock(budget);
	return (error);
}

/*
 * Whether slot names a page of owner's cache of the kind and an index on
 * it; the page's owner and kind are fixed when it joins the cache, so a
 * slot of another budget's cache is refused before its lock matters.
 */
static bool
kcache_slot_valid(const erx_kcache_slot_t *slot, const erx_budget_t *owner,
    erx_kcache_kind_t kind)
{
	return (slot->page != NULL && slot->page->owner == owner &&
	    slot->page->kind == kind &&
	    slot->index < erx_kcache_capacity(kind));
}

int
erx_kcache_free(erx_budget_t *budget, erx_kcache_kind_t kind,
    const erx_kcache_slot_t *slot, void **page_out,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	struct erx_kcache_page *page;
	erx_kcache_t *cache;
	uint64_t bit;
	bool was_full;
	int error = 0;

	effects_clear(effects);
	*page_out = NULL;
	if ((uint32_t)kind >= ERX_KCACHE_NKINDS)
		return (ERX_EINVAL);
	cache = &budget->caches[kind];

	erx_effect_budget_lock(budget);
	page = slot->page;
	bit = kcache_slot_valid(slot, budget, kind) ?
	    UINT64_C(1) << slot->index : 0;
	if (bit == 0 || (page->taken & bit) == 0 || cache->npages == 0) {
		error = ERX_EINVAL;
	} else if ((page->kept & bit) != 0) {
		error = ERX_EBUSY;
	} else {
		was_full = page->taken == kcache_full(kind);
		page->taken &= ~bit;
		if (page->taken == 0) {
			if (!was_full)
				kcache_unlink(cache, page);
			cache->npages--;
			/* A decrease: it never fails. */
			delta.used = -1;
			(void)held_change(budget, &delta,
			    BUDGET_DEAD_TAKES_NO_RISE, effects);
			*page_out = page;
		} else if (was_full) {
			kcache_push(cache, page);
		}
	}
	erx_effect_budget_unlock(budget);
	return (error);
}

int
erx_budget_carve(erx_budget_t *parent, void *page, erx_budget_kind_t kind,
    erx_npages_t guarantee, erx_npages_t cap, erx_budget_t **childp,
    bool *page_taken, erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	erx_kcache_slot_t slot;
	erx_budget_t *child;
	int error;

	effects_clear(effects);
	*childp = NULL;
	*page_taken = false;
	if (kind != ERX_BUDGET_WALL && kind != ERX_BUDGET_ELASTIC)
		return (ERX_EINVAL);
	if (cap < guarantee || (kind == ERX_BUDGET_WALL && cap != guarantee))
		return (ERX_EINVAL);
	if (!npages_delta(guarantee, &delta.carved))
		return (ERX_EINVAL);
	/* depth is fixed at carving, so it is read without the lock. */
	if (parent->depth >= ERX_BUDGET_DEPTH_MAX - 1)
		return (ERX_ELIMIT);

	/*
	 * One plan in one hold of the parent's lock: the record's new cache
	 * page, if the cache has no free record, and the guarantee. The record
	 * is taken only when the plan is applied, so a record is taken in the
	 * parent's cache of budget records exactly when a budget is carved
	 * into it.
	 */
	erx_effect_budget_lock(parent);
	delta.used = parent->caches[ERX_KCACHE_BUDGET].partial == NULL ? 1 : 0;
	if (parent->dead)
		error = ERX_ESTALE;
	else if (delta.used != 0 && page == NULL)
		error = ERX_ELIMIT;
	else
		error = held_change(parent, &delta, BUDGET_DEAD_REFUSED,
		    effects);
	if (error == 0) {
		kcache_place(parent, ERX_KCACHE_BUDGET, page, &slot);
		*page_taken = delta.used != 0;
		child = erx_object_body(erx_kcache_record(&slot));
		*child = (erx_budget_t){
			.parent = parent,
			.guarantee = guarantee,
			.cap = cap,
			.depth = parent->depth + 1,
			.kind = kind,
			.home = slot,
		};
		*childp = child;
	}
	erx_effect_budget_unlock(parent);
	return (error);
}

int
erx_budget_free_record(erx_budget_t *budget, void **page_out,
    erx_budget_effects_t *effects)
{
	erx_kcache_slot_t home = budget->home;
	erx_budget_t *parent = budget->parent;
	bool empty;

	*page_out = NULL;
	effects_clear(effects);
	if (parent == NULL || !erx_budget_dead(budget))
		return (ERX_EINVAL);
	/*
	 * Only an empty tombstone is freed: nothing is charged to it, so no
	 * cache page of its own holds a record. A dead budget takes no rise,
	 * so the check stays true once its lock is dropped.
	 */
	erx_effect_budget_lock(budget);
	empty = budget->used == 0 && budget->carved == 0 && budget->lent == 0;
	erx_effect_budget_unlock(budget);
	if (!empty)
		return (ERX_EBUSY);
	/* The record is gone once this returns: only the copies are read. */
	return (erx_kcache_free(parent, ERX_KCACHE_BUDGET, &home, page_out,
	    effects));
}

int
erx_budget_adjust(erx_budget_t *budget, int64_t pages,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { .used = pages };

	effects_clear(effects);
	return (chain_change(budget, &delta, BUDGET_DEAD_TAKES_NO_RISE,
	    effects));
}

int
erx_budget_pin(erx_budget_t *budget, erx_npages_t pages,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };

	effects_clear(effects);
	if (!npages_delta(pages, &delta.pinned))
		return (ERX_EINVAL);
	return (chain_change(budget, &delta, BUDGET_DEAD_TAKES_NO_RISE,
	    effects));
}

/*
 * Resize and close change the budget's own guarantee or state and pass
 * the consequence to the parent as one change; the budget's own lock is
 * held across the parent's plan, descendant first as everywhere.
 */
int
erx_budget_resize(erx_budget_t *budget, erx_npages_t guarantee,
    erx_npages_t cap, erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	erx_npages_t spent;
	int error;

	effects_clear(effects);
	if (budget->parent == NULL)
		return (ERX_EINVAL);
	if (cap < guarantee ||
	    (budget->kind == ERX_BUDGET_WALL && cap != guarantee))
		return (ERX_EINVAL);

	erx_effect_budget_lock(budget);
	if (budget->dead) {
		error = ERX_ESTALE;
	} else if (!spending(budget->used, budget->carved, budget->lent,
	    &spent) ||
	    !difference(guarantee, budget->guarantee, &delta.carved) ||
	    !difference(borrowing(spent, guarantee),
	    borrowing(spent, budget->guarantee), &delta.lent)) {
		error = ERX_EINVAL;
	} else {
		error = chain_change(budget->parent, &delta,
		    BUDGET_DEAD_TAKES_NO_RISE, effects);
	}
	if (error == 0) {
		budget->guarantee = guarantee;
		budget->cap = cap;
	}
	erx_effect_budget_unlock(budget);
	return (error);
}

/*
 * The parent's change at a close: its used gains the budget's spending s,
 * its carved loses the guarantee g and its lent the borrowing
 * max(0, s - g). Its spending changes by s - max(s, g), never a rise, so
 * the close never fails for room. Every value is at most the root's
 * pages, at most INT64_MAX, so the conversions fail only on corruption.
 */
static bool
close_parent_delta(const erx_budget_t *budget, erx_npages_t *spent,
    budget_delta_t *delta)
{
	if (!spending(budget->used, budget->carved, budget->lent, spent))
		return (false);
	if (!npages_delta(*spent, &delta->used))
		return (false);
	if (!difference(0, budget->guarantee, &delta->carved))
		return (false);
	return (difference(0, borrowing(*spent, budget->guarantee),
	    &delta->lent));
}

int
erx_budget_close(erx_budget_t *budget, erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	erx_npages_t spent;
	int error;

	effects_clear(effects);
	if (budget->parent == NULL)
		return (ERX_EINVAL);

	erx_effect_budget_lock(budget);
	if (budget->dead) {
		error = ERX_ESTALE;
	} else if (!close_parent_delta(budget, &spent, &delta)) {
		error = ERX_EINVAL;
	} else {
		error = chain_change(budget->parent, &delta,
		    BUDGET_DEAD_PASSES, effects);
	}
	if (error == 0) {
		atomic_store_explicit(&budget->dead, true, memory_order_release);
		if (spent == 0 && budget->pinned == 0)
			effects->tombstone[effects->ntombstone++] = budget;
	}
	erx_effect_budget_unlock(budget);
	return (error);
}

int
erx_budget_watch(erx_budget_t *budget, struct erx_irq *irq,
    erx_npages_t threshold, bool *fire)
{
	erx_npages_t spent;
	int error;

	*fire = false;
	erx_effect_budget_lock(budget);
	if (budget->dead) {
		error = ERX_ESTALE;
	} else if (irq == NULL) {
		budget->watch = NULL;
		budget->threshold = 0;
		error = 0;
	} else if (budget->watch != NULL && budget->watch != irq) {
		error = ERX_EBUSY;
	} else if (!spending(budget->used, budget->carved, budget->lent,
	    &spent)) {
		error = ERX_EINVAL;
	} else {
		budget->watch = irq;
		*fire = spent >= threshold;
		budget->threshold = *fire ? 0 : threshold;
		error = 0;
	}
	erx_effect_budget_unlock(budget);
	return (error);
}

bool
erx_budget_watch_detach(erx_budget_t *budget, struct erx_irq *irq)
{
	bool detached;

	erx_effect_budget_lock(budget);
	detached = irq != NULL && budget->watch == irq;
	if (detached) {
		budget->watch = NULL;
		budget->threshold = 0;
	}
	erx_effect_budget_unlock(budget);
	return (detached);
}

void
erx_budget_read(erx_budget_t *budget, erx_budget_counters_t *counters)
{
	/* Padding included, so a bytewise copy carries no stack residue. */
	__builtin_memset(counters, 0, sizeof(*counters));
	erx_effect_budget_lock(budget);
	*counters = (erx_budget_counters_t){
		.kind = budget->kind,
		.depth = budget->depth,
		.dead = atomic_load_explicit(&budget->dead, memory_order_relaxed),
		.guarantee = budget->guarantee,
		.cap = budget->cap,
		.used = budget->used,
		.carved = budget->carved,
		.lent = budget->lent,
		.pinned = budget->pinned,
		.threshold = budget->threshold,
	};
	erx_effect_budget_unlock(budget);
}

bool
erx_budget_dead(const erx_budget_t *budget)
{
	return (atomic_load_explicit(&budget->dead, memory_order_acquire));
}

erx_budget_t *
erx_budget_parent(const erx_budget_t *budget)
{
	return (budget->parent);
}

erx_charged_list_t *
erx_budget_charged(erx_budget_t *budget)
{
	return (&budget->att_charged);
}

void
erx_reserve_init(erx_reserve_t *reserve, erx_budget_t *budget)
{
	*reserve = (erx_reserve_t){ .budget = budget };
}

erx_budget_t *
erx_reserve_budget(const erx_reserve_t *reserve)
{
	return (reserve->budget);
}

void
erx_reserve_read(const erx_reserve_t *reserve, erx_reserve_counts_t *counts)
{
	*counts = (erx_reserve_counts_t){
		.charged = reserve->charged,
		.backed = reserve->backed,
		.pooled = reserve->pooled,
	};
}

int
erx_reserve_admit(erx_reserve_t *reserve, erx_npages_t pages,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	erx_npages_t charged;
	int error;

	effects_clear(effects);
	if (!npages_delta(pages, &delta.used) ||
	    __builtin_add_overflow(reserve->charged, pages, &charged))
		return (ERX_EINVAL);
	error = chain_change(reserve->budget, &delta,
	    BUDGET_DEAD_TAKES_NO_RISE, effects);
	if (error == 0)
		reserve->charged = charged;
	return (error);
}

int
erx_reserve_fill(erx_reserve_t *reserve, erx_npages_t pages)
{
	if (pages > reserve->charged - reserve->backed)
		return (ERX_EINVAL);
	reserve->backed += pages;
	reserve->pooled += pages;
	return (0);
}

int
erx_reserve_cancel(erx_reserve_t *reserve, erx_npages_t pages,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	int error;

	effects_clear(effects);
	if (pages > reserve->charged - reserve->backed ||
	    !npages_delta(pages, &delta.used))
		return (ERX_EINVAL);
	delta.used = -delta.used;
	error = chain_change(reserve->budget, &delta,
	    BUDGET_DEAD_TAKES_NO_RISE, effects);
	if (error == 0)
		reserve->charged -= pages;
	return (error);
}

int
erx_reserve_use(erx_reserve_t *reserve)
{
	if (reserve->pooled == 0)
		return (ERX_EINVAL);
	reserve->pooled--;
	return (0);
}

int
erx_reserve_refund(erx_reserve_t *reserve, erx_npages_t in_use,
    erx_npages_t pooled, erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	erx_npages_t pages;
	int error;

	effects_clear(effects);
	if (pooled > reserve->pooled ||
	    in_use > reserve->backed - reserve->pooled ||
	    __builtin_add_overflow(in_use, pooled, &pages) ||
	    !npages_delta(pages, &delta.used))
		return (ERX_EINVAL);
	delta.used = -delta.used;
	error = chain_change(reserve->budget, &delta,
	    BUDGET_DEAD_TAKES_NO_RISE, effects);
	if (error == 0) {
		reserve->backed -= pages;
		reserve->charged -= pages;
		reserve->pooled -= pooled;
	}
	return (error);
}
