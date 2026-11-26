/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_TRACE_KERNEL_H
#define ERX_CORE_TRACE_KERNEL_H

/*
 * The seam of the kernel's trace rings (docs/design-fiasco.md, "The kernel's trace
 * rings"): what Fiasco's glue (fiasco/kernel/src/erx/erx_trace.cpp) sees of them. Plain
 * C17 and C++17, with no atomic type, so the rings reach C++ only through these
 * functions and as an address, never as a type. kernel/core/trace_rings.c implements it.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/core/abi_trace.h"

#ifdef __cplusplus
extern "C" {
#endif

/* What one write records: everything but the sequence, which the ring assigns. */
typedef struct erx_trace_entry {
	uint64_t	time_ns;
	uint32_t	event;	/* a trace_event */
	uint16_t	cpu;
	uint16_t	flags;	/* trace_record_flags */
	uint64_t	thread;	/* the writer's thread, as its ring names threads, or 0 */
	uint64_t	space;	/* its space, the same way, or 0 */
	uint64_t	arg[ERX_TRACE_ENTRY_ARGS];
} erx_trace_entry_t;

/*
 * Writes entry on CPU cpu's ring. Its caller is that CPU, with interrupts masked, the
 * ring's one writer. A cpu at or past ERX_TRACE_KERNEL_RINGS writes nothing.
 */
void		erx_trace_kernel_put(uint32_t cpu, const erx_trace_entry_t *entry);

/*
 * The rings' first page, and in *bytes their size, a whole number of pages that holds
 * nothing but the rings: what map_trace maps read-only into the root.
 */
const void	*erx_trace_kernel_pages(size_t *bytes);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_TRACE_KERNEL_H */
