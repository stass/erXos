/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_HANDLES_H
#define ERX_BACKEND_HANDLES_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/grow_table.h"

/*
 * Object records and handle tables (docs/design-stopgap.md, "Capabilities in Fiasco's
 * object space"). The service keeps one table of object records and one handle table
 * per task. A handle is an entry's index plus one, so 0 stays ERX_CAP_NULL. An entry
 * names a record and the generation the record had when the entry was made. A record's
 * generation grows each time the record is freed, and a record whose generation is at
 * its last value is retired instead, never to be taken again, so an entry whose object
 * has gone never names a successor: it answers ERX_ESTALE until it is closed. A handle
 * carries no rights.
 *
 * Every decision is here and every effect is the caller's: the core says which record
 * a create took, or that a close left a record with no handle and no mapping, and the
 * caller frees what the record's kind holds before it frees the record. The core takes
 * pages only through each table's source, so it builds for the host and its tests run
 * there.
 */

/* What a record is: free, retired, or the kind of object it holds. */
typedef enum erx_backend_object_kind {
	ERX_BACKEND_OBJECT_FREE = 0,
	ERX_BACKEND_OBJECT_RETIRED,
	ERX_BACKEND_OBJECT_MEMORY,
	ERX_BACKEND_OBJECT_GATE,
	ERX_BACKEND_OBJECT_SPACE
} erx_backend_object_kind_t;

/* For erx_backend_handle_find: any live kind will do. */
#define ERX_BACKEND_OBJECT_ANY	UINT32_MAX

typedef struct erx_backend_object {
	uint32_t	kind;		/* erx_backend_object_kind_t */
	uint32_t	creator;	/* the task that made it, the one whose destroy is honoured */
	uint64_t	budget;		/* the budget its create named, recorded only */
	uint32_t	generation;
	uint32_t	handles;	/* entries in any table naming this record at this generation */
	uint32_t	mappings;	/* maps made of it, which keep it while it has no handle */
	uint32_t	reserved;
} erx_backend_object_t;

typedef struct erx_backend_handle_entry {
	uint32_t	object;		/* the record's index plus one, or 0 for a free entry */
	uint32_t	generation;	/* the record's generation when the entry was made */
} erx_backend_handle_entry_t;

typedef struct erx_backend_handles {
	erx_backend_grow_table_t entries;	/* erx_backend_handle_entry_t */
	uint32_t	limit;			/* the most entries, the cap_limit its space was made with */
} erx_backend_handles_t;

/* The object records, empty, whose pages come from source. */
void	erx_backend_objects_init(erx_backend_grow_table_t *objects, const erx_backend_grow_pages_t *source);

/* The record at index, or NULL past the table. */
erx_backend_object_t	*erx_backend_object_at(const erx_backend_grow_table_t *objects, uint32_t index);

/*
 * Takes the lowest free record for an object of this kind and creator, with no handle
 * and no mapping. ERX_ENOMEM when the table cannot grow.
 */
int	erx_backend_object_take(erx_backend_grow_table_t *objects, uint32_t kind, uint32_t creator, uint64_t budget,
	    uint32_t *index) ERX_WARN_UNUSED_RESULT;

/*
 * Frees a live record: every entry naming it is stale from now on. A record at its
 * last generation is retired and never taken again.
 */
void	erx_backend_object_free(erx_backend_grow_table_t *objects, uint32_t index);

/*
 * Returns a record no entry has ever named, as a create that failed leaves it, to free
 * at the generation it had, so a record that never held an object stays at generation 0.
 */
void	erx_backend_object_unmake(erx_backend_grow_table_t *objects, uint32_t index);

/* Whether a record holds an object: neither free nor retired. */
bool	erx_backend_object_live(const erx_backend_object_t *);

/* Whether a live record has neither a handle nor a mapping, and so is to be freed. */
bool	erx_backend_object_unreferenced(const erx_backend_object_t *);

/*
 * An empty handle table of at most limit entries; a table holds no more than its
 * grow table's limit either, whatever limit says.
 */
void	erx_backend_handles_init(erx_backend_handles_t *, uint32_t limit, const erx_backend_grow_pages_t *source);

/* One past the largest handle the table has room for: handles 1 to this, exclusive, may name entries. */
uint64_t	erx_backend_handles_end(const erx_backend_handles_t *);

/*
 * Adds an entry naming the live record at index, in the lowest free entry, and counts
 * it in the record. ERX_ELIMIT when every entry up to the limit is in use; ERX_ENOMEM
 * when the table cannot grow to the next one.
 */
int	erx_backend_handle_add(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint32_t index,
	    uint64_t *handle) ERX_WARN_UNUSED_RESULT;

/*
 * The record a handle names, which must be of kind, or of any live kind for
 * ERX_BACKEND_OBJECT_ANY. ERX_EINVAL for a value that is no entry in use; ERX_ESTALE
 * when the object it named has gone; ERX_ETYPE for a live object of another kind.
 */
int	erx_backend_handle_find(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *, uint64_t handle,
	    uint32_t kind, uint32_t *index) ERX_WARN_UNUSED_RESULT;

/* Adds a second entry naming what handle names: erx_backend_handle_find's refusals, then erx_backend_handle_add's. */
int	erx_backend_handle_dup(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint64_t handle,
	    uint64_t *copy) ERX_WARN_UNUSED_RESULT;

/*
 * Frees handle's entry. ERX_EINVAL for a value that is no entry in use. A stale entry
 * is freed too, since nothing else ever would. *freed is set to whether the entry was
 * the last reference to a live record, which the caller then frees. *index is set to
 * the record whenever the entry named a live one, and left alone for a stale entry.
 */
int	erx_backend_handle_close(erx_backend_grow_table_t *objects, erx_backend_handles_t *, uint64_t handle,
	    bool *freed, uint32_t *index) ERX_WARN_UNUSED_RESULT;

/* Gives the table's pages back; its entries must all have been closed. */
void	erx_backend_handles_clear(erx_backend_handles_t *);

#endif /* ERX_BACKEND_HANDLES_H */
