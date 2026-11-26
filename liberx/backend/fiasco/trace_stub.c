/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's side of the trace rings (docs/design-fiasco.md, "The trace ring" and "The
 * kernel's trace rings"). Only the root links its ring and maps the kernel's; a task links
 * this file instead, so both readers refuse and its parks and wakes record nothing.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/trace_ring.h"

int
erx_backend_trace_read(uint64_t cursor, erx_trace_record_t *records, uint32_t max, erx_trace_read_result_t *result)
{
	(void)cursor;
	(void)records;
	(void)max;
	(void)result;
	return (ERX_ENOTSUP);
}

void
erx_backend_trace_write(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2)
{
	(void)event;
	(void)arg0;
	(void)arg1;
	(void)arg2;
}

int
erx_trace_read(uint64_t res, uint32_t cpu, uint64_t cursor, erx_trace_record_t *records, uint32_t max,
    erx_trace_read_result_t *result)
{
	(void)res;
	(void)cpu;
	(void)cursor;
	(void)records;
	(void)max;
	(void)result;
	return (ERX_ENOTSUP);
}
