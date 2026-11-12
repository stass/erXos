/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The program layer's memory (pages.h). */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/pages.h"

uint64_t
erx_prog_page_round(uint64_t bytes)
{
	uint64_t rounded;

	if (__builtin_add_overflow(bytes, ERX_PAGE_SIZE - 1, &rounded))
		return (0);
	return (rounded & ~(uint64_t)(ERX_PAGE_SIZE - 1));
}

void *
erx_prog_pages_take(uint64_t bytes)
{
	const uint64_t size = erx_prog_page_round(bytes);
	uint64_t addr = 0;

	if (size == 0 || erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (NULL);
	if (erx_vm_commit(ERX_CAP_SELF, addr, size) != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, addr, size);
		return (NULL);
	}
	return ((void *)(uintptr_t)addr);
}

void
erx_prog_pages_give(const void *run, uint64_t bytes)
{
	if (run != NULL)
		(void)erx_vm_release(ERX_CAP_SELF, (uint64_t)(uintptr_t)run, erx_prog_page_round(bytes));
}

void *
erx_prog_object_map(uint64_t mem, uint64_t bytes, uint32_t prot)
{
	const uint64_t size = erx_prog_page_round(bytes);
	uint64_t addr = 0;

	if (size == 0 || erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (NULL);
	if (erx_vm_map(ERX_CAP_SELF, addr, size, mem, 0, prot) != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, addr, size);
		return (NULL);
	}
	return ((void *)(uintptr_t)addr);
}
