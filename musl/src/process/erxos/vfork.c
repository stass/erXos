/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <errno.h>
#include <unistd.h>

#include "syscall.h"

/* The personality's second tier writes this for programs; a runtime has no processes. */
pid_t
vfork(void)
{
	return (__syscall_ret(-ENOSYS));
}
