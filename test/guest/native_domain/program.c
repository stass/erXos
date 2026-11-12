/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The tiny native program a domain of the native_domain suite runs
 * (test/guest/native_domain/guest.c). Its first thread's argument is its boot
 * page's address; the page's first argument word says what to do: "halt"
 * returns HALT_STATUS once the page reads as a domain's, "fault" stores
 * through a null pointer, and "wait" sleeps until its domain is stopped.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/task_start.h"
#include "test/guest/native_domain/modes.h"

/* Whether the release slice, mapped at the boot page's address, begins with RELEASE_TEXT. */
static bool
release_reads(const erx_boot_info_t *info)
{
	const char *text = (const char *)(uintptr_t)info->release_addr;

	if (info->release.raw == ERX_CAP_NULL || text == NULL)
		return (false);
	for (size_t at = 0; RELEASE_TEXT[at] != '\0'; at++)
		if (text[at] != RELEASE_TEXT[at])
			return (false);
	return (true);
}

static bool
word_is(const char *word, const char *text)
{
	size_t at = 0;

	for (; text[at] != '\0'; at++)
		if (word[at] != text[at])
			return (false);
	return (word[at] == '\0');
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	const uint64_t argument = args[0];
	const erx_boot_info_t *info = (const erx_boot_info_t *)(uintptr_t)argument;
	const char *word = (const char *)(uintptr_t)(argument + info->args_off);
	static _Atomic uint32_t never;

	if (info->version != ERX_BOOT_VERSION || info->domain_id <= 4 || info->args_len == 0 ||
	    info->budget.raw == ERX_CAP_NULL || info->time_page.raw == ERX_CAP_NULL || !release_reads(info))
		return (BAD_PAGE_STATUS);
	if (word_is(word, "halt"))
		return (HALT_STATUS);
	if (word_is(word, "fault"))
		*(volatile uint64_t *)(uintptr_t)0 = 1;
	for (;;)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, ERX_WAIT_FOREVER);
}
