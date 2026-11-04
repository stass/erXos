/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_hosted_switch_stack(sp, fn, arg, saved_sp): a thread's start switches from the
 * pthread's stack to the one its start record names, and its exit switches back.
 * C cannot say this. Darwin's symbols take a leading underscore.
 */

	.text
	.global	_erx_hosted_switch_stack
	.p2align 2
_erx_hosted_switch_stack:
	mov	x9, sp
	str	x9, [x3]
	mov	sp, x0
	mov	x0, x2
	mov	x29, xzr
	mov	x30, xzr
	blr	x1
	brk	#1
