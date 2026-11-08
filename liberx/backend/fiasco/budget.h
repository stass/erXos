/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_BUDGET_H
#define ERX_FIASCO_BUDGET_H

#include <stdint.h>

#include "erx/cdefs.h"

/*
 * Budgets as records (docs/design-stopgap.md, "Budgets and groups as records"). A
 * budget is an object record of kind budget, and like every object record it names
 * the budget it is charged to, which for a budget is its parent. Its kind, guarantee
 * and cap are kept here by the record's index, as given: nothing reads them back, so
 * no create, commit or carve is refused for them. The root's own budget has no record,
 * since only the machine's end ends it; a record charged to it names
 * ERX_BACKEND_BUDGET_ROOT.
 *
 * The one property kept is that an object goes with its budget: a budget's end, at
 * its destroy, at its last handle's close or as a step of an outer budget's end, ends
 * everything charged to it or to a budget carved from it. Only the root carves and
 * resizes, so every budget record is the root's and no task's end ends one.
 * Only the service thread calls these.
 */

/* The budget rows, empty but for their first page. NULL or why not. */
const char	*erx_fiasco_budget_init(void);

/*
 * The budget a create of task's charges, from the create's budget argument:
 * ERX_CAP_SELF, or ERX_CAP_NULL, which callers still pass, is the budget task's own
 * space is charged to (the root's, for the root); any other value is a handle of
 * task's naming a budget, else erx_backend_handle_find's refusal. *charged is a budget
 * record's index or ERX_BACKEND_BUDGET_ROOT.
 */
int	erx_fiasco_budget_named(uint32_t task, uint64_t handle, uint64_t *charged) ERX_WARN_UNUSED_RESULT;

/*
 * erx_budget_create's body: a record under parent, one of the root's budgets, with the
 * three values recorded. A kind other than wall or elastic is ERX_EINVAL; a task other
 * than the root ERX_ENOTSUP.
 */
int	erx_fiasco_budget_create_body(uint32_t task, uint64_t parent, uint64_t kind, uint64_t guarantee, uint64_t cap,
	    uint64_t *budget) ERX_WARN_UNUSED_RESULT;

/*
 * erx_budget_resize's body: records the two values for a budget handle of the root's;
 * the root's own budget, which nothing resizes, and a task's call are ERX_ENOTSUP.
 */
int	erx_fiasco_budget_resize_body(uint32_t task, uint64_t handle, uint64_t guarantee, uint64_t cap)
	    ERX_WARN_UNUSED_RESULT;

/*
 * A budget's end, before its record is freed: ends every space charged to it or to a
 * budget carved from it, then every other such object, then the carved budgets,
 * leaves first.
 */
void	erx_fiasco_budget_end(uint32_t index);

#endif /* ERX_FIASCO_BUDGET_H */
