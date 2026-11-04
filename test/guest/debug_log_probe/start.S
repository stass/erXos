/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task's entry: the kernel starts it with no stack. Then the two
 * calls only assembly can make: one with exactly the given register values,
 * and one that checks what the kernel keeps. x8 holds the call number and
 * x0 to x5 the arguments; x0 to x2 come back as the status and results.
 */

	.text
	.global	_start
	.type	_start, %function
_start:
	adrp	x0, probe_stack_top
	add	x0, x0, :lo12:probe_stack_top
	mov	sp, x0
	bl	erx_probe_main
1:	b	1b
	.size	_start, . - _start

/* void erx_probe_raw_call(number, const args[6], results[3]) */
	.global	erx_probe_raw_call
	.type	erx_probe_raw_call, %function
erx_probe_raw_call:
	str	x2, [sp, #-16]!
	mov	x8, x0
	mov	x9, x1
	ldp	x0, x1, [x9, #0]
	ldp	x2, x3, [x9, #16]
	ldp	x4, x5, [x9, #32]
	svc	#0x4552
	ldr	x9, [sp], #16
	stp	x0, x1, [x9, #0]
	str	x2, [x9, #16]
	ret
	.size	erx_probe_raw_call, . - erx_probe_raw_call

/* Counts into x0 the register that no longer holds its known value. */
	.macro	changed register, value
	mov	x1, #\value
	cmp	\register, x1
	cinc	x0, x0, ne
	.endm

/* uint64_t erx_probe_preserved_changes(debug_log_number) */
	.global	erx_probe_preserved_changes
	.type	erx_probe_preserved_changes, %function
erx_probe_preserved_changes:
	stp	x29, x30, [sp, #-112]!
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	stp	x23, x24, [sp, #48]
	stp	x25, x26, [sp, #64]
	stp	x27, x28, [sp, #80]
	str	x0, [sp, #96]
	mov	x8, x0
	mov	x0, xzr
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, #0xe503
	mov	x4, #0xe504
	mov	x5, #0xe505
	mov	x6, #0xe506
	mov	x7, #0xe507
	mov	x9, #0xe509
	mov	x10, #0xe50a
	mov	x11, #0xe50b
	mov	x12, #0xe50c
	mov	x13, #0xe50d
	mov	x14, #0xe50e
	mov	x15, #0xe50f
	mov	x16, #0xe510
	mov	x17, #0xe511
	mov	x18, #0xe512
	mov	x19, #0xe513
	mov	x20, #0xe514
	mov	x21, #0xe515
	mov	x22, #0xe516
	mov	x23, #0xe517
	mov	x24, #0xe518
	mov	x25, #0xe519
	mov	x26, #0xe51a
	mov	x27, #0xe51b
	mov	x28, #0xe51c
	mov	x29, #0xe51d
	mov	x30, #0xe51e
	svc	#0x4552
	mov	x0, xzr
	changed	x3, 0xe503
	changed	x4, 0xe504
	changed	x5, 0xe505
	changed	x6, 0xe506
	changed	x7, 0xe507
	changed	x9, 0xe509
	changed	x10, 0xe50a
	changed	x11, 0xe50b
	changed	x12, 0xe50c
	changed	x13, 0xe50d
	changed	x14, 0xe50e
	changed	x15, 0xe50f
	changed	x16, 0xe510
	changed	x17, 0xe511
	changed	x18, 0xe512
	changed	x19, 0xe513
	changed	x20, 0xe514
	changed	x21, 0xe515
	changed	x22, 0xe516
	changed	x23, 0xe517
	changed	x24, 0xe518
	changed	x25, 0xe519
	changed	x26, 0xe51a
	changed	x27, 0xe51b
	changed	x28, 0xe51c
	changed	x29, 0xe51d
	changed	x30, 0xe51e
	ldr	x1, [sp, #96]
	cmp	x8, x1
	cinc	x0, x0, ne
	ldp	x19, x20, [sp, #16]
	ldp	x21, x22, [sp, #32]
	ldp	x23, x24, [sp, #48]
	ldp	x25, x26, [sp, #64]
	ldp	x27, x28, [sp, #80]
	ldp	x29, x30, [sp], #112
	ret
	.size	erx_probe_preserved_changes, . - erx_probe_preserved_changes

	.bss
	.balign	16
	.space	16384
probe_stack_top:
