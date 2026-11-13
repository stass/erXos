/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A root writes its standard output and standard error to the console itself. Alone in
 * its file: musl refers to this from every stdio call, and a program links liberxroot.a
 * ahead of its own objects, so a member here that reached the start path would bring
 * runtime_main.c's main ahead of the program's.
 */

#include <stdbool.h>
#include <stddef.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/libc_start.h"

void
erx_fiasco_libc_write(const void *bytes, size_t length)
{
	erx_fiasco_console_write(bytes, length);
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
