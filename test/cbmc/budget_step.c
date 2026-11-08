/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: budget_step (kernel/core/budget.c), the pure decision of
 * one level of a budget change, over every budget record, every change and
 * every dead rule. The expected answer is computed here in 128 bits from
 * the rule the core's header comment states, not from the core's helpers:
 *
 * - an accepted change gives each counter its exact new value, and the
 *   pin never falls;
 * - at a live level a rise of spending above the cap is refused (K3, "no
 *   budget's tree spends beyond its cap"), anything else passes up the
 *   change of borrowing, max(0, spending - guarantee), as lent;
 * - at a dead level the whole change of spending passes up as used, a
 *   rise refused where the level takes no charge;
 * - a refusal names a reason the inputs show.
 *
 * No loop, so no unwind bound. The one assumption keeps the dead rule
 * within its enumeration.
 */

#include "cbmc_harness.h"
#include "budget.c"

/* budget_step takes no lock; these satisfy the core's link. */
void
erx_effect_budget_lock(erx_budget_t *budget)
{
	(void)budget;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	(void)budget;
}

static __int128
exact_borrowing(__int128 spent, erx_npages_t guarantee)
{
	return (spent > (__int128)guarantee ? spent - guarantee : 0);
}

static bool
fits_u64(__int128 value)
{
	return (value >= 0 && value <= (__int128)UINT64_MAX);
}

/* A change the core passes up: a signed 64-bit value other than INT64_MIN. */
static bool
fits_change(__int128 value)
{
	return (value >= -(__int128)INT64_MAX && value <= INT64_MAX);
}

void
harness(void)
{
	erx_budget_t budget = {
		.guarantee = nondet_u64(),
		.cap = nondet_u64(),
		.used = nondet_u64(),
		.carved = nondet_u64(),
		.lent = nondet_u64(),
		.pinned = nondet_u64(),
		.threshold = nondet_u64(),
		.dead = nondet_bool(),
	};
	budget_delta_t delta = {
		.used = nondet_i64(),
		.carved = nondet_i64(),
		.lent = nondet_i64(),
		.pinned = nondet_i64(),
	};
	uint32_t rule = nondet_u32();
	budget_step_t step;
	__int128 used, carved, lent, pinned, old_spent, new_spent, lent_up;
	int error;

	__CPROVER_assume(rule <= BUDGET_DEAD_REFUSED);
	used = (__int128)budget.used + delta.used;
	carved = (__int128)budget.carved + delta.carved;
	lent = (__int128)budget.lent + delta.lent;
	pinned = (__int128)budget.pinned + delta.pinned;
	old_spent = (__int128)budget.used + budget.carved + budget.lent;
	new_spent = used + carved + lent;
	lent_up = exact_borrowing(new_spent, budget.guarantee) -
	    exact_borrowing(old_spent, budget.guarantee);

	error = budget_step(&budget, &delta, (budget_dead_rule_t)rule, &step);
	if (error == 0) {
		__CPROVER_assert(delta.pinned >= 0, "a pin never falls");
		__CPROVER_assert((__int128)step.used == used &&
		    (__int128)step.carved == carved &&
		    (__int128)step.lent == lent &&
		    (__int128)step.pinned == pinned,
		    "each counter takes its exact new value");
		__CPROVER_assert((__int128)step.old_spending == old_spent &&
		    (__int128)step.new_spending == new_spent,
		    "spending is used + carved + lent");
		__CPROVER_assert(step.up.pinned == delta.pinned &&
		    step.up.carved == 0, "a pin passes up unchanged");
		if (budget.dead) {
			__CPROVER_assert(rule != BUDGET_DEAD_REFUSED,
			    "a dead level is refused where the rule says so");
			__CPROVER_assert(rule != BUDGET_DEAD_TAKES_NO_RISE ||
			    new_spent <= old_spent, "a dead level takes no rise");
			__CPROVER_assert((__int128)step.up.used ==
			    new_spent - old_spent && step.up.lent == 0,
			    "a dead level passes its spending's change as used");
		} else {
			__CPROVER_assert(new_spent <= old_spent ||
			    new_spent <= (__int128)budget.cap,
			    "K3: no accepted rise spends beyond the cap");
			__CPROVER_assert(step.up.used == 0 &&
			    (__int128)step.up.lent == lent_up,
			    "a live level passes its borrowing's change as lent");
		}
	} else if (error == ERX_ENOMEM) {
		__CPROVER_assert(!budget.dead && new_spent > old_spent &&
		    new_spent > (__int128)budget.cap,
		    "ERX_ENOMEM only for a rise beyond the cap");
	} else if (error == ERX_ESTALE) {
		__CPROVER_assert(budget.dead && (rule == BUDGET_DEAD_REFUSED ||
		    (rule == BUDGET_DEAD_TAKES_NO_RISE && new_spent > old_spent)),
		    "ERX_ESTALE only for a dead level its rule refuses");
	} else {
		bool falling_pin = delta.pinned < 0;
		bool counter_out_of_range = !fits_u64(used) ||
		    !fits_u64(carved) || !fits_u64(lent) || !fits_u64(pinned) ||
		    !fits_u64(old_spent) || !fits_u64(new_spent);
		bool passed_up_out_of_range = budget.dead ?
		    !fits_change(new_spent - old_spent) : !fits_change(lent_up);

		__CPROVER_assert(error == ERX_EINVAL, "no other status");
		__CPROVER_assert(falling_pin || counter_out_of_range ||
		    passed_up_out_of_range,
		    "ERX_EINVAL only for a change out of range");
	}
}
