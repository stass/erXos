/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's writers of the trace ring (docs/design-stopgap.md, "The trace ring"). Every
 * write happens under the trace lock, which is held across no Fiasco call: the clock is
 * the architecture's counter, read in user mode.
 */

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/trace.h"

static erx_fiasco_lock_t trace_lock;
/* Each root thread's affinity mask, as the service last set it; 0 for wherever it was created. */
static _Atomic uint64_t trace_mask[ERX_FIASCO_THREADS_MAX];

void
erx_fiasco_trace_set_mask(uint32_t index, uint64_t mask)
{
	if (index < ERX_FIASCO_THREADS_MAX)
		atomic_store_explicit(&trace_mask[index], mask, memory_order_relaxed);
}

/* Takes the time and writes the record under the trace lock, so the ring is in time order. */
static void
trace_write(erx_trace_entry_t *entry)
{
	erx_fiasco_lock(&trace_lock);
	entry->time_ns = erx_clock_ns();
	(void)erx_trace_ring_put(&erx_trace_ring, entry);
	erx_fiasco_unlock(&trace_lock);
}

void
erx_backend_trace_write(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2)
{
	const uint32_t index = erx_fiasco_thread_self()->index;
	const uint64_t mask = index < ERX_FIASCO_THREADS_MAX ?
	    atomic_load_explicit(&trace_mask[index], memory_order_relaxed) : 0;
	erx_trace_entry_t entry = { .event = event, .thread = (uint64_t)index + 1,
	    .space = ERX_FIASCO_TASK_ROOT + 1, .arg = { arg0, arg1, arg2 } };

	/* Fiasco places a thread whose mask names one CPU on that CPU (scheduler.cpp:96-103). */
	if (mask != 0 && (mask & (mask - 1)) == 0)
		entry.cpu = (uint16_t)__builtin_ctzll(mask);
	else
		entry.flags = ERX_TRACE_RECORD_CPU_UNKNOWN;
	trace_write(&entry);
}

void
erx_fiasco_trace_service(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2)
{
	erx_trace_entry_t entry = { .event = event, .flags = ERX_TRACE_RECORD_CPU_UNKNOWN,
	    .space = ERX_FIASCO_TASK_ROOT + 1, .arg = { arg0, arg1, arg2 } };

	trace_write(&entry);
}
