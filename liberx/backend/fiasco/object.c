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
 *
 * No budget or space ends inside a task's end. The close of a task's handle table
 * ends nothing: it marks the records it frees and those the task created, and the
 * service ends the marked records once the request or fault that ended the task is
 * over, before it answers (erx_fiasco_object_drain). The task's end still ends memory
 * whose last mapping it drops and its home group, neither of which stops a task. A
 * task can hold the last handle of a budget, its own space's included, and a budget's
 * end stops and deletes the spaces below it: inside the task's end it would reach the
 * task's own space while its row is live, and spaces on a stop walk's path. After it,
 * every space it reaches is either live, with no end under way, or ended with its row
 * reset.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/budget.h"
#include "liberx/backend/fiasco/fault_gate.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

static erx_backend_handles_t *object_handles_of(uint32_t);
static int	object_pass_item(uint32_t, uint32_t, erx_msg_item_t *);
static int	object_pass_type(uint32_t, erx_ktype_t *);
static void	object_later(uint32_t);
static void	object_release(uint32_t);
static void	object_unheld(uint32_t);

/* Every object record, by index. */
static erx_backend_grow_table_t object_records;
/* The record erx_fiasco_object_keep keeps, or UINT32_MAX before it runs. */
static uint32_t object_kept = UINT32_MAX;
/* Each task's handle table, by the task's index. */
static erx_backend_grow_table_t object_tables;
/* Whether a record may be marked to end, so the drain has work. */
static bool object_marked;

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
			object_later(index);
	erx_backend_handles_clear(handles);
	for (index = 0; index < erx_backend_grow_table_capacity(&object_records); index++) {
		const erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

		if (erx_backend_object_live(record) && record->creator == task)
			object_later(index);
	}
}

/*
 * Ends every marked record. An end here can stop and delete spaces, whose tasks' ends
 * mark more records, so the drain sweeps again until a sweep starts from no mark; each
 * task ends once, so the sweeps are bounded. A sweep's own end may take a marked record
 * first, and a freed record carries no mark. A group still marked when its home has
 * threads goes with that home, as at a last close (object_unheld).
 */
void
erx_fiasco_object_drain(void)
{
	while (object_marked) {
		object_marked = false;
		for (uint32_t index = 0; index < erx_backend_grow_table_capacity(&object_records); index++) {
			erx_backend_object_t *const record = erx_backend_object_at(&object_records, index);

			if (!erx_backend_object_live(record) || record->ending == 0)
				continue;
			record->ending = 0;
			object_unheld(index);
		}
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

uint32_t
erx_fiasco_object_handles_used(uint32_t task)
{
	const erx_backend_handles_t *const handles = object_handles_of(task);
	const erx_backend_handle_entry_t *entry;
	uint32_t used = 0;

	for (uint32_t index = 0; handles != NULL && index < erx_backend_grow_table_capacity(&handles->entries); index++) {
		entry = erx_backend_grow_table_at(&handles->entries, index);
		used += entry != NULL && entry->object != 0;
	}
	return (used);
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
erx_fiasco_object_keep(uint32_t index)
{
	erx_fiasco_object_mapped(index);
	object_kept = index;
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
		object_unheld(index);
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
	if (record->creator != task || index == object_kept)
		return (ERX_ERIGHTS);
	/* A group never goes before its threads, which end only by their own exit or with their task. */
	if (record->kind == ERX_BACKEND_OBJECT_GROUP && erx_fiasco_group_home_has_threads(index))
		return (ERX_ENOTSUP);
	erx_fiasco_object_end(index);
	return (ERX_OK);
}

static void
object_later(uint32_t index)
{
	erx_backend_object_at(&object_records, index)->ending = 1;
	object_marked = true;
}

/*
 * A record whose last handle went and that has no mapping ends, but for a group whose
 * home has threads: its home holds it, and it goes with that home (service_task.c), so a
 * group never goes before its threads.
 */
static void
object_unheld(uint32_t index)
{
	if (erx_backend_object_at(&object_records, index)->kind == ERX_BACKEND_OBJECT_GROUP &&
	    erx_fiasco_group_home_has_threads(index))
		return;
	erx_fiasco_object_end(index);
}

/*
 * The items are copied out of the caller's public UTCB once, since its task can write
 * them while the service reads, and each is checked and passed from that copy before
 * its result is written back.
 */
int
erx_fiasco_cap_pass_body(uint32_t task, uint32_t caller, const erx_fiasco_cap_pass_request_t *request)
{
	erx_fiasco_thread_record_t *const thread = erx_fiasco_task_record(task, caller);
	erx_msg_item_t items[ERX_MSG_CAPS];
	uint32_t target;
	int status;

	if (task != ERX_FIASCO_TASK_ROOT || request->from != ERX_CAP_SELF || request->to == ERX_CAP_SELF)
		return (ERX_ENOTSUP);
	if (thread == NULL || request->count > ERX_MSG_CAPS)
		return (ERX_EINVAL);
	status = erx_fiasco_task_space_target(task, request->to, &target);
	if (status != ERX_OK)
		return (status);
	for (size_t at = 0; at < request->count; at++) {
		(void)erx_utcb_mr_load(&thread->utcb, 2 * at, &items[at].desc);
		(void)erx_utcb_mr_load(&thread->utcb, 2 * at + 1, &items[at].cap.raw);
	}
	for (size_t at = 0; at < request->count; at++) {
		status = object_pass_item(task, target, &items[at]);
		if (status != ERX_OK)
			return (status);
		(void)erx_utcb_mr_store(&thread->utcb, 2 * at, items[at].desc);
		(void)erx_utcb_mr_store(&thread->utcb, 2 * at + 1, items[at].cap.raw);
	}
	return (ERX_OK);
}

/*
 * One item, one of from's handles with its descriptor, passed into to's table and
 * rewritten as its result: a copy adds an entry naming the same record, and a move
 * then closes from's entry. The rights reported are the mask's within the type's, less
 * DESTROY, since only an object's creator destroys it; no entry records them. A sent
 * item that names the type its handle must have is a checked pass, which nothing here
 * offers.
 */
static int
object_pass_item(uint32_t from, uint32_t to, erx_msg_item_t *item)
{
	const uint32_t mask = (uint32_t)erx_msg_item_desc_rights_get(item->desc);
	const uint64_t move = erx_msg_item_desc_move_get(item->desc);
	uint64_t sent = 0, value = ERX_CAP_NULL;
	uint32_t index, closed;
	erx_ktype_t type = 0;
	bool freed;
	int status;

	(void)erx_msg_item_desc_rights_set(&sent, mask);
	(void)erx_msg_item_desc_move_set(&sent, move);
	(void)erx_msg_item_desc_type_set(&sent, erx_msg_item_desc_type_get(item->desc));
	if (sent != item->desc)
		return (ERX_EINVAL);
	if (erx_msg_item_desc_type_get(item->desc) != 0)
		return (ERX_ENOTSUP);
	status = erx_fiasco_object_find(from, item->cap.raw, ERX_BACKEND_OBJECT_ANY, &index);
	if (status == ERX_OK)
		status = object_pass_type(erx_backend_object_at(&object_records, index)->kind, &type);
	if (status == ERX_OK)
		status = erx_backend_handle_add(&object_records, object_handles_of(to), index, &value);
	if (status != ERX_OK)
		return (status);
	/*
	 * A move's close cannot fail and never frees the record: the find above took this
	 * entry, one service thread runs every request, and to's new entry names the record.
	 */
	if (move != 0)
		(void)erx_backend_handle_close(&object_records, object_handles_of(from), item->cap.raw, &freed, &closed);
	item->desc = 0;
	(void)erx_msg_item_desc_type_set(&item->desc, type);
	(void)erx_msg_item_desc_rights_set(&item->desc, mask & erx_ktype_rights_mask(type) & ~ERX_HR_DESTROY);
	item->cap.raw = value;
	return (ERX_OK);
}

/*
 * The type a passed handle of a record's kind reports: a memory object's; an IRQ
 * object's, which its holder triggers and acks; and a budget's and a group's, for the
 * domain library's install. A task that holds a budget's last handle ends it after its
 * own end, by the drain. A space's or a gate's handle never passes, so that handles flow
 * down from an object's creator. Every kind has its case, so a new one is a build
 * warning here.
 */
static int
object_pass_type(uint32_t kind, erx_ktype_t *type)
{
	switch ((erx_backend_object_kind_t)kind) {
	case ERX_BACKEND_OBJECT_MEMORY:
		*type = ERX_K_MEMORY;
		return (ERX_OK);
	case ERX_BACKEND_OBJECT_IRQ:
		*type = ERX_K_IRQ;
		return (ERX_OK);
	case ERX_BACKEND_OBJECT_BUDGET:
		*type = ERX_K_BUDGET;
		return (ERX_OK);
	case ERX_BACKEND_OBJECT_GROUP:
		*type = ERX_K_GROUP;
		return (ERX_OK);
	case ERX_BACKEND_OBJECT_GATE:
	case ERX_BACKEND_OBJECT_SPACE:
	case ERX_BACKEND_OBJECT_FREE:
	case ERX_BACKEND_OBJECT_RETIRED:
		break;
	}
	return (ERX_ENOTSUP);
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
	case ERX_BACKEND_OBJECT_GROUP:
		erx_fiasco_group_free(index);
		break;
	case ERX_BACKEND_OBJECT_SPACE:
		erx_fiasco_task_space_release(index);
		break;
	case ERX_BACKEND_OBJECT_BUDGET:
		erx_fiasco_budget_end(index);
		break;
	case ERX_BACKEND_OBJECT_IRQ:
		erx_fiasco_irq_free(index);
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
