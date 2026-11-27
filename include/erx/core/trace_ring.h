/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_TRACE_RING_H
#define ERX_CORE_TRACE_RING_H

/*
 * A trace ring and its lock-free reader (docs/design-fiasco.md, "The trace ring" and "The
 * kernel's trace rings"): one ring of erx_trace_record records, the root's own and each of
 * the kernel's per-CPU rings alike. A ring has one writer at a time: the root's ring its
 * trace lock serialises, a kernel ring its CPU with interrupts masked. The reader takes no
 * lock and keeps a record only if its sequence count, read before and after its fields, is
 * the even count of the index it expected (docs/design-kernel.md, "Sequence-counted
 * records").
 *
 * The ring and its reader are pure over the ring they are handed, so the host tests run
 * them on rings of their own. The kernel links them through erx_cores.a and the root and
 * the hosted process link the same file. The glue's C++ reaches the kernel's rings through
 * erx/core/trace_kernel.h, not here: the ring's fields are C11 atomics.
 *
 * Like every seam header, this one compiles alone as C++ and takes the ABI only from the
 * seam's generated headers (abi_trace.h): it names the ring and
 * its records by their struct tags, incomplete here, and a file that reads or writes their
 * fields includes erx/abi.h, which completes them as erx_trace_ring_t and
 * erx_trace_record_t.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/abi_trace.h"
#include "erx/core/trace_kernel.h"
#include "erx/core/trace_read.h"

/*
 * Index i's record holds sequence 2i + 1 while written and 2i + 2 after, so the last
 * index a ring may write is the one whose even count is the last below the terminal
 * value, and a head past it is an exhausted ring.
 */
#define ERX_TRACE_RING_INDEX_LAST	((ERX_TRACE_RECORD_SEQ_TERMINAL - 3u) / 2u)
#define ERX_TRACE_RING_HEAD_EXHAUSTED	(ERX_TRACE_RING_INDEX_LAST + 1u)

/*
 * The ring is abi/kernel.txt's erx_trace_ring layout, erx_trace_ring_t in erx/abi.h: its
 * records, each one cache line, and its head, the next index to write, on a line of its
 * own.
 */
struct erx_trace_ring;
struct erx_trace_record;

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Empties ring by storing to every one of its pages: each record's sequence 0 and the head
 * 0. It runs before the ring's first write, while nothing writes or reads it, so the pages
 * are faulted in before any write under the writer's lock or mask.
 */
void	erx_trace_ring_clear(struct erx_trace_ring *ring);

/*
 * Writes entry at the ring's head and moves the head on. The caller is the ring's one
 * writer. Returns false, writing nothing, once the ring is exhausted.
 */
bool	erx_trace_ring_put(struct erx_trace_ring *ring, const erx_trace_entry_t *entry);

/*
 * The lock-free reader over ring: copies at most max of the whole records from cursor on
 * into records[0 .. kept) and fills result. A cursor of UINT64_MAX copies nothing and
 * answers the head as next. Any other cursor past the head, or max 0 or over
 * ERX_TRACE_READ_MAX, is ERX_EINVAL; a cursor at the head of an exhausted ring is
 * ERX_ELIMIT. A cursor more than ERX_TRACE_RING_RECORDS below the head starts that far
 * below it, and the records it skips count as overwritten.
 */
int	erx_trace_ring_read(const struct erx_trace_ring *ring, uint64_t cursor,
	    struct erx_trace_record *records, uint32_t max, erx_trace_read_result_t *result);

#ifdef ERX_TRACE_RING_TEST_HOOKS
/* Called by the reader between a record's field loads and its second sequence load. */
void	erx_trace_ring_test_between(const struct erx_trace_record *record);
/* Called by the writer between its first and second field stores. */
void	erx_trace_ring_test_writing(const struct erx_trace_record *record);
#endif

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_TRACE_RING_H */
