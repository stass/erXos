/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A new thread's first instructions (docs/design-stopgap.md, "Thread creation").
 * The kernel's start call carries an instruction pointer and a stack pointer and
 * no thread pointer, so the service starts every thread here with the stack
 * pointer holding its record. This stores the record where erx_utcb_self finds
 * it, sets the marker that says the kernel holds this UTCB, and takes the stack,
 * thread pointer and argument from the record's starting registers.
 */

#include "liberx/backend/fiasco/thread_offsets.h"

	.text
	.global	erx_fiasco_thread_trampoline
	.type	erx_fiasco_thread_trampoline, %function
erx_fiasco_thread_trampoline:
	mov	x9, sp
	mrs	x10, tpidrro_el0
	str	x9, [x10, #ERX_FIASCO_NATIVE_OFF_RECORD]
	mov	x11, #1
	str	x11, [x10, #ERX_FIASCO_NATIVE_OFF_MARKER]
	ldr	x11, [x9, #ERX_FIASCO_RECORD_OFF_SP]
	mov	sp, x11
	ldr	x11, [x9, #ERX_FIASCO_RECORD_OFF_TLS]
	msr	tpidr_el0, x11
	ldr	x0, [x9, #ERX_FIASCO_RECORD_OFF_ARG]
	ldr	x11, [x9, #ERX_FIASCO_RECORD_OFF_PC]
	br	x11
	.size	erx_fiasco_thread_trampoline, . - erx_fiasco_thread_trampoline

	.global	erx_fiasco_thread_pointer
	.type	erx_fiasco_thread_pointer, %function
erx_fiasco_thread_pointer:
	mrs	x0, tpidr_el0
	ret
	.size	erx_fiasco_thread_pointer, . - erx_fiasco_thread_pointer
