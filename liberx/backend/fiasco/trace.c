/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's writers of the trace ring (docs/design-fiasco.md, "The trace ring"). Every
 * write happens under the trace lock, which is held across no Fiasco call: the clock,
 * erx_fiasco_clock_ns, is the architecture's counter, read in user mode.
 */

#include <stdatomic.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/ipc.h>
#include <l4/sys/types.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/trace.h"
#include "liberx/backend/fiasco/trace_window.h"
#include "liberx/backend/fiasco/vm.h"
#include "erx/core/trace_window.h"

static erx_fiasco_lock_t trace_lock;

_Static_assert(ERX_FIASCO_TRACE_WINDOW + (UINT64_C(1) << ERX_FIASCO_TRACE_WINDOW_ORDER) <= ERX_FIASCO_KIP_WINDOW,
    "the trace window ends below the kernel information page's");

/*
 * How many of the kernel's rings the window holds: 0 until map_trace answers, and for a
 * boot whose kernel refused it. Written once on the first thread, before the service runs.
 */
static _Atomic uint32_t trace_kernel_rings;
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
	entry->time_ns = erx_fiasco_clock_ns();
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

/*
 * map_trace on the platform control object (docs/design-fiasco.md, "The kernel's trace
 * rings", "The root's window"): the kernel maps its rings read-only at the window's base and
 * answers how many it mapped. Once per boot, on the first thread.
 */
bool
erx_fiasco_trace_window_map(void)
{
	l4_msg_regs_t *const mr = l4_utcb_mr();
	l4_msgtag_t tag;

	mr->mr[0] = ERX_FIASCO_PFC_MAP_TRACE;
	mr->mr[1] = l4_fpage(ERX_FIASCO_TRACE_WINDOW, ERX_FIASCO_TRACE_WINDOW_ORDER, L4_FPAGE_RO).raw;
	tag = l4_ipc_call(L4_BASE_ICU_CAP, l4_utcb(),
	    l4_msgtag(L4_PROTO_PLATFORM_CTL, ERX_FIASCO_PFC_MAP_TRACE_WORDS, 0, 0), L4_IPC_NEVER);
	if (l4_error(tag) <= 0 || l4_error(tag) > ERX_CPU_LIMIT)
		return (false);
	atomic_store_explicit(&trace_kernel_rings, (uint32_t)l4_error(tag), memory_order_release);
	return (true);
}

int
erx_trace_read(uint64_t res, uint32_t cpu, uint64_t cursor, erx_trace_record_t *records, uint32_t max,
    erx_trace_read_result_t *result)
{
	return (erx_fiasco_trace_window_read((const erx_trace_ring_t *)(uintptr_t)ERX_FIASCO_TRACE_WINDOW,
	    atomic_load_explicit(&trace_kernel_rings, memory_order_acquire), res, cpu, cursor, records, max, result));
}
