/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's program linked with musl: main's exit status stops the task, and the
 * launcher's join reads it. What it prints goes to the console unchanged, through
 * the service. Its first thread's argument is the address of its boot information
 * page, which its creator mapped read-only (docs/design-stopgap.md, "Boot
 * information"); a runtime's start checks the page with erx_boot_info_read and ends
 * the task with the reader's reason when it refuses. A test program, started with 0,
 * reads none.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/runtime_entry.h"

int	main(int, char **, char **);

/*
 * A page of zeros stands in for an argument that names no page, so the reader refuses it
 * with its diagnostic rather than the runtime faulting on address 0.
 */
static _Alignas(ERX_PAGE_SIZE) const unsigned char no_boot_page[ERX_PAGE_SIZE];
/* Set by the first thread before musl's start runs, and never again. */
static const erx_boot_info_t *boot_page = (const erx_boot_info_t *)(const void *)no_boot_page;

const erx_boot_info_t *
erx_boot_info(void)
{
	return (boot_page);
}

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_task_write(bytes, length);
}

int64_t
erx_task_main(uint64_t argument)
{
	if (argument != 0 && argument % ERX_PAGE_SIZE == 0)
		boot_page = (const erx_boot_info_t *)(uintptr_t)argument;
	erx_fiasco_libc_start(main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}
