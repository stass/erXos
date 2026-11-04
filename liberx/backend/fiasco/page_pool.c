/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/root_mem.h"

void
erx_fiasco_pool_put(erx_fiasco_pool_t *pool, uintptr_t page)
{
	*(uintptr_t *)page = pool->head;
	pool->head = page;
	pool->free_pages++;
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
	bzero((void *)page, ERX_PAGE_SIZE);
	return (page);
}
