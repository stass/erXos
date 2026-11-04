/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The probe's fixed place in QEMU virt's RAM, clear of bootstrap's modules:
 * bootstrap loads the root task at the addresses its headers give, and the
 * root pager maps each page where it finds it.
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
