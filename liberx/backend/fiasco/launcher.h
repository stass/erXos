/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LAUNCHER_H
#define ERX_FIASCO_LAUNCHER_H

#include <stdint.h>

#include "erx/cdefs.h"
#include "erx/pack.h"

/* The archive's entry at this path, or ERX_EINVAL. */
int	erx_fiasco_launcher_find(const erx_pack_view_t *view, const char *path, uint32_t *entry) ERX_WARN_UNUSED_RESULT;

/*
 * Makes a task from the archive's entry and starts its first thread, with argument
 * in the program's first register. On a refusal nothing of the task remains.
 */
int	erx_fiasco_launch(uint32_t entry, uint32_t flags, uint64_t argument, uint64_t *task) ERX_WARN_UNUSED_RESULT;

/*
 * Waits for the task to end, by a stop or a fault, and takes its status. Its pages
 * are back in the pool, and its index is free, from the return.
 */
int	erx_fiasco_task_join(uint64_t task, int64_t *status) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_LAUNCHER_H */
