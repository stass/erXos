/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TASK_START_H
#define ERX_FIASCO_TASK_START_H

#include <stdint.h>

#include "liberx/backend/fiasco/thread_offsets.h"

/* The status of a task whose reaper would not start: no program ran. */
#define ERX_FIASCO_TASK_STATUS_UP	INT64_C(-2)
/* The status of a program linked with musl whose start came back, which it never should. */
#define ERX_FIASCO_TASK_STATUS_LIBC	INT64_C(-3)
/* The status of a domain's runtime whose boot information page the reader refused: no program ran. */
#define ERX_FIASCO_TASK_STATUS_BOOT_PAGE	INT64_C(-4)
/* The status of a program linked with musl whose generator refused AT_RANDOM's bytes: no program ran. */
#define ERX_FIASCO_TASK_STATUS_ENTROPY	INT64_C(-5)

/*
 * The program's entry, on the task's first thread, with the argument registers its
 * starter wrote: a program's in the order of the ABI's program_arg, a domain's runtime
 * its boot information page's address in the first. Its result stops the task.
 */
int64_t	erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS]);

#endif /* ERX_FIASCO_TASK_START_H */
