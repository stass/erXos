/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_TRACE_RING_H
#define ERX_BACKEND_TRACE_RING_H

/*
 * The root's own trace ring (docs/design-fiasco.md, "The trace ring"): one ring of the
 * ring core (erx/core/trace_ring.h), written by the root's threads under their backend's
 * trace lock. liberx/backend/core/trace_ring.c holds it and is linked only into the root
 * and the hosted process; a task links fiasco/trace_stub.c instead and has no ring.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/trace_ring.h"

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

#endif /* ERX_BACKEND_TRACE_RING_H */
