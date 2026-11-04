/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The root task's fixed place in QEMU virt's RAM: bootstrap's load plan runs it
 * at the addresses its headers give, clear of bootstrap and the archive, and
 * sigma0 maps each of its pages at the same address.
 */
ENTRY(_start)
SECTIONS {
	. = 0x44000000;
	.text : { *(.text .text.*) }
	. = ALIGN(4096);
	.rodata : { *(.rodata .rodata.*) }
	. = ALIGN(4096);
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment .note .note.*) }
}
