/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A domain's runtime in a task, the task twin of runtime_entry.c (docs/design-stopgap.md,
 * "Boot information"). The domain library wrote the boot information page, mapped it
 * read-only and passed its address as the first thread's argument. Before musl's start
 * runs, this entry copies the page into the task's own memory, which nothing outside the
 * task writes, and checks the copy with the reader both entries share: a page it refuses
 * ends the task with the reader's reason on the console, and every later read, ERTS's
 * start reading the page again among them, sees the page that was checked. Then it enters
 * musl's start path, whose main is in runtime_main.c. What the runtime
 * prints goes to the console unchanged, through the service, until the log sink carries
 * its logger.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/runtime_entry.h"

int	main(int, char **, char **);

static void	say(const char *);

/* Written by the first thread before musl's start runs, and never again. */
static _Alignas(ERX_PAGE_SIZE) unsigned char boot_page[ERX_PAGE_SIZE];

const erx_boot_info_t *
erx_boot_info(void)
{
	return ((const erx_boot_info_t *)(const void *)boot_page);
}

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_task_write(bytes, length);
}

/*
 * argument is the page's address. An address that names no page is refused before
 * anything reads through it; the reader then checks the copy's every field and string.
 * The view it fills is not kept: erx_runtime_main reads the copy again for ERTS.
 */
int64_t
erx_task_main(uint64_t argument)
{
	const unsigned char *const page = (const unsigned char *)(uintptr_t)argument;
	erx_boot_view_t view;
	erx_boot_info_status_t status;

	if (argument == 0 || argument % ERX_PAGE_SIZE != 0) {
		say("erx: the boot information page: the first thread's argument names no page\n");
		return (ERX_FIASCO_TASK_STATUS_BOOT_PAGE);
	}
	for (size_t at = 0; at < ERX_PAGE_SIZE; at++)
		boot_page[at] = page[at];
	status = erx_boot_info_read(boot_page, ERX_PAGE_SIZE, &view);
	if (status != ERX_BOOT_INFO_OK) {
		say("erx: the boot information page: ");
		say(erx_boot_info_reason(status));
		say("\n");
		return (ERX_FIASCO_TASK_STATUS_BOOT_PAGE);
	}
	erx_fiasco_libc_start(main);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}

/*
 * Each reason is a fixed ASCII string of the reader's, so it reaches the console as it is.
 * The image's freestanding sources have no <string.h>, hence the loop.
 */
static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != 0)
		length++;
	erx_fiasco_task_write(text, length);
}
