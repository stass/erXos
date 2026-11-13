/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's test program linked with musl: main's exit status stops the task, and
 * whoever started it, the launcher's join for libc-test's programs, reads that; a
 * session's programs enter through program_task.c instead. What it prints
 * goes to the system console unchanged, through the service, not to a session's tty,
 * so only test programs use this entry. It is started with 0 and reads no boot information page; a domain's
 * runtime, which does, enters through domain_entry.c instead.
 */

#include <stdbool.h>
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

/* No descriptor table: musl's own rows answer every call (libc_start.h). */
bool
erx_fiasco_libc_fd(long n, const long args[6], long *result)
{
	(void)n;
	(void)args;
	(void)result;
	return (false);
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	(void)args;
	erx_fiasco_libc_start(main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
