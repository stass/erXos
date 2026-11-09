/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's test program linked with musl: main's exit status stops the task, and the
 * launcher's join reads it. What it prints goes to the console unchanged, through
 * the service. It is started with 0 and reads no boot information page; a domain's
 * runtime, which does, enters through domain_entry.c instead.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"

int	main(int, char **, char **);

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_task_write(bytes, length);
}

int64_t
erx_task_main(uint64_t argument)
{
	(void)argument;
	erx_fiasco_libc_start(main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
