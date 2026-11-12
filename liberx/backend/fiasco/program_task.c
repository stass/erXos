/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A session's program as a task (docs/design-programs.md, "Starting a program", step 9):
 * the first thread hands its argument registers, the values of the program's install, to
 * liberx's program layer, and musl's start enters the layer's start-up, which calls the
 * program's main once its startup message is accepted. main's status stops the task, and
 * the session's fault gate reads it. What the program prints goes to the system console
 * unchanged, through the service, as libc_task.c's does: a program's descriptors are its
 * startup message's, and the console stands in for them until they are built.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/program/program.h"

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_task_write(bytes, length);
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	erx_prog_enter(args);
	erx_fiasco_libc_start(liberx_program_main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
