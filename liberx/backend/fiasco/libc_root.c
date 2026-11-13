/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The first thread of a test's root task linked with musl: bring the service up, then
 * run the program's main. There is no archive and no boot information page.
 */

#include <stddef.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"

void	erx_fiasco_root_main(void);
int	main(int, char **, char **);

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0, 0);

	if (reason != NULL) {
		size_t length = 0;

		while (reason[length] != '\0')
			length++;
		erx_fiasco_console_write(reason, length);
		erx_fiasco_machine_off();
	}
	erx_fiasco_libc_root_start(main);
}
