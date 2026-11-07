/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_trace_ring's BIFs (docs/design-live.md, "Tracing"): read/3 drains one trace ring for
 * erx_tracer, and clocks/0 gives the pair that converts ERTS's monotonic time to erx_clock_ns.
 * They are BIFs because the tracer reads each ring every 10 ms. read/3 decodes its terms,
 * makes one call of its row (erx_backend_trace_read for backend, erx_trace_read for
 * {kernel, Cpu}) into a buffer of its own, and returns each kept record's fields as integers.
 * It names no event and creates no atom from a record: erx_tracer decodes the integers with
 * the generated erx_abi_events. The only atoms it makes are status names from the generated
 * erx_status_name table.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <string.h>

#include "sys.h"
#include "global.h"
#include "bif.h"
#include "big.h"
#include "erl_process.h"
#include "erl_time.h"
#include "error.h"

#include "erx/abi.h"
#include "liberx/backend/api.h"

#ifndef ARCH_64
#error "erx_trace_ring's clocks/0 reads monotonic time in nanoseconds, which needs a 64-bit build"
#endif

/* The arity of one record's tuple: {Time, Event, Cpu, Flags, Thread, Space, {A0, A1, A2}}. */
#define RECORD_TUPLE_ARITY	7

/* A source decoded from its term: the ring and, for the kernel's, the CPU. */
typedef struct trace_source {
	bool		kernel;
	uint32_t	cpu;
} trace_source_t;

/* Source: backend, or {kernel, Cpu} with Cpu a u32. */
static bool
decode_source(Eterm term, trace_source_t *source)
{
	const Eterm *pair;

	if (term == am_backend) {
		*source = (trace_source_t){ .kernel = false, .cpu = 0 };
		return (true);
	}
	if (!is_tuple_arity(term, 2))
		return (false);
	pair = tuple_val(term);
	if (pair[1] != am_kernel || !is_small(pair[2]) || signed_val(pair[2]) < 0 ||
	    (Uint)signed_val(pair[2]) > UINT32_MAX)
		return (false);
	*source = (trace_source_t){ .kernel = true, .cpu = (uint32_t)signed_val(pair[2]) };
	return (true);
}

/*
 * Cursor: present, which the reader spells UINT64_MAX, or an integer below it. A cursor the
 * ring returned may exceed a small, so a bignum within 64 bits is read; any other term,
 * UINT64_MAX itself included, is refused, so present has one spelling.
 */
static bool
decode_cursor(Eterm term, uint64_t *cursor)
{
	Uint64 value;

	if (term == am_present) {
		*cursor = UINT64_MAX;
		return (true);
	}
	if (!(is_small(term) || is_big(term)) || !term_to_Uint64(term, &value) || value == UINT64_MAX)
		return (false);
	*cursor = value;
	return (true);
}

/* Max: a small from 1 to ERX_TRACE_READ_MAX. */
static bool
decode_max(Eterm term, uint32_t *max)
{
	if (!is_small(term) || signed_val(term) < 1 || signed_val(term) > ERX_TRACE_READ_MAX)
		return (false);
	*max = (uint32_t)signed_val(term);
	return (true);
}

/*
 * One kept record's fields, read from the private copy through the generated accessors.
 * The tuple's arg element always has three words: the layout's arg count.
 */
typedef struct ring_fields {
	uint64_t	time_ns;
	uint32_t	event;
	uint16_t	cpu;
	uint16_t	flags;
	uint64_t	thread;
	uint64_t	space;
	uint64_t	arg[3];
} ring_fields_t;

_Static_assert(sizeof(((erx_trace_record_t *)0)->arg) / sizeof(((erx_trace_record_t *)0)->arg[0]) == 3,
    "a record's tuple carries three arg words");

static ring_fields_t
load_fields(const erx_trace_record_t *record)
{
	ring_fields_t fields = { 0 };

	(void)erx_trace_record_time_ns_load(record, &fields.time_ns);
	(void)erx_trace_record_event_load(record, &fields.event);
	(void)erx_trace_record_cpu_load(record, &fields.cpu);
	(void)erx_trace_record_flags_load(record, &fields.flags);
	(void)erx_trace_record_thread_load(record, &fields.thread);
	(void)erx_trace_record_space_load(record, &fields.space);
	for (size_t i = 0; i < 3; i++)
		(void)erx_trace_record_arg_load(record, i, &fields.arg[i]);
	return (fields);
}

/* {Time, Event, Cpu, Flags, Thread, Space, {A0, A1, A2}}, one builder call a statement. */
static Eterm
build_record(Uint **hpp, Uint *szp, const erx_trace_record_t *record)
{
	const ring_fields_t f = load_fields(record);
	const Eterm a0 = erts_bld_uint64(hpp, szp, f.arg[0]);
	const Eterm a1 = erts_bld_uint64(hpp, szp, f.arg[1]);
	const Eterm a2 = erts_bld_uint64(hpp, szp, f.arg[2]);
	const Eterm args = erts_bld_tuple(hpp, szp, 3, a0, a1, a2);
	const Eterm stamp = erts_bld_uint64(hpp, szp, f.time_ns);
	const Eterm event = erts_bld_uint64(hpp, szp, f.event);
	const Eterm cpu = erts_bld_uint64(hpp, szp, f.cpu);
	const Eterm flags = erts_bld_uint64(hpp, szp, f.flags);
	const Eterm thread = erts_bld_uint64(hpp, szp, f.thread);
	const Eterm space = erts_bld_uint64(hpp, szp, f.space);

	return (erts_bld_tuple(hpp, szp, RECORD_TUPLE_ARITY, stamp, event, cpu, flags, thread, space, args));
}

/*
 * {ok, Records, Next, Overwritten}, built in two passes of ERTS's builders over the same
 * records: the first, with no heap, sums the words; the second builds into one allocation
 * of exactly that size.
 */
static Eterm
build_result(Uint **hpp, Uint *szp, const erx_trace_record_t *records, const erx_trace_read_result_t *result)
{
	Eterm list = NIL;
	Eterm next, overwritten;

	for (uint64_t i = result->kept; i > 0; i--) {
		const Eterm record = build_record(hpp, szp, &records[i - 1]);

		list = erts_bld_cons(hpp, szp, record, list);
	}
	next = erts_bld_uint64(hpp, szp, result->next);
	overwritten = erts_bld_uint64(hpp, szp, result->overwritten);
	return (erts_bld_tuple(hpp, szp, 4, am_ok, list, next, overwritten));
}

/* {error, unsupported} for ERX_ENOTSUP, {error, Status} for another named status. */
static Eterm
refusal(Process *process, int status)
{
	const char *const name = erx_status_name(status);
	Eterm reason, *hp;

	if (status == ERX_ENOTSUP)
		reason = am_unsupported;
	else if (name != NULL)
		reason = erts_atom_put((const byte *)name, (Sint)strlen(name), ERTS_ATOM_ENC_7BIT_ASCII, 1);
	else
		reason = am_unknown;
	hp = HAlloc(process, 3);
	return (TUPLE2(hp, am_error, reason));
}

BIF_RETTYPE
erx_trace_ring_read_3(BIF_ALIST_3)
{
	trace_source_t source;
	uint64_t cursor;
	uint32_t max;
	erx_trace_record_t *records;
	erx_trace_read_result_t result = { 0 };
	Eterm term;
	Uint size = 0;
	Uint *hp;
	int status;

	if (!decode_source(BIF_ARG_1, &source) || !decode_cursor(BIF_ARG_2, &cursor) || !decode_max(BIF_ARG_3, &max))
		BIF_ERROR(BIF_P, BADARG);
	records = erts_alloc(ERTS_ALC_T_TMP, (Uint)max * sizeof(*records));
	if (source.kernel)
		status = erx_trace_read(0, source.cpu, cursor, records, max, &result);
	else
		status = erx_backend_trace_read(cursor, records, max, &result);
	if (status != ERX_OK) {
		erts_free(ERTS_ALC_T_TMP, records);
		BIF_RET(refusal(BIF_P, status));
	}
	/* The reader writes only within records; kept above max would be its bug, not input. */
	ERTS_ASSERT(result.kept <= max);
	BUMP_REDS(BIF_P, (int)result.kept);
	(void)build_result(NULL, &size, records, &result);
	hp = HAlloc(BIF_P, size);
	term = build_result(&hp, NULL, records, &result);
	erts_free(ERTS_ALC_T_TMP, records);
	BIF_RET(term);
}

/*
 * {Monotonic, Clock}: erlang:monotonic_time(nanosecond) and erx_clock_ns(), read back to back,
 * so a relay adds Clock - Monotonic to each OTP timestamp of a batch. ERTS derives its
 * monotonic time from erx_clock_ns (sys/erxos/sys_time.c), so the pair differs only by ERTS's
 * offset and its time correction.
 */
BIF_RETTYPE
erx_trace_ring_clocks_0(BIF_ALIST_0)
{
	const ErtsMonotonicTime native = erts_get_monotonic_time(erts_proc_sched_data(BIF_P));
	const uint64_t clock = erx_clock_ns();
	const Sint64 monotonic = ERTS_MONOTONIC_TO_NSEC(native) + ERTS_MONOTONIC_OFFSET_NSEC;
	Uint size = 0;
	Uint *hp;

	(void)erts_bld_tuple(NULL, &size, 2, erts_bld_sint64(NULL, &size, monotonic), erts_bld_uint64(NULL, &size, clock));
	hp = HAlloc(BIF_P, size);
	BIF_RET(erts_bld_tuple(&hp, NULL, 2, erts_bld_sint64(&hp, NULL, monotonic), erts_bld_uint64(&hp, NULL, clock)));
}
