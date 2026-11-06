/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The page's one writer after boot is the service, and only the wall offset moves,
 * so the sequence guards that field alone: the scale is fixed before any reader.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/time_table.h"

/* An odd value is a write in progress, so the last write ends at the largest even one. */
#define TIME_SEQ_LAST		(UINT64_MAX - 1)

static union {
	erx_time_page_t	page;
	_Alignas(ERX_PAGE_SIZE) uint8_t bytes[ERX_PAGE_SIZE];
} time_area;

void
erx_fiasco_time_init(void)
{
	const uint64_t hz = erx_fiasco_counter_hz();
	const erx_fiasco_time_scale_t scale = erx_fiasco_time_scale(hz);

	atomic_store_explicit(&time_area.page.version, ERX_TIME_PAGE_VERSION, memory_order_relaxed);
	atomic_store_explicit(&time_area.page.counter_hz, hz, memory_order_relaxed);
	atomic_store_explicit(&time_area.page.mult, scale.mult, memory_order_relaxed);
	atomic_store_explicit(&time_area.page.shift, scale.shift, memory_order_relaxed);
	atomic_store_explicit(&time_area.page.seq, 0, memory_order_release);
}

const erx_time_page_t *
erx_time_page(void)
{
	return (&time_area.page);
}

uint64_t
erx_time_monotonic_ns(void)
{
	const erx_fiasco_time_scale_t scale = {
		.mult = atomic_load_explicit(&time_area.page.mult, memory_order_relaxed),
		.shift = atomic_load_explicit(&time_area.page.shift, memory_order_relaxed) };

	return (erx_fiasco_time_ns(erx_fiasco_counter(), scale));
}

bool
erx_time_wall_ns(uint64_t *wall_ns)
{
	uint64_t before, after;
	int64_t offset;

	do {
		before = atomic_load_explicit(&time_area.page.seq, memory_order_acquire);
		if (before >= TIME_SEQ_LAST)
			return (false);
		offset = atomic_load_explicit(&time_area.page.wall_offset_ns, memory_order_relaxed);
		atomic_thread_fence(memory_order_acquire);
		after = atomic_load_explicit(&time_area.page.seq, memory_order_relaxed);
	} while (before != after || (before & 1) != 0);
	*wall_ns = erx_time_monotonic_ns() + (uint64_t)offset;
	return (true);
}

int
erx_time_set_wall(uint64_t wall_ns)
{
	const erx_fiasco_time_set_wall_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .wall_ns = wall_ns };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_TIME_SET_WALL, &request, sizeof(request), &reply));
}

int
erx_fiasco_time_set_wall_body(uint64_t wall_ns)
{
	const uint64_t seq = atomic_load_explicit(&time_area.page.seq, memory_order_relaxed);

	if (seq >= TIME_SEQ_LAST)
		return (ERX_ELIMIT);
	atomic_store_explicit(&time_area.page.seq, seq + 1, memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	atomic_store_explicit(&time_area.page.wall_offset_ns, (int64_t)(wall_ns - erx_time_monotonic_ns()),
	    memory_order_relaxed);
	atomic_store_explicit(&time_area.page.seq, seq + 2, memory_order_release);
	return (ERX_OK);
}
