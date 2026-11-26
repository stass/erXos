/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_TRACE_READ_H
#define ERX_CORE_TRACE_READ_H

/*
 * What a reader of a trace ring is told (docs/design-fiasco.md, "The trace ring"): the
 * result of the ring core's reader, of erx_backend_trace_read and of erx_trace_read. Apart
 * from the ring's header, so a caller of the reads sees no ring and none of its writers.
 */

#include <stdint.h>

/*
 * What one read did: where the next read starts, how many records it copied, and how
 * many records between the cursor and next were overwritten before they were read.
 */
typedef struct erx_trace_read_result {
	uint64_t	next;
	uint64_t	kept;
	uint64_t	overwritten;
} erx_trace_read_result_t;

#endif /* ERX_CORE_TRACE_READ_H */
