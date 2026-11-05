/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A new thread over liberx (docs/design-stopgap.md, "Thread creation"). Only
 * pthread_create's clone is offered: a thread in this task. Its starting registers go
 * in the caller's public UTCB, which erx_thread_create reads. Its word to clear and its
 * identifier are set before the start, since it can exit as soon as it runs.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <sched.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "pthread_impl.h"

#include "erx/abi.h"
#include "liberx/backend/fiasco/thread.h"

int
__clone(int (*func)(void *), void *stack, int flags, void *arg, ...)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	va_list list;
	pid_t *tid_word;
	void *tls;
	volatile int *clear_word;
	int status;

	if (!(flags & CLONE_THREAD))
		return (-ENOSYS);
	va_start(list, arg);
	tid_word = va_arg(list, pid_t *);
	tls = va_arg(list, void *);
	clear_word = va_arg(list, volatile int *);
	va_end(list);

	start.regs.gpr[0] = (uint64_t)(uintptr_t)arg;
	start.regs.sp = (uint64_t)(uintptr_t)stack & ~UINT64_C(15);
	start.regs.pc = (uint64_t)(uintptr_t)func;
	start.tls = (uint64_t)(uintptr_t)tls;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, 0, 0, (flags & ERX_CLONE_EXECUTOR) ? ERX_THREAD_CLASS_EXECUTOR : ERX_THREAD_CLASS_WORKER,
	    &thread);
	if (status != ERX_OK)
		return (-EAGAIN);
	status = erx_fiasco_thread_set_clear_word(thread, (uint64_t)(uintptr_t)clear_word);
	if (status != ERX_OK)
		return (-EAGAIN);
	*tid_word = (pid_t)thread + 1;
	status = erx_thread_start(thread);
	return (status == ERX_OK ? (int)thread + 1 : -EAGAIN);
}
