/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's crash records (end_record.h). The form and the rings are set once, on
 * the first thread, before any other thread runs; an end on another thread loads
 * them with acquire order, so it sees the rings whole once it sees their count.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/crash.h"
#include "liberx/backend/fiasco/end_record.h"

static _Atomic uint32_t end_form = ERX_CRASH_FORM_BRIEF;
static const void *_Atomic end_rings;
static _Atomic uint32_t end_ring_count;

void
erx_fiasco_end_boot(bool development)
{
	atomic_store_explicit(&end_form, development ? ERX_CRASH_FORM_FULL : ERX_CRASH_FORM_BRIEF,
	    memory_order_release);
}

void
erx_fiasco_end_trace_rings(const void *rings, uint32_t count)
{
	atomic_store_explicit(&end_rings, rings, memory_order_relaxed);
	atomic_store_explicit(&end_ring_count, count, memory_order_release);
}

uint32_t
erx_fiasco_end_record_write(erx_crash_input_t input, bool trace, void *record, void *scratch)
{
	input.form = atomic_load_explicit(&end_form, memory_order_acquire);
	if (trace) {
		input.ntrace = atomic_load_explicit(&end_ring_count, memory_order_acquire);
		input.trace = input.ntrace != 0 ?
		    atomic_load_explicit(&end_rings, memory_order_relaxed) : NULL;
	}
	return (erx_crash_record_write(&input, record, scratch));
}
