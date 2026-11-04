/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A task's program: fixed addresses in the range table's area, past the thread
 * table's pages, with its file header and ABI note in the code segment, as
 * elf_plan.c asks, and each segment on a page of its own.
 */
ENTRY(_start)
PHDRS {
	text PT_LOAD FILEHDR PHDRS FLAGS(5);
	rodata PT_LOAD FLAGS(4);
	data PT_LOAD FLAGS(6);
	note PT_NOTE FLAGS(4);
}
SECTIONS {
	. = 0x4000100000 + SIZEOF_HEADERS;
	.note.erx.abi : { KEEP(*(.note.erx.abi)) } :text :note
	.text : { *(.text .text.*) } :text
	. = ALIGN(4096);
	.rodata : { *(.rodata .rodata.*) } :rodata
	. = ALIGN(4096);
	.data : { *(.data .data.*) } :data
	.bss : { *(.bss .bss.* COMMON) } :data
	/DISCARD/ : { *(.comment) *(.eh_frame*) *(.note.GNU-stack) }
}
