/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's trace rings (docs/design-fiasco.md, "The kernel's trace rings"): one ring
 * for each CPU the kernel is configured for, in one static array of the kernel's image.
 * Each CPU writes only its own ring, with interrupts masked; nothing writes them but
 * erx_trace_kernel_put, and the root reads them through a read-only mapping of their
 * pages, with the ring core's reader. Linked into the kernel only, never into the root.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_kernel.h"
#include "erx/core/trace_ring.h"

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

/* The record's cpu is the ring's own, whatever the entry says, so a ring holds only its CPU's records. */
void
erx_trace_kernel_put(uint32_t cpu, const erx_trace_entry_t *entry)
{
	erx_trace_entry_t written = *entry;

	if (cpu >= ERX_TRACE_KERNEL_RINGS)
		return;
	written.cpu = (uint16_t)cpu;
	(void)erx_trace_ring_put(&erx_trace_rings.ring[cpu], &written);
}

const void *
erx_trace_kernel_pages(size_t *bytes)
{
	*bytes = sizeof(erx_trace_rings.pages);
	return (erx_trace_rings.pages);
}
