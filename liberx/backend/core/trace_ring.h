/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_TRACE_RING_H
#define ERX_BACKEND_TRACE_RING_H

/*
 * The stopgap's trace ring (docs/design-stopgap.md, "The trace ring"): one ring of
 * erx_trace_record records, the layout and events of the kernel's rings. Writers are
 * serialised by their backend's trace lock; the reader takes no lock and keeps a record
 * only if its sequence count, read before and after its fields, is the even count of the
 * index it expected (docs/design-kernel.md, "Sequence-counted records").
 *
 * The ring and its reader are pure over the ring they are handed, so the host tests run
 * them on rings of their own. trace_ring.c is linked only into the root and the hosted
 * process; a task links fiasco/trace_stub.c instead and has no ring.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"

/*
 * Index i's record holds sequence 2i + 1 while written and 2i + 2 after, so the last
 * index a ring may write is the one whose even count is the last below the terminal
 * value, and a head past it is an exhausted ring.
 */
#define ERX_TRACE_RING_INDEX_LAST	((ERX_TRACE_RECORD_SEQ_TERMINAL - 3u) / 2u)
#define ERX_TRACE_RING_HEAD_EXHAUSTED	(ERX_TRACE_RING_INDEX_LAST + 1u)

/* The record's arg words, as abi/kernel.txt counts them. */
#define ERX_TRACE_RING_ARGS	(sizeof(((erx_trace_record_t *)0)->arg) / sizeof(((erx_trace_record_t *)0)->arg[0]))

typedef struct erx_trace_ring {
	erx_trace_record_t	records[ERX_TRACE_RING_RECORDS];
	_Atomic uint64_t	head;	/* the next index to write */
} erx_trace_ring_t;

/* What one write records: everything but the sequence, which the ring assigns. */
typedef struct erx_trace_entry {
	uint64_t	time_ns;
	uint32_t	event;	/* a trace_event */
	uint16_t	cpu;
	uint16_t	flags;	/* trace_record_flags */
	uint64_t	thread;	/* the writer's thread record index plus one, or 0 */
	uint64_t	space;	/* its task index plus one, or 0 */
	uint64_t	arg[ERX_TRACE_RING_ARGS];
} erx_trace_entry_t;

/*
 * Writes entry at the ring's head and moves the head on. The caller holds the ring's
 * trace lock. Returns false, writing nothing, once the ring is exhausted.
 */
bool	erx_trace_ring_put(erx_trace_ring_t *ring, const erx_trace_entry_t *entry);

/*
 * The lock-free reader of erx_backend_trace_read over ring: copies at most max records
 * from cursor into records, and fills result. See api.h for the refusals.
 */
int	erx_trace_ring_read(const erx_trace_ring_t *ring, uint64_t cursor, erx_trace_record_t *records,
	    uint32_t max, erx_trace_read_result_t *result);

/* The root's or the hosted process's one ring. The root touches it as its service starts. */
extern erx_trace_ring_t erx_trace_ring;

/* Faults the ring's pages in, so that no write under the trace lock faults. */
void	erx_trace_ring_touch(void);

/*
 * Records one event of the calling backend thread on the process's ring, under the trace
 * lock, with its time read under that lock. Each backend that links the ring defines it;
 * a task's stub does nothing. The service, which has no thread record, writes through
 * erx_fiasco_trace_service instead.
 */
void	erx_backend_trace_write(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2);

#ifdef ERX_TRACE_RING_TEST_HOOKS
/* Called by the reader between a record's field loads and its second sequence load. */
void	erx_trace_ring_test_between(const erx_trace_record_t *record);
/* Called by the writer between its first and second field stores. */
void	erx_trace_ring_test_writing(const erx_trace_record_t *record);
#endif

#endif /* ERX_BACKEND_TRACE_RING_H */
