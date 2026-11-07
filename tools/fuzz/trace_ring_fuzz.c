/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The trace ring's lock-free reader (liberx/backend/core/trace_ring.c) over a ring the
 * input writes freely: its head, a cursor, max, and the sequence and fields of any
 * slots, so the reader meets counts and heads no writer would leave. Whatever the
 * ring holds, the reader answers ERX_OK, ERX_EINVAL or ERX_ELIMIT, writes no record
 * past max, accounts for every index between the cursor and next, and keeps only
 * records whose count is the even count of an index it read. The kernel's window
 * copy reuses this target in Phase 2.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static erx_trace_ring_t ring;
static erx_trace_record_t out[ERX_TRACE_READ_MAX + 1];

static uint64_t
take(const uint8_t **data, size_t *length, size_t bytes)
{
	uint64_t value = 0;

	for (size_t i = 0; i < bytes && *length > 0; i++, (*data)++, (*length)--)
		value |= (uint64_t)**data << (8 * i);
	return (value);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t length)
{
	const uint64_t head = take(&data, &length, 8);
	uint64_t cursor = take(&data, &length, 8);
	const uint32_t max = (uint32_t)take(&data, &length, 2);
	const uint64_t marker = UINT64_C(0x7e7e7e7e7e7e7e7e);
	erx_trace_read_result_t result = { 0 };
	uint64_t seq;
	int status;

	for (uint32_t slot = 0; slot < ERX_TRACE_RING_RECORDS; slot++)
		(void)erx_trace_record_seq_store(&ring.records[slot], 0);
	/* Each slot entry: its index, then its sequence and one field word. */
	while (length >= 18) {
		erx_trace_record_t *const record = &ring.records[take(&data, &length, 2) % ERX_TRACE_RING_RECORDS];

		(void)erx_trace_record_seq_store(record, take(&data, &length, 8));
		(void)erx_trace_record_thread_store(record, take(&data, &length, 8));
	}
	atomic_store_explicit(&ring.head, head, memory_order_relaxed);
	for (uint32_t i = 0; i <= ERX_TRACE_READ_MAX; i++)
		(void)erx_trace_record_seq_store(&out[i], marker);

	status = erx_trace_ring_read(&ring, cursor, out, max, &result);
	if (status != ERX_OK) {
		if (status != ERX_EINVAL && status != ERX_ELIMIT)
			abort();
		return (0);
	}
	if (max == 0 || max > ERX_TRACE_READ_MAX || result.kept > max)
		abort();
	for (uint32_t i = (uint32_t)result.kept; i <= ERX_TRACE_READ_MAX; i++)
		if (!erx_trace_record_seq_load(&out[i], &seq) || seq != marker)
			abort();
	if (cursor == UINT64_MAX) {
		if (result.kept != 0 || result.overwritten != 0 || result.next > ERX_TRACE_RING_HEAD_EXHAUSTED)
			abort();
		return (0);
	}
	/* Every index from the cursor to next is kept or counted, and next is at most the head. */
	if (result.next < cursor || result.next - cursor != result.kept + result.overwritten ||
	    result.next > ERX_TRACE_RING_HEAD_EXHAUSTED)
		abort();
	for (uint64_t k = 0; k < result.kept; k++) {
		if (!erx_trace_record_seq_load(&out[k], &seq) || seq < 2 || seq % 2 != 0 ||
		    (seq - 2) / 2 < cursor || (seq - 2) / 2 >= result.next)
			abort();
		if (k > 0) {
			uint64_t previous;

			(void)erx_trace_record_seq_load(&out[k - 1], &previous);
			if (previous >= seq)
				abort();
		}
	}
	return (0);
}
