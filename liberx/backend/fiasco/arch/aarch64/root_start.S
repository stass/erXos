/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task's entry. The kernel starts it with a stack pointer of 0
 * (docs/design-stopgap.md, "Boot handoff"), so the first instructions set one
 * inside the image; touching it faults to sigma0, which maps it one to one.
 */

	.text
	.global	_start
	.type	_start, %function
_start:
	adrp	x0, root_stack_top
	add	x0, x0, :lo12:root_stack_top
	mov	sp, x0
	bl	erx_fiasco_root_main
1:	b	1b
	.size	_start, . - _start

/* void erx_fiasco_call_on_stack(void *top, void (*entry)(void)): moves to a stack for good. */
	.global	erx_fiasco_call_on_stack
	.type	erx_fiasco_call_on_stack, %function
erx_fiasco_call_on_stack:
	mov	sp, x0
	blr	x1
1:	b	1b
	.size	erx_fiasco_call_on_stack, . - erx_fiasco_call_on_stack

	.bss
	.balign	16
	.space	65536
root_stack_top:
