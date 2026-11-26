/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's trace rings (docs/design-fiasco.md, "The kernel's trace rings"): one ring
 * for each CPU the kernel is configured for, in one static array of the kernel's image.
 * Each CPU writes only its own ring, with interrupts masked, and keeps its times in
 * order; nothing writes them but
 * erx_trace_kernel_put, and the root reads them through a read-only mapping of their
 * pages, with the ring core's reader. Linked into the kernel only, never into the root.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_kernel.h"
#include "erx/core/trace_ring.h"

#include "trace_ring_impl.h"

#define TRACE_RINGS_PAGES \
	((ERX_TRACE_RING_SIZE * ERX_TRACE_KERNEL_RINGS + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE)

/*
 * The rings padded to whole pages and aligned to one, so the pages the root maps hold
 * nothing else of the kernel's. The host's debugger finds them by this symbol.
 */
typedef union erx_trace_rings {
	erx_trace_ring_t	ring[ERX_TRACE_KERNEL_RINGS];
	uint8_t			pages[TRACE_RINGS_PAGES * ERX_PAGE_SIZE];
} erx_trace_rings_t;

_Alignas(ERX_PAGE_SIZE) erx_trace_rings_t erx_trace_rings;

/*
 * The time of each ring's newest record. Each CPU reads and writes only its own, with
 * interrupts masked, as it writes its ring.
 */
static uint64_t trace_rings_newest_ns[ERX_TRACE_KERNEL_RINGS];

/* Whether a map_trace call holds the rings' mapping (erx_trace_kernel_window_claim). */
static atomic_bool trace_rings_window_claimed;

/*
 * The record's cpu is the ring's own, whatever the entry says, so a ring holds only its
 * CPU's records. Its time is the entry's, or the ring's newest where the entry's is
 * earlier: the writer reads the counter with no ISB, so of two reads in one kernel entry
 * the later may come out earlier, and a ring stays in time order, as its readers rely.
 */
void
erx_trace_kernel_put(uint32_t cpu, const erx_trace_entry_t *entry)
{
	uint64_t time_ns;

	if (cpu >= ERX_TRACE_KERNEL_RINGS)
		return;
	time_ns = entry->time_ns;
	if (time_ns < trace_rings_newest_ns[cpu])
		time_ns = trace_rings_newest_ns[cpu];
	trace_rings_newest_ns[cpu] = time_ns;
	(void)trace_ring_write(&erx_trace_rings.ring[cpu], entry, (uint16_t)cpu, time_ns);
}

const void *
erx_trace_kernel_pages(size_t *bytes)
{
	*bytes = sizeof(erx_trace_rings.pages);
	return (erx_trace_rings.pages);
}

bool
erx_trace_kernel_window_claim(void)
{
	return (!atomic_exchange_explicit(&trace_rings_window_claimed, true, memory_order_acq_rel));
}

void
erx_trace_kernel_window_release(void)
{
	atomic_store_explicit(&trace_rings_window_claimed, false, memory_order_release);
}
