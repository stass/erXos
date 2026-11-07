/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The hosted process's writer of its trace ring (docs/design-stopgap.md, "The trace
 * ring"): the parks, wakes and deliveries the hosted backend carries out. A host thread
 * has no thread record, task or known CPU, so every record has thread and space 0 and
 * sets cpu_unknown.
 */

#include <pthread.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;

void
erx_backend_trace_write(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2)
{
	erx_trace_entry_t entry = { .event = event, .flags = ERX_TRACE_RECORD_CPU_UNKNOWN,
	    .arg = { arg0, arg1, arg2 } };

	(void)pthread_mutex_lock(&trace_mutex);
	entry.time_ns = erx_clock_ns();
	(void)erx_trace_ring_put(&erx_trace_ring, &entry);
	(void)pthread_mutex_unlock(&trace_mutex);
}
