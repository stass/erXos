/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's side of the time page (docs/design-stopgap.md, the call table): the page
 * is a memory object of the root budget, made before the service starts and kept by
 * erx_fiasco_object_keep, so no close or destroy ends it and its record, its window
 * page and every task's mapping of it hold until the machine ends. The service is its
 * one writer, through the window.
 */

#include <stdatomic.h>
#include <stdint.h>

#include "liberx/backend/core/handles.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/time_table.h"

/*
 * Set once on the root's first thread before the service starts, and never again, so a
 * plain read of them is ordered by the service's start. Until then the page is a zeroed
 * record, whose scale reads every counter as 0 ns, so an early read is wrong but safe.
 */
static erx_time_page_t time_unset;
static erx_time_page_t *time_page = &time_unset;
static uint64_t time_handle;
static uint32_t time_record;

const char *
erx_fiasco_time_init(void)
{
	const erx_fiasco_mem_create_request_t request = { .caller = ERX_FIASCO_TASK_ROOT, .budget = ERX_CAP_SELF,
	    .size = ERX_PAGE_SIZE };
	uint64_t hz, handle;
	erx_fiasco_time_scale_t scale;
	uint32_t record;
	uintptr_t window;

	if (erx_fiasco_task_mem_create_body(ERX_FIASCO_TASK_ROOT, &request, &handle) != ERX_OK ||
	    erx_fiasco_object_find(ERX_FIASCO_TASK_ROOT, handle, ERX_BACKEND_OBJECT_MEMORY, &record) != ERX_OK)
		return ("time: no memory for the time page");
	window = erx_fiasco_vm_object_window(record, 0);
	if (window == 0)
		return ("time: the time page has no window page");
	erx_fiasco_object_keep(record);
	time_page = (erx_time_page_t *)window;
	time_handle = handle;
	time_record = record;

	/*
	 * A counter without a frequency reads as time 0 for ever (erx_fiasco_clock_ns), and a
	 * clock that never advances would hold every pipe write in its wait for the clock to
	 * pass its publication (docs/design-pipes.md, "Writing").
	 */
	hz = erx_fiasco_counter_hz();
	if (hz == 0)
		return ("time: the counter reports no frequency, so the clock would not advance");
	scale = erx_fiasco_time_scale(hz);
	atomic_store_explicit(&time_page->version, ERX_TIME_PAGE_VERSION, memory_order_relaxed);
	atomic_store_explicit(&time_page->counter_hz, hz, memory_order_relaxed);
	atomic_store_explicit(&time_page->mult, scale.mult, memory_order_relaxed);
	atomic_store_explicit(&time_page->shift, scale.shift, memory_order_relaxed);
	atomic_store_explicit(&time_page->seq, 0, memory_order_release);
	return (NULL);
}

const erx_time_page_t *
erx_time_page(void)
{
	return (time_page);
}

uint64_t
erx_fiasco_time_object(void)
{
	return (time_handle);
}

int
erx_fiasco_time_page_map(uint32_t task)
{
	return (erx_fiasco_vm_object_map(task, time_record, ERX_FIASCO_TIME_PAGE_ADDR, ERX_PAGE_SIZE, 0, ERX_PROT_R));
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
	const uint64_t seq = atomic_load_explicit(&time_page->seq, memory_order_relaxed);

	if (seq >= ERX_FIASCO_TIME_SEQ_LAST)
		return (ERX_ELIMIT);
	atomic_store_explicit(&time_page->seq, seq + 1, memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	atomic_store_explicit(&time_page->wall_offset_ns, (int64_t)(wall_ns - erx_time_monotonic_ns()),
	    memory_order_relaxed);
	atomic_store_explicit(&time_page->seq, seq + 2, memory_order_release);
	return (ERX_OK);
}
