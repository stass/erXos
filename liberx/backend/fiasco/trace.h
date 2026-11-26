/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TRACE_H
#define ERX_FIASCO_TRACE_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The root's writers of the trace ring (docs/design-fiasco.md, "The trace ring"), in
 * fiasco/trace.c, which only the root links. erx_backend_trace_write
 * (core/trace_ring.h) records an event of the calling backend thread.
 */

/* Records an event of the service, which has no thread record: thread 0, CPU unknown. */
void	erx_fiasco_trace_service(uint32_t event, uint64_t arg0, uint64_t arg1, uint64_t arg2);

/*
 * The service tells the writers each root thread's affinity mask as it sets or clears it,
 * so a record names the writer's CPU when the mask names exactly one.
 */
void	erx_fiasco_trace_set_mask(uint32_t index, uint64_t mask);

/*
 * Asks the kernel to map its trace rings into the root's window; false when it refused, and
 * erx_trace_read then answers ERX_ENOTSUP for the boot. The root's first thread, once.
 */
bool	erx_fiasco_trace_window_map(void);

#endif /* ERX_FIASCO_TRACE_H */
