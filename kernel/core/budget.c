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
 * - A pin passes up unchanged, to the root.
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
	    delta->pinned == 0);
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

	if (delta->pinned < 0)
		return (ERX_EINVAL);
	if (!add_delta(budget->used, delta->used, &step->used) ||
	    !add_delta(budget->carved, delta->carved, &step->carved) ||
	    !add_delta(budget->lent, delta->lent, &step->lent) ||
	    !add_delta(budget->pinned, delta->pinned, &step->pinned))
		return (ERX_EINVAL);
	if (!spending(budget->used, budget->carved, budget->lent,
	    &step->old_spending) ||
	    !spending(step->used, step->carved, step->lent,
	    &step->new_spending))
		return (ERX_EINVAL);

	step->up = (budget_delta_t){ .pinned = delta->pinned };
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
	if (level->pinned == 0 && step->pinned != 0)
		effects->first_pin[effects->nfirst_pin++] = level;
	if (level->dead && step->old_spending != 0 &&
	    step->new_spending == 0 && step->pinned == 0)
		effects->tombstone[effects->ntombstone++] = level;
}

/*
 * Applies the plan chain_plan accepted over the same nlocked levels. Each
 * step is recomputed rather than stored, since sixteen stored steps would
 * not fit the stack proof's frame cap, and the recomputation is the plan:
 * budget_step is a pure function of the level's counters and the change
 * from below, every level is still locked, and applying a level writes
 * nothing the level above reads.
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
		note_effects(level, &step, effects);
		if (watch_crossed(level, &step))
			level->threshold = 0;	/* the watch fires once */
		level->used = step.used;
		level->carved = step.carved;
		level->lent = step.lent;
		level->pinned = step.pinned;
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
	effects->nfirst_pin = 0;
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

int
erx_budget_carve(erx_budget_t *parent, erx_budget_t *child,
    erx_budget_kind_t kind, erx_npages_t guarantee, erx_npages_t cap,
    erx_budget_effects_t *effects)
{
	budget_delta_t delta = { 0 };
	int error;

	effects_clear(effects);
	if (kind != ERX_BUDGET_WALL && kind != ERX_BUDGET_ELASTIC)
		return (ERX_EINVAL);
	if (cap < guarantee || (kind == ERX_BUDGET_WALL && cap != guarantee))
		return (ERX_EINVAL);
	if (!npages_delta(guarantee, &delta.carved))
		return (ERX_EINVAL);
	/* depth is fixed at carving, so it is read without the lock. */
	if (parent->depth >= ERX_BUDGET_DEPTH_MAX - 1)
		return (ERX_ELIMIT);

	error = chain_change(parent, &delta, BUDGET_DEAD_REFUSED, effects);
	if (error != 0)
		return (error);
	*child = (erx_budget_t){
		.parent = parent,
		.guarantee = guarantee,
		.cap = cap,
		.depth = parent->depth + 1,
		.kind = kind,
	};
	return (0);
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
		budget->dead = true;
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
		.dead = budget->dead,
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

erx_budget_t *
erx_budget_parent(const erx_budget_t *budget)
{
	return (budget->parent);
}

void
erx_budget_walk_begin(erx_budget_walk_t *walk, erx_budget_t *top)
{
	*walk = (erx_budget_walk_t){ .top = top, .cursor = top };
}

erx_budget_walk_action_t
erx_budget_walk_next(erx_budget_walk_t *walk, erx_budget_head_t head,
    erx_budget_t *head_budget)
{
	walk->subject = NULL;
	switch (head) {
	case ERX_BUDGET_HEAD_OBJECT:
		return (ERX_BUDGET_WALK_DESTROY);
	case ERX_BUDGET_HEAD_BUDGET:
		if (head_budget == NULL || head_budget->parent != walk->cursor)
			return (ERX_BUDGET_WALK_INVALID);
		walk->subject = head_budget;
		walk->cursor = head_budget;
		return (ERX_BUDGET_WALK_ENTER);
	case ERX_BUDGET_HEAD_EMPTY:
		break;
	default:
		return (ERX_BUDGET_WALK_INVALID);
	}
	if (walk->cursor == walk->top)
		return (ERX_BUDGET_WALK_DONE);
	walk->subject = walk->cursor;
	walk->cursor = walk->cursor->parent;
	return (ERX_BUDGET_WALK_LEAVE);
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
