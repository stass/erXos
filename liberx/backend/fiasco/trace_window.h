/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TRACE_WINDOW_H
#define ERX_FIASCO_TRACE_WINDOW_H

/*
 * The root's window onto the kernel's trace rings (docs/design-fiasco.md, "The kernel's trace
 * rings", "The root's window"). Plain C, with no Fiasco header, so the reader builds for the
 * host.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_ring.h"

/*
 * Where the root's layout reserves the window: below the kernel information page's window
 * (vm.h), above all RAM of every board, one flexpage of 2^ERX_FIASCO_TRACE_WINDOW_ORDER
 * bytes, room for ERX_CPU_LIMIT rings, aligned to its size. The kernel maps its rings at the
 * base and nothing past them.
 */
#define ERX_FIASCO_TRACE_WINDOW		UINT64_C(0xD00000000)
#define ERX_FIASCO_TRACE_WINDOW_ORDER	25u

_Static_assert((uint64_t)ERX_CPU_LIMIT * ERX_TRACE_RING_SIZE <= UINT64_C(1) << ERX_FIASCO_TRACE_WINDOW_ORDER,
    "the trace window holds a ring for every CPU erXos admits");
_Static_assert(ERX_FIASCO_TRACE_WINDOW % (UINT64_C(1) << ERX_FIASCO_TRACE_WINDOW_ORDER) == 0,
    "the trace window is aligned to its size, as a flexpage is");

/*
 * erx_trace_read over count rings at rings: a res other than ERX_ROOT_SLOT_ROOT_RESOURCE,
 * the one slot that holds TRACE, ERX_ERIGHTS; no rings mapped, ERX_ENOTSUP; a cpu at or
 * past count, ERX_EINVAL; otherwise the ring core's reader on that CPU's ring.
 */
int	erx_fiasco_trace_window_read(const erx_trace_ring_t *rings, uint32_t count, uint64_t res, uint32_t cpu,
	    uint64_t cursor, erx_trace_record_t *records, uint32_t max, erx_trace_read_result_t *result);

#endif /* ERX_FIASCO_TRACE_WINDOW_H */
