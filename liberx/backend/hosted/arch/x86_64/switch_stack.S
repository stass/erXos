/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_hosted_switch_stack(sp, fn, arg, saved_sp): a thread's start switches from the
 * pthread's stack to the one its start record names, and its exit switches back.
 * C cannot say this. Darwin's symbols take a leading underscore.
 *
 * Every host's file is built; the preprocessor keeps the one body the compiler
 * targets, so a host without one fails at the link, not before.
 *
 * The saved value is the caller's stack pointer, above the return address the
 * call pushed, so it is 16-byte aligned like every sp handed in; the call below
 * then enters fn with the alignment the ABI promises. A zero frame pointer ends
 * the frame chain there, so no unwinder (the address sanitizer's included) walks
 * into the abandoned stack, which the exit path releases.
 */

#if defined(__x86_64__)
	.text
	.globl	_erx_hosted_switch_stack
	.p2align 4
_erx_hosted_switch_stack:
	leaq	8(%rsp), %rax
	movq	%rax, (%rcx)
	movq	%rdi, %rsp
	movq	%rdx, %rdi
	xorl	%ebp, %ebp
	callq	*%rsi
	ud2
#endif
