/* Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff"). */
/*
 * Copyright (C) 2008-2009 Technische Universität Dresden.
 * Author(s): Adam Lackorzynski <adam@os.inf.tu-dresden.de>
              Frank Mehnert <fm3@os.inf.tu-dresden.de>
 *
 * License: see LICENSE.spdx (in this directory or the directories above)
 */
/* -*- c -*- */

/*
 * The boot protocol's header and erXos's locator (abi/arch/aarch64.txt,
 * erx_arch_boot_header and erx_boot_locator; docs/design-arch-aarch64.md, "Boot
 * entry"). tools/lib/erx/boot_file.rb decodes them against the ABI and refuses
 * a first stage whose fields disagree. text_offset 0, and QEMU's loader moves an
 * image that would meet its own stub up by 2 MiB, to bootstrap's link address.
 */
.section .text.init,"ax"
.type _start,#function
.globl _start
_start:
	b	10f
	.4byte	0
	.8byte	0			/* text_offset */
	.globl	erx_boot_declared_size
erx_boot_declared_size:
	.8byte	__erx_image_size	/* image_size, covering .bss as built */
	.8byte	0xa			/* flags: LE, 4 KiB pages, anywhere */
	.8byte	0, 0, 0			/* reserved */
	.ascii	"ARM\x64"		/* magic */
	.4byte	0			/* reserved */
	.globl	erx_boot_locator
erx_boot_locator:
	.ascii	"ERXBOOT\0"		/* magic */
	.4byte	1			/* version */
	.4byte	0			/* zero */
	.8byte	0			/* archive_off; the packer writes it */
	.8byte	0			/* archive_size; the packer writes it */
10:
	/*
	 * bootstrap runs only at its link address: moving itself would copy its
	 * image before the archive is validated and could copy it over the
	 * archive. A loader that placed it elsewhere stops here.
	 */
	adr	x4, _start
	ldr	x5, .LCstart
	cmp	x4, x5
	b.eq	run
11:	wfe
	b	11b

	.align 3
.LCstart:	.8byte _start

run:
	b	platform_cpu_bootup

.type platform_cpu_bootup, #function
.weak platform_cpu_bootup
platform_cpu_bootup:
	/* Can be overridden by platform for special MP boot */

.global do_bootstrap
.type do_bootstrap, #function
do_bootstrap:
	adrp	x9, crt0_stack_high
	add	x9, x9, :lo12:crt0_stack_high
	mov	sp, x9

	mrs	x8, cpacr_el1
	orr	x8, x8, #0x300000 // fpen
	msr	cpacr_el1, x8

	bl	__main
1:	b	1b

.section ".bss"

	.global crt0_stack_low
	.align 4
crt0_stack_low:
	.space	16384
	.global crt0_stack_high
crt0_stack_high:
