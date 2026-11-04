/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TASK_START_H
#define ERX_FIASCO_TASK_START_H

#include <stdint.h>

/* The status of a task whose reaper would not start: no program ran. */
#define ERX_FIASCO_TASK_STATUS_UP	INT64_C(-2)
/* The status of a program linked with musl whose start came back, which it never should. */
#define ERX_FIASCO_TASK_STATUS_LIBC	INT64_C(-3)

/* The program's entry, on the task's first thread. Its result stops the task. */
int64_t	erx_task_main(uint64_t argument);

#endif /* ERX_FIASCO_TASK_START_H */
