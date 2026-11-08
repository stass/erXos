/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: a whole budget change along a chain (kernel/core/budget.c,
 * chain_plan, chain_apply and chain_unlock behind erx_budget_adjust,
 * erx_budget_pin and erx_budget_carve), with a refused charge as the
 * allocation failure.
 *
 * Bounds: a chain of CHAIN_DEPTH budgets, root at index 0, every counter
 * of every level nondeterministic. The operation and its pages are
 * nondeterministic; it starts at the leaf, since a change that starts
 * higher is the same as one on a shorter chain, and a constant start keeps
 * every pointer the core follows constant for the solver. The loops run
 * at most CHAIN_DEPTH + 1 times; the roster's unwind bound covers that,
 * and the unwinding assertions prove it.
 *
 * Assumptions: the chain's shape is one erx_budget_carve makes (parent
 * links, depths, kinds, a cap at or above the guarantee and equal to it
 * for a wall) and the root is live, a wall, and at most INT64_MAX pages,
 * as erx_budget_init_root makes it. The counters are otherwise free, a
 * superset of the reachable states. The lock effects are stubs that check
 * their own use; the ticket lock itself is not modelled.
 *
 * Checked: the change is whole or nothing (K3's "every change goes
 * through the one plan"): a refusal leaves every counter of every level as
 * it was and names a level of the chain; an accepted change takes no
 * live level's spending above its cap where it rises (K3); each level
 * the leaf changes by exactly what the operation asked and a pin reaches
 * the root; every level above the leaf changes by exactly the change of
 * its child's borrowing (live child) or spending (dead child), computed
 * from the counters rather than from where the core stopped; every lock
 * taken is taken once, descendant first, and released before the call
 * returns.
 */

#include "cbmc_harness.h"
#include "budget.c"

#ifndef CHAIN_DEPTH
#define CHAIN_DEPTH 3
#endif
#ifndef CHAIN_VALUE_MAX
#define CHAIN_VALUE_MAX UINT64_C(255)
#endif

static erx_budget_t chain[CHAIN_DEPTH];
static erx_budget_t before[CHAIN_DEPTH];
/* The cache page a carve's record sits in: its header says its kind. */
static _Alignas(64) unsigned char carve_page[ERX_KCACHE_PAGE_BYTES];
static bool held[CHAIN_DEPTH];
static bool locked_ever[CHAIN_DEPTH];
static int last_locked = -1;

static int
level_of(const erx_budget_t *budget)
{
	int i;

	for (i = 0; i < CHAIN_DEPTH; i++)
		if (budget == &chain[i])
			return (i);
	return (-1);
}

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	int i = level_of(budget);

	__CPROVER_assert(i >= 0, "a lock names a level of the chain");
	__CPROVER_assert(!held[i], "no level is locked twice");
	__CPROVER_assert(last_locked < 0 || i == last_locked - 1,
	    "locks are taken descendant first, one level at a time");
	held[i] = true;
	locked_ever[i] = true;
	last_locked = i;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	int i = level_of(budget);

	__CPROVER_assert(i >= 0 && held[i], "an unlock releases a held lock");
	held[i] = false;
}

static __int128
spent(const erx_budget_t *budget)
{
	return ((__int128)budget->used + budget->carved + budget->lent);
}

static __int128
borrowed(const erx_budget_t *budget)
{
	__int128 s = spent(budget);

	return (s > (__int128)budget->guarantee ? s - budget->guarantee : 0);
}

static bool
same_counters(const erx_budget_t *a, const erx_budget_t *b)
{
	return (a->used == b->used && a->carved == b->carved &&
	    a->lent == b->lent && a->pinned == b->pinned &&
	    a->guarantee == b->guarantee && a->cap == b->cap &&
	    a->dead == b->dead && a->threshold == b->threshold);
}

static void
shape_chain(void)
{
	int i;

	for (i = 0; i < CHAIN_DEPTH; i++) {
		chain[i] = (erx_budget_t){
			.parent = i == 0 ? NULL : &chain[i - 1],
			.watch = NULL,
			.guarantee = nondet_u64(),
			.cap = nondet_u64(),
			.used = nondet_u64(),
			.carved = nondet_u64(),
			.lent = nondet_u64(),
			.pinned = nondet_u64(),
			.threshold = nondet_u64(),
			.depth = (uint32_t)i,
			.kind = nondet_bool() ? ERX_BUDGET_WALL : ERX_BUDGET_ELASTIC,
			.dead = i == 0 ? false : nondet_bool(),
		};
		__CPROVER_assume(chain[i].guarantee <= CHAIN_VALUE_MAX &&
		    chain[i].cap <= CHAIN_VALUE_MAX &&
		    chain[i].used <= CHAIN_VALUE_MAX &&
		    chain[i].carved <= CHAIN_VALUE_MAX &&
		    chain[i].lent <= CHAIN_VALUE_MAX &&
		    chain[i].pinned <= CHAIN_VALUE_MAX &&
		    chain[i].threshold <= CHAIN_VALUE_MAX);
		__CPROVER_assume(chain[i].cap >= chain[i].guarantee);
		__CPROVER_assume(chain[i].kind != ERX_BUDGET_WALL ||
		    chain[i].cap == chain[i].guarantee);
		before[i] = chain[i];
	}
	__CPROVER_assume(chain[0].kind == ERX_BUDGET_WALL &&
	    chain[0].guarantee <= (erx_npages_t)INT64_MAX);
}

void
harness(void)
{
	erx_budget_effects_t effects;
	erx_budget_t *child;
	erx_kcache_slot_t slot;
	const int start = CHAIN_DEPTH - 1;
	uint32_t op = nondet_u32();
	int64_t pages = nondet_i64();
	erx_npages_t pin = nondet_u64();
	erx_npages_t guarantee = nondet_u64();
	int error, i;

	shape_chain();
	__CPROVER_assume(op < 3);
	if (op == 0)
		error = erx_budget_adjust(&chain[start], pages, &effects);
	else if (op == 1)
		error = erx_budget_pin(&chain[start], pin, &effects);
	else {
		((struct erx_kcache_page *)(void *)carve_page)->kind =
		    ERX_KCACHE_BUDGET;
		slot = (erx_kcache_slot_t){
			.page = (struct erx_kcache_page *)(void *)carve_page,
			.index = 0,
		};
		error = erx_budget_carve(&chain[start], &slot,
		    ERX_BUDGET_ELASTIC, guarantee, guarantee, &child, &effects);
	}

	for (i = 0; i < CHAIN_DEPTH; i++)
		__CPROVER_assert(!held[i], "every lock is released");
	for (i = 0; i < CHAIN_DEPTH; i++)
		__CPROVER_assert(locked_ever[i] || same_counters(&chain[i],
		    &before[i]), "no unlocked level changes");
	__CPROVER_assert(effects.nfire <= ERX_BUDGET_DEPTH_MAX &&
	    effects.ntombstone <= ERX_BUDGET_DEPTH_MAX,
	    "the effect lists stay within their arrays");

	if (error != 0) {
		for (i = 0; i < CHAIN_DEPTH; i++)
			__CPROVER_assert(same_counters(&chain[i], &before[i]),
			    "a refused change leaves every level as it was");
		if (error == ERX_ENOMEM) {
			int r = level_of(effects.refused);

			__CPROVER_assert(r >= 0 && r <= start,
			    "the allocation failure names a level of the chain");
			__CPROVER_assert(r < 0 || !before[r].dead,
			    "the refusing level is live");
		}
		return;
	}

	__CPROVER_assert(effects.refused == NULL,
	    "an applied change names no refusal");

	/* The leaf takes exactly what the operation asked for. */
	__CPROVER_assert((__int128)chain[start].used - before[start].used ==
	    (op == 0 ? (__int128)pages : 0),
	    "the leaf's used changes by the charge");
	__CPROVER_assert((__int128)chain[start].carved - before[start].carved ==
	    (op == 2 ? (__int128)guarantee : 0),
	    "the leaf's carved changes by the carved guarantee");
	for (i = 0; i < CHAIN_DEPTH; i++)
		__CPROVER_assert((__int128)chain[i].pinned - before[i].pinned ==
		    (op == 1 ? (__int128)pin : 0), "a pin reaches every level");

	/*
	 * Every level above the leaf changes by exactly what its child passes
	 * up, computed here from the counters, whether or not the core went
	 * that far: lent by a live child's change of borrowing, used by a dead
	 * child's change of spending, and carved not at all.
	 */
	for (i = start; i > 0; i--) {
		__int128 lent_up = before[i].dead ? 0 :
		    borrowed(&chain[i]) - borrowed(&before[i]);
		__int128 used_up = before[i].dead ?
		    spent(&chain[i]) - spent(&before[i]) : 0;

		__CPROVER_assert((__int128)chain[i - 1].lent -
		    before[i - 1].lent == lent_up,
		    "a live level passes up its borrowing's change as lent");
		__CPROVER_assert((__int128)chain[i - 1].used -
		    before[i - 1].used == used_up,
		    "a dead level passes up its spending's change as used");
		__CPROVER_assert(chain[i - 1].carved == before[i - 1].carved,
		    "an ancestor's carved does not change");
	}
	for (i = 0; i < CHAIN_DEPTH; i++)
		__CPROVER_assert(chain[i].dead ||
		    spent(&chain[i]) <= spent(&before[i]) ||
		    spent(&chain[i]) <= (__int128)chain[i].cap,
		    "K3: no live level's spending rises beyond its cap");
}
