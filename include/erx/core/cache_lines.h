/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_CACHE_LINES_H
#define ERX_CORE_CACHE_LINES_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The cache lines that cover [start, start + size), for lines of line bytes, a
 * power of two: *first is the start's line, *end the first line past the range,
 * so a maintenance loop runs while its address is below *end. The masks are as
 * wide as the address, so a range across 4 GiB or higher keeps its upper bits.
 * Returns false, setting nothing, when the range's last line would pass the top
 * of the address space; the caller then maintains the whole cache instead.
 */
static inline bool
erx_cache_lines(uint64_t start, uint64_t size, uint64_t line, uint64_t *first,
    uint64_t *end)
{
	uint64_t last;

	if (__builtin_add_overflow(start, size, &last) ||
	    __builtin_add_overflow(last, line - 1, &last))
		return (false);
	*first = start & ~(line - 1);
	*end = last & ~(line - 1);
	return (true);
}

#endif /* ERX_CORE_CACHE_LINES_H */
