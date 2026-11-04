/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The architecture's prescribed sequence for code written by this CPU, the one asmjit
 * and ERTS use (docs/design-arch-aarch64.md, "Cache maintenance"): clean the data side
 * to the point of unification, invalidate the instruction side on every CPU, and
 * synchronize this one. Fiasco lets user mode run all of it.
 */

#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/fiasco/cache.h"

#define CACHE_CTR_DMINLINE_SHIFT	16u
#define CACHE_CTR_LINE_MASK		UINT64_C(0xf)
/* Each field holds the log2 of the line in words. */
#define CACHE_WORD_BYTES		UINT64_C(4)

void
erx_fiasco_cache_make_coherent(uintptr_t start, size_t size)
{
	const uintptr_t end = start + size;
	uint64_t type, data_line, instruction_line;

	__asm__ volatile("mrs %0, ctr_el0" : "=r"(type));
	data_line = CACHE_WORD_BYTES << ((type >> CACHE_CTR_DMINLINE_SHIFT) & CACHE_CTR_LINE_MASK);
	instruction_line = CACHE_WORD_BYTES << (type & CACHE_CTR_LINE_MASK);

	for (uintptr_t line = start & ~(data_line - 1); line < end; line += data_line)
		__asm__ volatile("dc cvau, %0" :: "r"(line));
	__asm__ volatile("dsb ish");
	for (uintptr_t line = start & ~(instruction_line - 1); line < end; line += instruction_line)
		__asm__ volatile("ic ivau, %0" :: "r"(line));
	__asm__ volatile("dsb ish\n\tisb");
}
