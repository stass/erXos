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
contig_held(const erx_fiasco_contig_t *pool, uint32_t page)
{
	return ((pool->used[page / 64] >> (page % 64) & 1) != 0);
}

unsigned
erx_fiasco_contig_order(uint64_t bytes)
{
	unsigned order = ERX_FIASCO_CONTIG_MIN_ORDER;

	while (order <= ERX_FIASCO_CONTIG_MAX_ORDER && (UINT64_C(1) << order) < bytes)
		order++;
	return (order <= ERX_FIASCO_CONTIG_MAX_ORDER ? order : 0);
}

/* One pass up the pool, keeping the length of the free run that ends at each page. */
uint32_t
erx_fiasco_contig_take(erx_fiasco_contig_t *pool, uint32_t pages, uint32_t limit)
{
	const uint32_t end = limit < pool->pages ? limit : pool->pages;
	uint32_t free_run = 0;

	if (pages == 0 || pages > pool->pages)
		return (ERX_FIASCO_CONTIG_NONE);
	for (uint32_t last = 0; last < end; last++) {
		free_run = contig_held(pool, last) ? 0 : free_run + 1;
		if (free_run < pages)
			continue;
		for (uint32_t page = last + 1 - pages; page <= last; page++)
			pool->used[page / 64] |= UINT64_C(1) << (page % 64);
		return (last + 1 - pages);
	}
	return (ERX_FIASCO_CONTIG_NONE);
}
