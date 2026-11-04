/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A cancellation point. No signal is delivered, so a thread blocked in a call is
 * not interrupted by pthread_cancel; it acts on the request at its next cancellation
 * point. The labels are what musl's cancel handler compares against, which never runs.
 */

#include "pthread_impl.h"
#include "syscall.h"

hidden long __cancel();
hidden long __syscall_cp_asm(volatile int *, syscall_arg_t, syscall_arg_t, syscall_arg_t, syscall_arg_t,
    syscall_arg_t, syscall_arg_t, syscall_arg_t);

__asm__(".hidden __cp_begin\n.hidden __cp_end\n.hidden __cp_cancel\n"
    ".global __cp_begin\n.global __cp_end\n.global __cp_cancel\n"
    ".text\n__cp_begin:\n__cp_end:\n__cp_cancel:\n");

long
__syscall_cp_asm(volatile int *cancel, syscall_arg_t nr, syscall_arg_t u, syscall_arg_t v, syscall_arg_t w,
    syscall_arg_t x, syscall_arg_t y, syscall_arg_t z)
{
	if (*cancel)
		return (__cancel());
	return (__syscall(nr, u, v, w, x, y, z));
}
