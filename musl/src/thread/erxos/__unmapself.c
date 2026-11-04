/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>

#include "pthread_impl.h"

/* liberx's private exit: the reaper releases this range once the thread cannot run. */
_Noreturn void erx_thread_exit_release(uint64_t, uint64_t);

void
__unmapself(void *base, size_t size)
{
	erx_thread_exit_release((uint64_t)(uintptr_t)base, size);
}
