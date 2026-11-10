/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Object records and handle tables: see handles.h. Both are grow tables, so a record
 * or an entry never moves and every reference is an index. Both searches are linear,
 * lowest first, which keeps reuse predictable for the tests and costs a stopgap
 * nothing that matters.
 */

#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/core/handles.h"

static erx_backend_handle_entry_t *entry_slot(const erx_backend_handles_t *, uint32_t);
static erx_backend_handle_entry_t *entry_at(const erx_backend_handles_t *, uint64_t);
static uint32_t	entries_usable(const erx_backend_handles_t *);
static bool	entry_live(const erx_backend_grow_table_t *, const erx_backend_handle_entry_t *);

void
erx_backend_objects_init(erx_backend_grow_table_t *objects, const erx_backend_grow_pages_t *source)
{
	erx_backend_grow_table_init(objects, sizeof(erx_backend_object_t), source);
}

erx_backend_object_t *
erx_backend_object_at(const erx_backend_grow_table_t *objects, uint32_t index)
{
	return (erx_backend_grow_table_at(objects, index));
}

int
erx_backend_object_take(erx_backend_grow_table_t *objects, uint32_t kind, uint32_t creator, uint64_t budget,
    uint32_t *index)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(objects);
	uint32_t found = 0;
	erx_backend_object_t *record;

	while (found < capacity && erx_backend_object_at(objects, found)->kind != ERX_BACKEND_OBJECT_FREE)
		found++;
	/* A record a grow adds reads zero: free, at generation 0. */
	if (found == capacity && (capacity == UINT32_MAX || erx_backend_grow_table_room(objects, capacity + 1) != ERX_OK))
		return (ERX_ENOMEM);
	record = erx_backend_object_at(objects, found);
	record->kind = kind;
	record->creator = creator;
	record->budget = budget;
	record->handles = 0;
	record->mappings = 0;
	record->ending = 0;
	record->kept = 0;
	*index = found;
	return (ERX_OK);
}

void
erx_backend_object_free(erx_backend_grow_table_t *objects, uint32_t index)
{
	erx_backend_object_t *const record = erx_backend_object_at(objects, index);

	record->handles = 0;
	record->mappings = 0;
	record->ending = 0;
	record->kept = 0;
	if (record->generation == UINT32_MAX) {
		record->kind = ERX_BACKEND_OBJECT_RETIRED;
		return;
	}
	record->generation++;
	record->kind = ERX_BACKEND_OBJECT_FREE;
}

void
erx_backend_object_unmake(erx_backend_grow_table_t *objects, uint32_t index)
{
	erx_backend_object_at(objects, index)->kind = ERX_BACKEND_OBJECT_FREE;
}

bool
erx_backend_object_live(const erx_backend_object_t *record)
{
	return (record->kind != ERX_BACKEND_OBJECT_FREE && record->kind != ERX_BACKEND_OBJECT_RETIRED);
}

bool
erx_backend_object_unreferenced(const erx_backend_object_t *record)
{
	return (record->handles == 0 && record->mappings == 0 && record->kept == 0);
}

void
erx_backend_handles_init(erx_backend_handles_t *handles, uint32_t limit, const erx_backend_grow_pages_t *source)
{
	erx_backend_grow_table_init(&handles->entries, sizeof(erx_backend_handle_entry_t), source);
	handles->limit = limit;
}

uint64_t
erx_backend_handles_end(const erx_backend_handles_t *handles)
{
	return ((uint64_t)entries_usable(handles) + 1);
}

int
erx_backend_handle_add(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint32_t index,
    uint64_t *handle)
{
	erx_backend_object_t *const record = erx_backend_object_at(objects, index);
	uint32_t usable = entries_usable(handles);
	uint32_t found = 0;
	erx_backend_handle_entry_t *entry;

	while (found < usable && entry_slot(handles, found)->object != 0)
		found++;
	if (found == usable) {
		if (usable >= handles->limit)
			return (ERX_ELIMIT);
		/* A grow adds a whole page, whose entries past the limit stay unused. */
		if (erx_backend_grow_table_room(&handles->entries, usable + 1) != ERX_OK)
			return (ERX_ENOMEM);
	}
	entry = entry_slot(handles, found);
	entry->object = index + 1;
	entry->generation = record->generation;
	record->handles++;
	*handle = (uint64_t)found + 1;
	return (ERX_OK);
}

int
erx_backend_handle_find(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, uint64_t handle,
    uint32_t kind, uint32_t *index)
{
	const erx_backend_handle_entry_t *const entry = entry_at(handles, handle);
	const erx_backend_object_t *record;

	if (entry == NULL)
		return (ERX_EINVAL);
	if (!entry_live(objects, entry))
		return (ERX_ESTALE);
	record = erx_backend_object_at(objects, entry->object - 1);
	if (kind != ERX_BACKEND_OBJECT_ANY && record->kind != kind)
		return (ERX_ETYPE);
	*index = entry->object - 1;
	return (ERX_OK);
}

int
erx_backend_handle_dup(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint64_t handle,
    uint64_t *copy)
{
	uint32_t index;
	const int status = erx_backend_handle_find(objects, handles, handle, ERX_BACKEND_OBJECT_ANY, &index);

	if (status != ERX_OK)
		return (status);
	return (erx_backend_handle_add(objects, handles, index, copy));
}

int
erx_backend_handle_close(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, uint64_t handle,
    bool *freed, uint32_t *index)
{
	erx_backend_handle_entry_t *const entry = entry_at(handles, handle);
	erx_backend_object_t *record;

	if (entry == NULL)
		return (ERX_EINVAL);
	*freed = false;
	if (entry_live(objects, entry)) {
		record = erx_backend_object_at(objects, entry->object - 1);
		record->handles--;
		*freed = erx_backend_object_unreferenced(record);
		*index = entry->object - 1;
	}
	*entry = (erx_backend_handle_entry_t){ 0 };
	return (ERX_OK);
}

void
erx_backend_handles_clear(erx_backend_handles_t *handles)
{
	erx_backend_grow_table_clear(&handles->entries);
}

/* How many entries may be used: those the table has pages for, up to its limit. */
static uint32_t
entries_usable(const erx_backend_handles_t *handles)
{
	const uint32_t capacity = erx_backend_grow_table_capacity(&handles->entries);

	return (capacity < handles->limit ? capacity : handles->limit);
}

/* The entry at an index below the capacity, free or in use. */
static erx_backend_handle_entry_t *
entry_slot(const erx_backend_handles_t *handles, uint32_t slot)
{
	return (erx_backend_grow_table_at(&handles->entries, slot));
}

/* The entry in use that handle names, or NULL. */
static erx_backend_handle_entry_t *
entry_at(const erx_backend_handles_t *handles, uint64_t handle)
{
	erx_backend_handle_entry_t *entry;

	if (handle == 0 || handle > entries_usable(handles))
		return (NULL);
	entry = entry_slot(handles, (uint32_t)(handle - 1));
	return (entry->object != 0 ? entry : NULL);
}

/* Whether the record an entry in use names is still the object the entry was made for. */
static bool
entry_live(const erx_backend_grow_table_t *objects, const erx_backend_handle_entry_t *entry)
{
	const erx_backend_object_t *const record = erx_backend_object_at(objects, entry->object - 1);

	return (record != NULL && erx_backend_object_live(record) && record->generation == entry->generation);
}
