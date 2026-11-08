/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Budgets as records on the service (budget.h). A budget's end is flat sweeps of the
 * object table, never a walk that recurses: a record is below a budget when the chain
 * of budgets it is charged to reaches that budget, and every budget on such a chain is
 * live, since a budget ends only after everything charged to it. The last sweeps take
 * the carved budgets nothing is charged to any more, leaves first, so the number of
 * sweeps is the depth of the budget tree, which the table bounds.
 *
 * A sweep survives the records an end takes with it, since each record is checked live
 * when the sweep reaches it, but not an end that comes back to a record already
 * ending. None does, because only the root holds a budget handle: a task's end, run
 * from inside a sweep, closes no budget's last handle and so starts no budget's end.
 * A call that passed budget handles to a task would have to keep that true, as a pass
 * of space handles would break task_stop_tree's walk.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/grow_table.h"
#include "liberx/backend/core/handles.h"
#include "liberx/backend/fiasco/budget.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"

/* What a budget record keeps besides its parent, which is its object record's budget. */
typedef struct budget_row {
	uint64_t	kind;		/* an erx_budget_kind_t */
	uint64_t	guarantee;	/* pages, as given */
	uint64_t	cap;		/* pages, as given */
} budget_row_t;

/* Which records one sweep of a budget's end takes, of those below the budget. */
typedef enum budget_sweep {
	BUDGET_SWEEP_SPACES,	/* spaces, so no task runs on while what it uses goes */
	BUDGET_SWEEP_OBJECTS,	/* every other object but a budget */
	BUDGET_SWEEP_LEAVES	/* carved budgets nothing is charged to */
} budget_sweep_t;

static budget_row_t	*budget_row_of(uint32_t);
static int	budget_fill(uint32_t, const void *);
static bool	budget_below(uint64_t, uint32_t);
static bool	budget_charged(uint32_t);
static bool	budget_takes(budget_sweep_t, uint32_t, const erx_backend_object_t *);
static bool	budget_sweep(uint32_t, budget_sweep_t);

/* Each budget record's row, by the record's index; pool memory, as every service table is. */
static erx_backend_grow_table_t budget_rows;

const char *
erx_fiasco_budget_init(void)
{
	erx_backend_grow_table_init(&budget_rows, sizeof(budget_row_t), &erx_fiasco_vm_records);
	/* The first page now, so a first carve takes no table page a page count would miss. */
	if (erx_backend_grow_table_room(&budget_rows, 1) != ERX_OK)
		return ("budgets: the pool cannot hold the budget records");
	return (NULL);
}

int
erx_fiasco_budget_named(uint32_t task, uint64_t handle, uint64_t *charged)
{
	uint32_t index;
	int status;

	if (handle == ERX_CAP_SELF || handle == ERX_CAP_NULL) {
		const uint32_t space = erx_fiasco_task(task)->tree.space;

		/* The root has no space record and is charged to its own budget; a live task always has one. */
		if (task == ERX_FIASCO_TASK_ROOT)
			*charged = ERX_BACKEND_BUDGET_ROOT;
		else if (space != 0)
			*charged = erx_fiasco_object_at(space - 1)->budget;
		else
			return (ERX_EINVAL);
		return (ERX_OK);
	}
	status = erx_fiasco_object_find(task, handle, ERX_BACKEND_OBJECT_BUDGET, &index);
	if (status == ERX_OK)
		*charged = index;
	return (status);
}

int
erx_fiasco_budget_create_body(uint32_t task, uint64_t parent, uint64_t kind, uint64_t guarantee, uint64_t cap,
    uint64_t *budget)
{
	const budget_row_t row = { .kind = kind, .guarantee = guarantee, .cap = cap };

	if (task != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	if (kind != ERX_BUDGET_WALL && kind != ERX_BUDGET_ELASTIC)
		return (ERX_EINVAL);
	/* The create's one path names parent as the budget the new record is charged to. */
	return (erx_fiasco_object_create(task, ERX_BACKEND_OBJECT_BUDGET, parent, budget_fill, &row, budget));
}

int
erx_fiasco_budget_resize_body(uint32_t task, uint64_t handle, uint64_t guarantee, uint64_t cap)
{
	uint32_t index;
	int status;

	if (task != ERX_FIASCO_TASK_ROOT || handle == ERX_CAP_SELF)
		return (ERX_ENOTSUP);
	status = erx_fiasco_object_find(task, handle, ERX_BACKEND_OBJECT_BUDGET, &index);
	if (status != ERX_OK)
		return (status);
	budget_row_of(index)->guarantee = guarantee;
	budget_row_of(index)->cap = cap;
	return (ERX_OK);
}

void
erx_fiasco_budget_end(uint32_t index)
{
	(void)budget_sweep(index, BUDGET_SWEEP_SPACES);
	(void)budget_sweep(index, BUDGET_SWEEP_OBJECTS);
	while (budget_sweep(index, BUDGET_SWEEP_LEAVES))
		continue;
}

static budget_row_t *
budget_row_of(uint32_t index)
{
	return (erx_backend_grow_table_at(&budget_rows, index));
}

static int
budget_fill(uint32_t index, const void *request)
{
	if (erx_backend_grow_table_room(&budget_rows, index + 1) != ERX_OK)
		return (ERX_ENOMEM);
	*budget_row_of(index) = *(const budget_row_t *)request;
	return (ERX_OK);
}

/*
 * Whether a record charged to the budget at index charged is below the budget being
 * ended: charged to it or to a budget carved from it. Each step goes up one parent; the table's size bounds the
 * steps, though the chain is shorter by construction.
 */
static bool
budget_below(uint64_t charged, uint32_t ending)
{
	for (uint32_t steps = erx_fiasco_object_capacity(); steps > 0 && charged != ERX_BACKEND_BUDGET_ROOT; steps--) {
		const erx_backend_object_t *record;

		if (charged == ending)
			return (true);
		record = charged < UINT32_MAX ? erx_fiasco_object_at((uint32_t)charged) : NULL;
		if (record == NULL || record->kind != ERX_BACKEND_OBJECT_BUDGET)
			return (false);
		charged = record->budget;
	}
	return (false);
}

/* Whether any live record is charged to the budget at index. */
static bool
budget_charged(uint32_t index)
{
	for (uint32_t other = 0; other < erx_fiasco_object_capacity(); other++) {
		const erx_backend_object_t *const record = erx_fiasco_object_at(other);

		if (erx_backend_object_live(record) && record->budget == index)
			return (true);
	}
	return (false);
}

static bool
budget_takes(budget_sweep_t sweep, uint32_t index, const erx_backend_object_t *record)
{
	switch (sweep) {
	case BUDGET_SWEEP_SPACES:
		return (record->kind == ERX_BACKEND_OBJECT_SPACE);
	case BUDGET_SWEEP_OBJECTS:
		return (record->kind != ERX_BACKEND_OBJECT_BUDGET);
	case BUDGET_SWEEP_LEAVES:
		return (record->kind == ERX_BACKEND_OBJECT_BUDGET && !budget_charged(index));
	}
	return (false);
}

/*
 * Ends every live record below the budget being ended that the sweep takes, and says whether it ended
 * any. Ending a space ends what its task created as well, at any index, so each record
 * is checked live when the sweep reaches it.
 */
static bool
budget_sweep(uint32_t ending, budget_sweep_t sweep)
{
	bool ended = false;

	for (uint32_t index = 0; index < erx_fiasco_object_capacity(); index++) {
		const erx_backend_object_t *const record = erx_fiasco_object_at(index);

		if (index == ending || !erx_backend_object_live(record) || !budget_below(record->budget, ending) ||
		    !budget_takes(sweep, index, record))
			continue;
		erx_fiasco_object_end(index);
		ended = true;
	}
	return (ended);
}
