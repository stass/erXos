/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's reader of the kernel's trace rings (docs/design-fiasco.md, "The kernel's trace
 * rings", "Reading"): erx_trace_read's answer over the rings the root's read-only window
 * holds, as a pure function of the window and its ring count, so host tests drive it over
 * rings of their own. trace.c maps the window and passes it.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_ring.h"
#include "liberx/backend/fiasco/trace_window.h"

int
erx_fiasco_trace_window_read(const erx_trace_ring_t *rings, uint32_t count, uint64_t res, uint32_t cpu,
    uint64_t cursor, erx_trace_record_t *records, uint32_t max, erx_trace_read_result_t *result)
{
	if (res != ERX_ROOT_SLOT_ROOT_RESOURCE)
		return (ERX_ERIGHTS);
	if (count == 0)
		return (ERX_ENOTSUP);
	if (cpu >= count)
		return (ERX_EINVAL);
	return (erx_trace_ring_read(&rings[cpu], cursor, records, max, result));
}
