/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_OBJECT_H
#define ERX_FIASCO_OBJECT_H

#include <stdint.h>

#include "erx/cdefs.h"
#include "liberx/backend/core/handles.h"

/*
 * The service's object records and each task's handle table (docs/design-stopgap.md,
 * "Capabilities in Fiasco's object space"), over the core in handles.c. Only the
 * service thread calls these. A memory object's pages are vm.c's, a gate's queue
 * fault_gate.c's, a space's task service_task.c's and a budget's values budget.c's,
 * each kept by the record's index. A record goes at its creator's destroy, at its
 * creator's end, once it has neither a handle nor a mapping, or with its budget; a
 * space's record goes at the space's deletion too.
 */

/* The record table and the root's handle table, which only the pool bounds. NULL or why not. */
const char	*erx_fiasco_object_init(void);

/* An empty handle table of cap_limit entries for a task about to be made. ERX_ENOMEM when the pool cannot hold it. */
int	erx_fiasco_object_task_open(uint32_t task, uint32_t cap_limit) ERX_WARN_UNUSED_RESULT;

/*
 * A task's end, once its space is gone: closes every handle it held, and ends every
 * object it created, wherever handles to them remain, which then answer ERX_ESTALE.
 */
void	erx_fiasco_object_task_close(uint32_t task);

/*
 * Makes what an object of a kind holds, for the record at index, from a create's
 * request; on failure it holds nothing.
 */
typedef int	(*erx_fiasco_object_fill_t)(uint32_t index, const void *request);

/*
 * Every create's one path: charges the record to the budget a budget argument of
 * task's names (erx_fiasco_budget_named, whose refusal it returns), takes a record,
 * fills it, and gives task a handle to it.
 * A full record table, or a full handle table (ERX_ELIMIT) or one that cannot grow
 * (ERX_ENOMEM), or the fill's own refusal leaves nothing of the object and the record
 * at the generation it had.
 */
int	erx_fiasco_object_create(uint32_t task, uint32_t kind, uint64_t budget, erx_fiasco_object_fill_t fill,
	    const void *request, uint64_t *handle) ERX_WARN_UNUSED_RESULT;

/* The record at index, or NULL past the table; and one past the last index, for budget.c's sweeps. */
const erx_backend_object_t	*erx_fiasco_object_at(uint32_t index);
uint32_t	erx_fiasco_object_capacity(void);

/* The record a task's handle names, of this kind: erx_backend_handle_find's refusals. */
int	erx_fiasco_object_find(uint32_t task, uint64_t handle, uint32_t kind, uint32_t *index) ERX_WARN_UNUSED_RESULT;

/*
 * An object's end: its mappings go from every space, what it holds goes, then its
 * record, leaving every entry naming it stale.
 */
void	erx_fiasco_object_end(uint32_t index);

/* Counts a map of the object at index, which keeps it while it has no handle. */
void	erx_fiasco_object_mapped(uint32_t index);
/* Counts a mapping of it gone; the object goes once it has neither a handle nor a mapping. */
void	erx_fiasco_object_unmapped(uint32_t index);

/* The bodies of erx_cap_dup, erx_cap_close and erx_object_destroy for the calling task. */
int	erx_fiasco_cap_dup_body(uint32_t task, uint64_t handle, uint64_t *copy) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_cap_close_body(uint32_t task, uint64_t handle) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_object_destroy_body(uint32_t task, uint64_t handle) ERX_WARN_UNUSED_RESULT;

#ifdef ERX_FIASCO_TEST_HOOKS
/*
 * Sets the lowest free record's generation to its last value, so the next object
 * made there retires its record when it goes. Call it only while no request runs: the
 * IPC of the caller's next request orders this write before the service reads it.
 */
void	erx_fiasco_test_object_age(void);
#endif

#endif /* ERX_FIASCO_OBJECT_H */
