/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root's own trace ring (docs/design-fiasco.md, "The trace ring") and its reader, the
 * ring core's (kernel/core/trace_ring.c) over this one ring.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

erx_trace_ring_t erx_trace_ring;

void
erx_trace_ring_touch(void)
{
	erx_trace_ring_clear(&erx_trace_ring);
}

int
erx_backend_trace_read(uint64_t cursor, erx_trace_record_t *records, uint32_t max, erx_trace_read_result_t *result)
{
	return (erx_trace_ring_read(&erx_trace_ring, cursor, records, max, result));
}
