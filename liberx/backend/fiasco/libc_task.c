/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's program linked with musl: main's exit status stops the task, and the
 * launcher's join reads it. The root's argument has no reader, as a program takes
 * only what musl's start hands main.
 */

#include <stdint.h>

#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/task_start.h"

int64_t
erx_task_main(uint64_t argument)
{
	(void)argument;
	erx_fiasco_libc_start();
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
