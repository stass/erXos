/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The growable table's core: a directory page of record pages, each record found
 * by its index's page and its place in that page. Growing takes the directory with
 * the first record page, and gives the directory back if that page cannot be had,
 * so an empty table holds no page.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/grow_table.h"
#include "liberx/backend/core/mem.h"

static int	table_grow(erx_backend_grow_table_t *);

void
erx_backend_grow_table_init(erx_backend_grow_table_t *table, size_t record_bytes, const erx_backend_grow_pages_t *source)
{
	*table = (erx_backend_grow_table_t){ .source = source, .record_bytes = (uint32_t)record_bytes,
	    .per_page = (uint32_t)(ERX_PAGE_SIZE / record_bytes) };
}

uint32_t
erx_backend_grow_table_capacity(const erx_backend_grow_table_t *table)
{
	return (table->pages * table->per_page);
}

uint32_t
erx_backend_grow_table_limit(const erx_backend_grow_table_t *table)
{
	return (ERX_BACKEND_GROW_PAGES_MAX * table->per_page);
}

void *
erx_backend_grow_table_at(const erx_backend_grow_table_t *table, uint32_t index)
{
	if (index >= erx_backend_grow_table_capacity(table))
		return (NULL);
	return ((void *)(table->directory[index / table->per_page] +
	    (uintptr_t)(index % table->per_page) * table->record_bytes));
}

int
erx_backend_grow_table_room(erx_backend_grow_table_t *table, uint32_t records)
{
	if (records > erx_backend_grow_table_limit(table))
		return (ERX_ENOMEM);
	while (erx_backend_grow_table_capacity(table) < records)
		if (table_grow(table) != ERX_OK)
			return (ERX_ENOMEM);
	return (ERX_OK);
}

/* One more record page, zeroed; the caller has checked the directory has room for it. */
static int
table_grow(erx_backend_grow_table_t *table)
{
	const erx_backend_grow_pages_t *const pages = table->source;
	uintptr_t page;

	if (table->directory == NULL) {
		page = pages->take();
		if (page == 0)
			return (ERX_ENOMEM);
		table->directory = (uintptr_t *)page;
	}
	page = pages->take();
	if (page == 0) {
		if (table->pages == 0) {
			pages->give((uintptr_t)table->directory);
			table->directory = NULL;
		}
		return (ERX_ENOMEM);
	}
	bzero((void *)page, ERX_PAGE_SIZE);
	table->directory[table->pages++] = page;
	return (ERX_OK);
}

void
erx_backend_grow_table_move(erx_backend_grow_table_t *table, uint32_t to, uint32_t from, uint32_t count)
{
	if (to < from)
		for (uint32_t done = 0; done < count; done++)
			bcopy(erx_backend_grow_table_at(table, from + done), erx_backend_grow_table_at(table, to + done),
			    table->record_bytes);
	else if (to > from)
		for (uint32_t left = count; left-- > 0;)
			bcopy(erx_backend_grow_table_at(table, from + left), erx_backend_grow_table_at(table, to + left),
			    table->record_bytes);
}

void
erx_backend_grow_table_clear(erx_backend_grow_table_t *table)
{
	const erx_backend_grow_pages_t *const pages = table->source;

	for (uint32_t page = 0; page < table->pages; page++)
		pages->give(table->directory[page]);
	if (table->directory != NULL)
		pages->give((uintptr_t)table->directory);
	table->directory = NULL;
	table->pages = 0;
}
