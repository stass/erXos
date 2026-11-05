/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The first thread of a root task linked with musl: the service, then the program. */

#include <stddef.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/service.h"

void	erx_fiasco_root_main(void);

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_console_write(bytes, length);
}

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0);

	if (reason != NULL) {
		size_t length = 0;

		while (reason[length] != '\0')
			length++;
		erx_fiasco_console_write(reason, length);
		erx_fiasco_machine_off();
	}
	erx_fiasco_libc_start();
	erx_fiasco_machine_off();
}
