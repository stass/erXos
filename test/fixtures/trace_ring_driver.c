/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The trace ring and its lock-free reader on the host (docs/design-stopgap.md, "The
 * trace ring", and its Verification row), driven by test/host/trace_ring_test.rb. Each
 * mode prints "MODE: ok" or names what it found broken and exits 1. Built with
 * liberx/backend/core/trace_ring.c and ERX_TRACE_RING_TEST_HOOKS, or, for the mode
 * "stub", with liberx/backend/fiasco/trace_stub.c, a task's side.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

#define RACE_WRITERS	4
#define RACE_RECORDS	400000u
#define RACE_READ_MAX	8u

static erx_trace_record_t out[ERX_TRACE_READ_MAX + 1];


static int
fail(const char *mode, const char *what)
{
	printf("%s: %s\n", mode, what);
	return (1);
}

#ifndef TRACE_RING_STUB
static erx_trace_ring_t ring;

/* Every field of index i's record is a function of i, so a torn copy shows. */
static erx_trace_entry_t
entry_of(uint64_t i)
{
	return ((erx_trace_entry_t){ .time_ns = i * 7 + 1, .event = (uint32_t)(1 + i % 5), .cpu = (uint16_t)i,
	    .flags = (uint16_t)(i & 1), .thread = i ^ 0x5555, .space = i + 3, .arg = { i, ~i, i * 13 } });
}

/* True when record is whole and is index i's, as entry_of made it. */
static bool
record_is(const erx_trace_record_t *record, uint64_t i)
{
	const erx_trace_entry_t want = entry_of(i);
	erx_trace_entry_t got;
	uint64_t seq;

	(void)erx_trace_record_seq_load(record, &seq);
	(void)erx_trace_record_time_ns_load(record, &got.time_ns);
	(void)erx_trace_record_event_load(record, &got.event);
	(void)erx_trace_record_cpu_load(record, &got.cpu);
	(void)erx_trace_record_flags_load(record, &got.flags);
	(void)erx_trace_record_thread_load(record, &got.thread);
	(void)erx_trace_record_space_load(record, &got.space);
	for (size_t arg = 0; arg < 3; arg++)
		(void)erx_trace_record_arg_load(record, arg, &got.arg[arg]);
	return (seq == 2 * i + 2 && got.time_ns == want.time_ns && got.event == want.event && got.cpu == want.cpu &&
	    got.flags == want.flags && got.thread == want.thread && got.space == want.space &&
	    got.arg[0] == want.arg[0] && got.arg[1] == want.arg[1] && got.arg[2] == want.arg[2]);
}

static void
put_next(void)
{
	const erx_trace_entry_t entry = entry_of(atomic_load_explicit(&ring.head, memory_order_relaxed));

	(void)erx_trace_ring_put(&ring, &entry);
}

/* The hook the reader calls between its field loads and its second sequence load. */
static _Atomic(erx_trace_record_t *) hook_target;

void
erx_trace_ring_test_between(const erx_trace_record_t *record)
{
	erx_trace_record_t *const target = atomic_load_explicit(&hook_target, memory_order_relaxed);

	/* A writer lapping the reader: index 4096 rewrites index 0's slot. */
	if (target != NULL && target == record) {
		atomic_store_explicit(&hook_target, NULL, memory_order_relaxed);
		put_next();
	}
}

/* While armed, a reader reads index 0 in the middle of the write that overwrites it. */
static _Atomic bool writing_armed;
static erx_trace_read_result_t writing_result;
static int writing_status;

void
erx_trace_ring_test_writing(const erx_trace_record_t *record)
{
	(void)record;
	if (atomic_exchange_explicit(&writing_armed, false, memory_order_relaxed))
		writing_status = erx_trace_ring_read(&ring, 0, out, 1, &writing_result);
}

static int
mode_basic(void)
{
	erx_trace_read_result_t result;

	for (int i = 0; i < 3; i++)
		put_next();
	if (erx_trace_ring_read(&ring, 0, out, 8, &result) != ERX_OK || result.next != 3 || result.kept != 3 ||
	    result.overwritten != 0)
		return (fail("basic", "three records not read back"));
	for (uint64_t i = 0; i < 3; i++)
		if (!record_is(&out[i], i))
			return (fail("basic", "a field read back differs"));
	if (erx_trace_ring_read(&ring, UINT64_MAX, out, 1, &result) != ERX_OK || result.next != 3 ||
	    result.kept != 0 || result.overwritten != 0)
		return (fail("basic", "the present cursor is not the head"));
	if (erx_trace_ring_read(&ring, 3, out, 1, &result) != ERX_OK || result.next != 3 || result.kept != 0)
		return (fail("basic", "a read at the head copied something"));
	return (0);
}

static int
mode_refusals(void)
{
	erx_trace_read_result_t result;

	for (int i = 0; i < 4; i++)
		put_next();
	if (erx_trace_ring_read(&ring, 5, out, 1, &result) != ERX_EINVAL)
		return (fail("refusals", "a cursor past the head was accepted"));
	if (erx_trace_ring_read(&ring, 0, out, 0, &result) != ERX_EINVAL)
		return (fail("refusals", "max 0 was accepted"));
	if (erx_trace_ring_read(&ring, 0, out, ERX_TRACE_READ_MAX + 1, &result) != ERX_EINVAL)
		return (fail("refusals", "max 513 was accepted"));
	return (0);
}

/* A short read writes exactly max records: the slot after them keeps its marker. */
static int
mode_bounded(void)
{
	erx_trace_read_result_t result;
	uint64_t marker;

	for (int i = 0; i < 10; i++)
		put_next();
	(void)erx_trace_record_seq_store(&out[4], UINT64_C(0xfeed));
	if (erx_trace_ring_read(&ring, 0, out, 4, &result) != ERX_OK || result.kept != 4 || result.next != 4)
		return (fail("bounded", "a read of four did not copy four"));
	(void)erx_trace_record_seq_load(&out[4], &marker);
	if (marker != 0xfeed)
		return (fail("bounded", "a read wrote past max"));
	return (0);
}

static int
mode_lapped(void)
{
	erx_trace_read_result_t result;

	for (uint32_t i = 0; i < ERX_TRACE_RING_RECORDS + 100; i++)
		put_next();
	if (erx_trace_ring_read(&ring, 0, out, ERX_TRACE_READ_MAX, &result) != ERX_OK)
		return (fail("lapped", "the read was refused"));
	if (result.overwritten != 100)
		return (fail("lapped", "the lapped count differs"));
	if (result.kept != ERX_TRACE_READ_MAX || result.next != 100 + ERX_TRACE_READ_MAX || !record_is(&out[0], 100))
		return (fail("lapped", "the read did not start at the oldest record"));
	return (0);
}

static int
mode_between(void)
{
	erx_trace_read_result_t result;

	for (uint32_t i = 0; i < ERX_TRACE_RING_RECORDS; i++)
		put_next();
	atomic_store_explicit(&hook_target, &ring.records[0], memory_order_relaxed);
	if (erx_trace_ring_read(&ring, 0, out, 2, &result) != ERX_OK)
		return (fail("between", "the read was refused"));
	if (result.kept != 1 || result.overwritten != 1 || !record_is(&out[0], 1))
		return (fail("between", "a record rewritten during its read was kept"));
	return (0);
}

static int
mode_writing(void)
{
	for (uint32_t i = 0; i < ERX_TRACE_RING_RECORDS; i++)
		put_next();
	atomic_store_explicit(&writing_armed, true, memory_order_relaxed);
	put_next();
	if (writing_status != ERX_OK || writing_result.kept != 0 || writing_result.overwritten != 1)
		return (fail("writing", "a record read while written was kept"));
	return (0);
}

static int
mode_exhausted(void)
{
	erx_trace_read_result_t result;

	atomic_store_explicit(&ring.head, ERX_TRACE_RING_INDEX_LAST, memory_order_relaxed);
	if (!erx_trace_ring_put(&ring, &(erx_trace_entry_t){ .event = 1 }))
		return (fail("exhausted", "the last index was not written"));
	if (erx_trace_ring_put(&ring, &(erx_trace_entry_t){ .event = 2 }))
		return (fail("exhausted", "a write past the last index was accepted"));
	if (erx_trace_ring_read(&ring, ERX_TRACE_RING_INDEX_LAST, out, 4, &result) != ERX_OK || result.kept != 1 ||
	    result.next != ERX_TRACE_RING_HEAD_EXHAUSTED)
		return (fail("exhausted", "the last record was not read"));
	if (erx_trace_ring_read(&ring, ERX_TRACE_RING_HEAD_EXHAUSTED, out, 4, &result) != ERX_ELIMIT)
		return (fail("exhausted", "the exhausted ring's head was not ERX_ELIMIT"));
	return (0);
}

static pthread_mutex_t race_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic bool race_done;

static void *
race_writer(void *unused)
{
	(void)unused;
	for (;;) {
		pthread_mutex_lock(&race_lock);
		if (atomic_load_explicit(&ring.head, memory_order_relaxed) >= RACE_RECORDS) {
			pthread_mutex_unlock(&race_lock);
			break;
		}
		put_next();
		pthread_mutex_unlock(&race_lock);
	}
	return (NULL);
}

/*
 * Four writers and a reader that reads the oldest records, the ones being overwritten,
 * a few at a time:
 * every kept record is whole, and every index between two cursors is kept or counted.
 */
static int
mode_race(void)
{
	pthread_t writers[RACE_WRITERS];
	erx_trace_read_result_t result;
	uint64_t cursor = 0, head;
	int status = 0;

	for (int i = 0; i < RACE_WRITERS; i++)
		pthread_create(&writers[i], NULL, race_writer, NULL);
	while (status == 0 && !atomic_load_explicit(&race_done, memory_order_relaxed)) {
		head = atomic_load_explicit(&ring.head, memory_order_acquire);
		if (head >= RACE_RECORDS)
			atomic_store_explicit(&race_done, true, memory_order_relaxed);
		/* The oldest records are the ones a writer is overwriting now. */
		if (head > ERX_TRACE_RING_RECORDS && head - ERX_TRACE_RING_RECORDS > cursor)
			cursor = head - ERX_TRACE_RING_RECORDS;
		if (erx_trace_ring_read(&ring, cursor, out, RACE_READ_MAX, &result) != ERX_OK)
			status = fail("race", "a read was refused");
		else if (result.kept + result.overwritten != result.next - cursor)
			status = fail("race", "a read lost count of a record");
		for (uint64_t k = 0; status == 0 && k < result.kept; k++) {
			uint64_t seq;

			(void)erx_trace_record_seq_load(&out[k], &seq);
			if (seq < 2 || seq % 2 != 0 || !record_is(&out[k], (seq - 2) / 2))
				status = fail("race", "a kept record is torn");
		}
		if (status == 0)
			cursor = result.next;
	}
	for (int i = 0; i < RACE_WRITERS; i++)
		pthread_join(writers[i], NULL);
	return (status);
}
#else
static int
mode_stub(void)
{
	erx_trace_read_result_t result;

	if (erx_backend_trace_read(UINT64_MAX, out, 1, &result) != ERX_ENOTSUP)
		return (fail("stub", "a task's read was not ERX_ENOTSUP"));
	erx_backend_trace_write(ERX_TRACE_EVENT_PARK, 0, 0, 0);
	return (0);
}
#endif

int
main(int argc, char **argv)
{
	static const struct {
		const char	*name;
		int		(*run)(void);
	} modes[] = {
#ifndef TRACE_RING_STUB
	    { "basic", mode_basic }, { "refusals", mode_refusals }, { "bounded", mode_bounded },
	    { "lapped", mode_lapped }, { "between", mode_between }, { "writing", mode_writing },
	    { "exhausted", mode_exhausted },
	    { "race", mode_race },
#else
	    { "stub", mode_stub },
#endif
	};

	if (argc != 2)
		return (2);
	for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
		if (strcmp(argv[1], modes[i].name) != 0)
			continue;
		if (modes[i].run() != 0)
			return (1);
		printf("%s: ok\n", modes[i].name);
		return (0);
	}
	return (2);
}
