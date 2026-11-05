/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * ERTS's link name that has no native body. Making an executor says so on the console
 * and fails, so a boot that reaches it stops with the reason.
 */

#include <errno.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/pthread_executor.h"

int
erx_pthread_create_executor(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg)
{
	static const char line[] = "erx: erx_pthread_create_executor has no native body\n";

	(void)thread;
	(void)attr;
	(void)start;
	(void)arg;
	erx_fiasco_console_write(line, sizeof(line) - 1);
	return (ENOSYS);
}
