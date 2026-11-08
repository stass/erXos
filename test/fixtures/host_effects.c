/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects the object store and the budget core take from their host,
 * for a host test whose writer is one thread that never waits at a
 * preemption point: the thread's count of preemption points stays 0, and
 * a budget's lock has nothing to exclude. Tests that drive the epoch or the
 * locks (object_driver.c, budget_driver.c) define their own.
 */

#include <stdint.h>

#include "erx/budget.h"
#include "erx/object.h"

uint32_t
erx_effect_thread_epoch(void)
{
	return (0);
}

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
