/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TIME_H
#define ERX_FIASCO_TIME_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

/*
 * The time page (docs/design-stopgap.md, the call table): one pool page, a memory
 * object of the root budget, that the service fills and writes. The root reads it
 * through the window; a task reads it at ERX_FIASCO_TIME_PAGE_ADDR, where the
 * service mapped it read-only at the task's creation. Reading it needs no call.
 */

/* In every task, just above the thread table, and reserved there, so no erx_vm_reserve hands it out. */
#define ERX_FIASCO_TIME_PAGE_ADDR	(ERX_FIASCO_AREA_START + ERX_FIASCO_THREAD_TABLE_BYTES)
/* An odd sequence is a write in progress, so the last write ends at the largest even one. */
#define ERX_FIASCO_TIME_SEQ_LAST	(UINT64_MAX - 1)

/* The root's page (time_page.c), on its first thread once the object table is up. NULL or why not. */
const char	*erx_fiasco_time_init(void);
/* The root's handle to the page's object, which its boot information names. */
uint64_t	erx_fiasco_time_object(void);
/* On the service: maps the page read-only at its address in a new task, which reserved it. */
int		erx_fiasco_time_page_map(uint32_t task) ERX_WARN_UNUSED_RESULT;

/* The page: its window address in the root (time_page.c), ERX_FIASCO_TIME_PAGE_ADDR in a task (task_start.c). */
const erx_time_page_t *erx_time_page(void);
/* The readers (time.c), in the root and in every task. */
uint64_t	erx_time_monotonic_ns(void);
/* False when the page's sequence has run out, which leaves wall time unavailable. */
bool		erx_time_wall_ns(uint64_t *wall_ns) ERX_WARN_UNUSED_RESULT;

/* Sets wall time from now on. ERX_ELIMIT when the page's sequence has run out. */
int		erx_time_set_wall(uint64_t wall_ns) ERX_WARN_UNUSED_RESULT;
/* The call's body, on the service. */
int		erx_fiasco_time_set_wall_body(uint64_t wall_ns);

#endif /* ERX_FIASCO_TIME_H */
