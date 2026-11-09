/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The time page's readers, the same in the root and in every task: each finds the
 * page through erx_time_page. The page's one writer after boot is the service, and
 * only the wall offset moves, so the sequence guards that field alone: the scale is
 * fixed before any reader.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/time_table.h"

uint64_t
erx_time_monotonic_ns(void)
{
	const erx_time_page_t *const page = erx_time_page();
	const erx_fiasco_time_scale_t scale = {
		.mult = atomic_load_explicit(&page->mult, memory_order_relaxed),
		.shift = atomic_load_explicit(&page->shift, memory_order_relaxed) };

	return (erx_fiasco_time_ns(erx_fiasco_counter(), scale));
}

bool
erx_time_wall_ns(uint64_t *wall_ns)
{
	const erx_time_page_t *const page = erx_time_page();
	uint64_t before, after;
	int64_t offset;

	do {
		before = atomic_load_explicit(&page->seq, memory_order_acquire);
		if (before >= ERX_FIASCO_TIME_SEQ_LAST)
			return (false);
		offset = atomic_load_explicit(&page->wall_offset_ns, memory_order_relaxed);
		atomic_thread_fence(memory_order_acquire);
		after = atomic_load_explicit(&page->seq, memory_order_relaxed);
	} while (before != after || (before & 1) != 0);
	*wall_ns = erx_time_monotonic_ns() + (uint64_t)offset;
	return (true);
}
