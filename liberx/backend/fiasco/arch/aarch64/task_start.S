/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's ELF entry. The service starts its first thread here with the stack pointer
 * holding the record (docs/design-stopgap.md, "Thread creation"), as it starts every
 * thread at the trampoline. Only the task's image knows its stack and its C entry, so
 * these go in the record, and the trampoline does the rest; the argument is the root's.
 */

#include "liberx/backend/fiasco/thread_offsets.h"

	.text
	.global	_start
	.type	_start, %function
_start:
	mov	x9, sp
	adrp	x10, task_stack_top
	add	x10, x10, :lo12:task_stack_top
	str	x10, [x9, #ERX_FIASCO_RECORD_OFF_SP]
	adrp	x10, erx_fiasco_task_main
	add	x10, x10, :lo12:erx_fiasco_task_main
	str	x10, [x9, #ERX_FIASCO_RECORD_OFF_PC]
	b	erx_fiasco_thread_trampoline
	.size	_start, . - _start

	/* A musl program's main runs here, and its frames are not small. No guard page: see TODO.md. */
	.bss
	.balign	16
	.space	262144
task_stack_top:
