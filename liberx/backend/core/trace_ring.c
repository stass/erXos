/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The stopgap's trace ring and its lock-free reader (docs/design-stopgap.md, "The trace
 * ring"). Every field of a record is reached through its generated accessor, which
 * performs one atomic access with the order abi/kernel.txt declares.
 *
 * The reader trusts only what it checks: it reads the head once, derives every slot it
 * touches from an index below that head modulo the ring's size, keeps a record only if
 * both sequence loads are the even count of that index, and writes only records[0 .. max).
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

erx_trace_ring_t erx_trace_ring;

static const erx_trace_record_t *
trace_slot(const erx_trace_ring_t *ring, uint64_t index)
{
	return (&ring->records[index % ERX_TRACE_RING_RECORDS]);
}

void
erx_trace_ring_touch(void)
{
	for (uint32_t index = 0; index < ERX_TRACE_RING_RECORDS; index++)
		(void)erx_trace_record_seq_store(&erx_trace_ring.records[index], 0);
}

bool
erx_trace_ring_put(erx_trace_ring_t *ring, const erx_trace_entry_t *entry)
{
	const uint64_t index = atomic_load_explicit(&ring->head, memory_order_relaxed);
	erx_trace_record_t *record;

	if (index > ERX_TRACE_RING_INDEX_LAST)
		return (false);
	record = &ring->records[index % ERX_TRACE_RING_RECORDS];
	(void)erx_trace_record_seq_store(record, 2 * index + 1);
	(void)erx_trace_record_time_ns_store(record, entry->time_ns);
#ifdef ERX_TRACE_RING_TEST_HOOKS
	erx_trace_ring_test_writing(record);
#endif
	(void)erx_trace_record_event_store(record, entry->event);
	(void)erx_trace_record_cpu_store(record, entry->cpu);
	(void)erx_trace_record_flags_store(record, entry->flags);
	(void)erx_trace_record_thread_store(record, entry->thread);
	(void)erx_trace_record_space_store(record, entry->space);
	for (size_t arg = 0; arg < ERX_TRACE_RING_ARGS; arg++)
		(void)erx_trace_record_arg_store(record, arg, entry->arg[arg]);
	(void)erx_trace_record_seq_store(record, 2 * index + 2);
	atomic_store_explicit(&ring->head, index + 1, memory_order_release);
	return (true);
}

/*
 * One record by the sequence-counted protocol: true, with entry filled, only if the
 * count read before and after the fields is index's even count, so entry is the state
 * the writer of that index published and no other.
 */
static bool
trace_snapshot(const erx_trace_record_t *record, uint64_t index, erx_trace_entry_t *entry)
{
	const uint64_t expected = 2 * index + 2;
	uint64_t before, after;
	bool loaded;

	loaded = erx_trace_record_seq_load(record, &before);
	loaded &= erx_trace_record_time_ns_load(record, &entry->time_ns);
	loaded &= erx_trace_record_event_load(record, &entry->event);
	loaded &= erx_trace_record_cpu_load(record, &entry->cpu);
	loaded &= erx_trace_record_flags_load(record, &entry->flags);
	loaded &= erx_trace_record_thread_load(record, &entry->thread);
	loaded &= erx_trace_record_space_load(record, &entry->space);
	for (size_t arg = 0; arg < ERX_TRACE_RING_ARGS; arg++)
		loaded &= erx_trace_record_arg_load(record, arg, &entry->arg[arg]);
#ifdef ERX_TRACE_RING_TEST_HOOKS
	erx_trace_ring_test_between(record);
#endif
	loaded &= erx_trace_record_seq_load(record, &after);
	return (loaded && before == expected && after == expected);
}

static void
trace_copy(erx_trace_record_t *out, uint64_t index, const erx_trace_entry_t *entry)
{
	(void)erx_trace_record_seq_store(out, 2 * index + 2);
	(void)erx_trace_record_time_ns_store(out, entry->time_ns);
	(void)erx_trace_record_event_store(out, entry->event);
	(void)erx_trace_record_cpu_store(out, entry->cpu);
	(void)erx_trace_record_flags_store(out, entry->flags);
	(void)erx_trace_record_thread_store(out, entry->thread);
	(void)erx_trace_record_space_store(out, entry->space);
	for (size_t arg = 0; arg < ERX_TRACE_RING_ARGS; arg++)
		(void)erx_trace_record_arg_store(out, arg, entry->arg[arg]);
}

int
erx_trace_ring_read(const erx_trace_ring_t *ring, uint64_t cursor, erx_trace_record_t *records,
    uint32_t max, erx_trace_read_result_t *result)
{
	uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
	uint64_t count, kept = 0, lost = 0;
	erx_trace_entry_t entry;

	if (records == NULL || result == NULL || max == 0 || max > ERX_TRACE_READ_MAX)
		return (ERX_EINVAL);
	/* No writer moves the head past exhaustion; one that read otherwise is clamped there. */
	if (head > ERX_TRACE_RING_HEAD_EXHAUSTED)
		head = ERX_TRACE_RING_HEAD_EXHAUSTED;
	if (cursor == UINT64_MAX) {
		*result = (erx_trace_read_result_t){ .next = head };
		return (ERX_OK);
	}
	if (cursor > head)
		return (ERX_EINVAL);
	if (cursor == head && head == ERX_TRACE_RING_HEAD_EXHAUSTED)
		return (ERX_ELIMIT);
	if (head - cursor > ERX_TRACE_RING_RECORDS) {
		lost = head - ERX_TRACE_RING_RECORDS - cursor;
		cursor = head - ERX_TRACE_RING_RECORDS;
	}
	count = head - cursor < max ? head - cursor : max;
	for (uint64_t index = cursor; index < cursor + count; index++) {
		if (trace_snapshot(trace_slot(ring, index), index, &entry))
			trace_copy(&records[kept++], index, &entry);
		else
			lost++;
	}
	*result = (erx_trace_read_result_t){ .next = cursor + count, .kept = kept, .overwritten = lost };
	return (ERX_OK);
}

int
erx_backend_trace_read(uint64_t cursor, erx_trace_record_t *records, uint32_t max, erx_trace_read_result_t *result)
{
	return (erx_trace_ring_read(&erx_trace_ring, cursor, records, max, result));
}
