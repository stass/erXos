/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/root_mem.h"

void
erx_fiasco_pool_add(erx_fiasco_pool_t *pool, uintptr_t page)
{
	*(uintptr_t *)page = pool->head;
	pool->head = page;
	pool->free_pages++;
	pool->pages++;
}

void
erx_fiasco_pool_put(erx_fiasco_pool_t *pool, uintptr_t page)
{
	/* Back on the free list, but not added: pages counts the pool as it was built. */
	*(uintptr_t *)page = pool->head;
	pool->head = page;
	pool->free_pages++;
	if (pool->held_pages > 0)
		pool->held_pages--;
}

uintptr_t
erx_fiasco_pool_take(erx_fiasco_pool_t *pool)
{
	uintptr_t page;

	page = pool->head;
	if (page == 0)
		return (0);
	pool->head = *(uintptr_t *)page;
	pool->free_pages--;
	pool->held_pages++;
	bzero((void *)page, ERX_PAGE_SIZE);
	return (page);
}

static bool
contig_free(const erx_fiasco_contig_t *pool, uint32_t first, uint32_t pages)
{
	for (uint32_t page = first; page < first + pages; page++)
		if ((pool->used[page / 64] >> (page % 64) & 1) != 0)
			return (false);
	return (true);
}

uint32_t
erx_fiasco_contig_take(erx_fiasco_contig_t *pool, uint32_t pages, uint32_t limit)
{
	const uint32_t end = limit < ERX_FIASCO_CONTIG_PAGES ? limit : ERX_FIASCO_CONTIG_PAGES;
	uint32_t align = 1;

	if (pages == 0 || pages > ERX_FIASCO_CONTIG_PAGES)
		return (ERX_FIASCO_CONTIG_NONE);
	while (align < pages)
		align *= 2;
	for (uint32_t first = 0; first + pages <= end; first += align) {
		if (!contig_free(pool, first, pages))
			continue;
		for (uint32_t page = first; page < first + pages; page++)
			pool->used[page / 64] |= UINT64_C(1) << (page % 64);
		return (first);
	}
	return (ERX_FIASCO_CONTIG_NONE);
}
