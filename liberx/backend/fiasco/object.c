/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects around handles.c: which table is a task's, and what ending an object
 * of each kind gives back. Every decision about records, generations and entries is
 * the core's.
 *
 * Each task's range table keeps its mapping records (vm.c); a record here counts them,
 * so an object with no handle lives while a mapping does. An object that goes while
 * mapped, by its creator's destroy or its creator's end, is revoked first: every
 * mapping of it, in every task, goes at once.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/budget.h"
#include "liberx/backend/fiasco/fault_gate.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"

static erx_backend_handles_t *object_handles_of(uint32_t);
static void	object_release(uint32_t);

/* Every object record, by index. */
static erx_backend_grow_table_t object_records;
/* Each task's handle table, by the task's index. */
static erx_backend_grow_table_t object_tables;

const char *
erx_fiasco_object_init(void)
{
	erx_backend_objects_init(&object_records, &erx_fiasco_vm_records);
	erx_backend_grow_table_init(&object_tables, sizeof(erx_backend_handles_t), &erx_fiasco_vm_records);
	/* The first page now, so a task's first create takes no table page a page count would miss. */
	if (erx_backend_grow_table_room(&object_records, 1) != ERX_OK)
		return ("objects: the pool cannot hold the object records");
	/*
	 * The root's table is bounded by the pool alone, which its grow table's limit stands
	 * for; its first page now too, for the same reason as the records'.
	 */
	if (erx_fiasco_object_task_open(ERX_FIASCO_TASK_ROOT, UINT32_MAX) != ERX_OK ||
	    erx_backend_grow_table_room(&object_handles_of(ERX_FIASCO_TASK_ROOT)->entries, 1) != ERX_OK)
		return ("objects: the pool cannot hold the root's handle table");
	return (NULL);
}

int
erx_fiasco_object_task_open(uint32_t task, uint32_t cap_limit)
{
	if (task == UINT32_MAX || erx_backend_grow_table_room(&object_tables, task + 1) != ERX_OK)
		return (ERX_ENOMEM);
	erx_backend_handles_init(object_handles_of(task), cap_limit, &erx_fiasco_vm_records);
	return (ERX_OK);
}

void
erx_fiasco_object_task_close(uint32_t task)
{
	erx_backend_handles_t *const handles = object_handles_of(task);
	const uint64_t end = erx_backend_handles_end(handles);
	uint32_t index;
	bool freed;

	for (uint64_t handle = 1; handle < end; handle++)
		if (erx_backend_handle_close(&object_records, handles, handle, &freed, &index) == ERX_OK && freed)
			erx_fiasco_object_end(index);
	erx_backend_handles_clear(handles);
	for (index = 0; index < erx_backend_grow_table_capacity(&object_records); index++) {
		const erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

		if (erx_backend_object_live(record) && record->creator == task)
			erx_fiasco_object_end(index);
	}
}

int
erx_fiasco_object_create(uint32_t task, uint32_t kind, uint64_t budget, erx_fiasco_object_fill_t fill, const void *request,
    uint64_t *handle)
{
	uint64_t charged;
	uint32_t index;
	int status = erx_fiasco_budget_named(task, budget, &charged);

	if (status != ERX_OK)
		return (status);
	status = erx_backend_object_take(&object_records, kind, task, charged, &index);
	if (status != ERX_OK)
		return (status);
	status = fill(index, request);
	if (status == ERX_OK) {
		status = erx_backend_handle_add(&object_records, object_handles_of(task), index, handle);
		if (status != ERX_OK)
			object_release(index);
	}
	/* No entry ever named the record, so it goes back at the generation it had. */
	if (status != ERX_OK)
		erx_backend_object_unmake(&object_records, index);
	return (status);
}

const erx_backend_object_t *
erx_fiasco_object_at(uint32_t index)
{
	return (erx_backend_object_at(&object_records, index));
}

uint32_t
erx_fiasco_object_capacity(void)
{
	return (erx_backend_grow_table_capacity(&object_records));
}

int
erx_fiasco_object_find(uint32_t task, uint64_t handle, uint32_t kind, uint32_t *index)
{
	return (erx_backend_handle_find(&object_records, object_handles_of(task), handle, kind, index));
}

void
erx_fiasco_object_mapped(uint32_t index)
{
	erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

	record->mappings++;
}

void
erx_fiasco_object_unmapped(uint32_t index)
{
	erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

	record->mappings--;
	if (erx_backend_object_unreferenced(record))
		erx_fiasco_object_end(index);
}

int
erx_fiasco_cap_dup_body(uint32_t task, uint64_t handle, uint64_t *copy)
{
	return (erx_backend_handle_dup(&object_records, object_handles_of(task), handle, copy));
}

int
erx_fiasco_cap_close_body(uint32_t task, uint64_t handle)
{
	uint32_t index;
	bool freed;
	const int status = erx_backend_handle_close(&object_records, object_handles_of(task), handle, &freed, &index);

	if (status == ERX_OK && freed)
		erx_fiasco_object_end(index);
	return (status);
}

/* No pass conveys the delete right, so only the creator's task destroys. */
int
erx_fiasco_object_destroy_body(uint32_t task, uint64_t handle)
{
	uint32_t index;
	const int status = erx_fiasco_object_find(task, handle, ERX_BACKEND_OBJECT_ANY, &index);
	const erx_backend_object_t *record;

	if (status != ERX_OK)
		return (status);
	record = erx_backend_object_at(&object_records, index);
	if (record->creator != task)
		return (ERX_ERIGHTS);
	erx_fiasco_object_end(index);
	return (ERX_OK);
}

static erx_backend_handles_t *
object_handles_of(uint32_t task)
{
	return (erx_backend_grow_table_at(&object_tables, task));
}

/* Gives back what a live record's object holds; every kind has its case, so a new one is a build warning here. */
static void
object_release(uint32_t index)
{
	switch ((erx_backend_object_kind_t)erx_backend_object_at(&object_records, index)->kind) {
	case ERX_BACKEND_OBJECT_MEMORY:
		erx_fiasco_vm_object_free(index);
		break;
	case ERX_BACKEND_OBJECT_GATE:
		erx_fiasco_gate_free(index);
		break;
	case ERX_BACKEND_OBJECT_SPACE:
		erx_fiasco_task_space_release(index);
		break;
	case ERX_BACKEND_OBJECT_BUDGET:
		erx_fiasco_budget_end(index);
		break;
	case ERX_BACKEND_OBJECT_FREE:
	case ERX_BACKEND_OBJECT_RETIRED:
		break;
	}
}

void
erx_fiasco_object_end(uint32_t index)
{
	erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

	if (record->mappings != 0) {
		erx_fiasco_vm_object_revoke(index);
		record->mappings = 0;
	}
	object_release(index);
	erx_backend_object_free(&object_records, index);
}

#ifdef ERX_FIASCO_TEST_HOOKS
void
erx_fiasco_test_object_age(void)
{
	for (uint32_t index = 0; index < erx_backend_grow_table_capacity(&object_records); index++) {
		erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

		if (record->kind == ERX_BACKEND_OBJECT_FREE) {
			record->generation = UINT32_MAX;
			return;
		}
	}
}
#endif
