/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_GROW_TABLE_H
#define ERX_BACKEND_GROW_TABLE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * A table of fixed-size records in pages (docs/design-stopgap.md, "Table sizes"):
 * a directory page holds the addresses of the record pages, and a table that fills
 * takes one more page. A record never moves, since its page stays where it was
 * taken, so a caller names records by index and may hold a pointer to one only until
 * the table is cleared. Records past the table's capacity do not exist; every
 * record a grow adds reads zero.
 *
 * The core takes and gives pages only through the source the table was made with, and
 * reads no other state, so it builds for the host and its tests run there.
 */

/* How many record pages one directory page names. */
#define ERX_BACKEND_GROW_PAGES_MAX	((uint32_t)(ERX_PAGE_SIZE / sizeof(uintptr_t)))

/* Where a table's pages come from: the Fiasco backend's pool, or a host test's. */
typedef struct erx_backend_grow_pages {
	/* A page-aligned page of ERX_PAGE_SIZE bytes, any contents, or 0 when none is left. */
	uintptr_t (*take)(void);
	void	(*give)(uintptr_t page);
} erx_backend_grow_pages_t;

typedef struct erx_backend_grow_table {
	const erx_backend_grow_pages_t *source;	/* where every page of the table comes from and goes back to */
	uintptr_t	*directory;	/* NULL until the first grow */
	uint32_t	 record_bytes;
	uint32_t	 per_page;	/* records in each page */
	uint32_t	 pages;		/* record pages the directory names */
} erx_backend_grow_table_t;

/*
 * An empty table of records of this size, at least 1 and at most ERX_PAGE_SIZE bytes,
 * whose pages come from source, which outlives the table. It holds no page.
 */
void	erx_backend_grow_table_init(erx_backend_grow_table_t *, size_t record_bytes, const erx_backend_grow_pages_t *source);

/* How many records the table has pages for: records 0 to this, exclusive, exist. */
uint32_t	erx_backend_grow_table_capacity(const erx_backend_grow_table_t *);

/* The most records the table can ever hold, a full directory's. */
uint32_t	erx_backend_grow_table_limit(const erx_backend_grow_table_t *);

/* The record at index, or NULL past the capacity. */
void	*erx_backend_grow_table_at(const erx_backend_grow_table_t *, uint32_t index);

/*
 * Grows the table until it holds at least this many records. ERX_ENOMEM when the
 * count is past the limit, or when the source runs out: the records before keep
 * their contents, and any page a grow took stays the table's.
 */
int	erx_backend_grow_table_room(erx_backend_grow_table_t *, uint32_t records) ERX_WARN_UNUSED_RESULT;

/*
 * Copies count records from index from to index to, both runs below the capacity,
 * as memmove does: the runs may overlap.
 */
void	erx_backend_grow_table_move(erx_backend_grow_table_t *, uint32_t to, uint32_t from, uint32_t count);

/* Gives every page back, leaving the table empty and holding none. */
void	erx_backend_grow_table_clear(erx_backend_grow_table_t *);

#endif /* ERX_BACKEND_GROW_TABLE_H */
