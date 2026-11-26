/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_TRACE_RING_IMPL_H
#define ERX_TRACE_RING_IMPL_H

/*
 * The trace ring's one writer. Only kernel/core/trace_ring.c, whose erx_trace_ring_put
 * writes an entry as it is, and kernel/core/trace_rings.c, whose erx_trace_kernel_put
 * writes it with its ring's CPU and time in place of the entry's, include this file, so
 * the kernel's writer inlines the write and stores each field of the caller's entry
 * straight into the slot, copying no entry (docs/design-fiasco.md, "The kernel's trace
 * rings", "Writing").
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_ring.h"

/*
 * Writes entry, with cpu and time_ns for its own, at the ring's head and moves the head
 * on: the slot's odd sequence first, then every field, then its even sequence and the
 * head, each a release store, so a reader that sees the even count sees the fields. The
 * caller is the ring's one writer. Returns false, writing nothing, once the ring is
 * exhausted.
 */
static inline bool
trace_ring_write(erx_trace_ring_t *ring, const erx_trace_entry_t *entry, uint16_t cpu,
    uint64_t time_ns)
{
	uint64_t index = 0;
	erx_trace_record_t *record;

	(void)erx_trace_ring_head_load(ring, &index);
	if (index > ERX_TRACE_RING_INDEX_LAST)
		return (false);
	record = &ring->records[index % ERX_TRACE_RING_RECORDS];
	(void)erx_trace_record_seq_store(record, 2 * index + 1);
	(void)erx_trace_record_time_ns_store(record, time_ns);
#ifdef ERX_TRACE_RING_TEST_HOOKS
	erx_trace_ring_test_writing(record);
#endif
	(void)erx_trace_record_event_store(record, entry->event);
	(void)erx_trace_record_cpu_store(record, cpu);
	(void)erx_trace_record_flags_store(record, entry->flags);
	(void)erx_trace_record_thread_store(record, entry->thread);
	(void)erx_trace_record_space_store(record, entry->space);
	for (size_t arg = 0; arg < ERX_TRACE_ENTRY_ARGS; arg++)
		(void)erx_trace_record_arg_store(record, arg, entry->arg[arg]);
	(void)erx_trace_record_seq_store(record, 2 * index + 2);
	(void)erx_trace_ring_head_store(ring, index + 1);
	return (true);
}

#endif /* ERX_TRACE_RING_IMPL_H */
