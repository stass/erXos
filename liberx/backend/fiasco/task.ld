/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A task's program: fixed addresses in the range table's area, past the thread
 * table's pages, with its file header and ABI note in the code segment, as
 * elf_plan.c asks, and each segment on a page of its own. A program linked with
 * musl finds its TLS image through the headers, and its constructors in .init_array.
 * musl sizes each thread's TLS from the tls segment, so that holds .tdata and .tbss and
 * nothing else. A section this script does not name would take the segments of the one before
 * it, so .got has its place ahead of them, and a task's link refuses an unnamed section
 * (NativeRoot::TASK_LINK_FLAGS).
 */
ENTRY(_start)
PHDRS {
	text PT_LOAD FILEHDR PHDRS FLAGS(5);
	rodata PT_LOAD FLAGS(4);
	data PT_LOAD FLAGS(6);
	tls PT_TLS FLAGS(4);
	note PT_NOTE FLAGS(4);
}
SECTIONS {
	. = 0x4000100000 + SIZEOF_HEADERS;
	.note.erx.abi : { KEEP(*(.note.erx.abi)) } :text :note
	.text : { *(.text .text.*) } :text
	. = ALIGN(4096);
	.rodata : { *(.rodata .rodata.*) } :rodata
	. = ALIGN(4096);
	.init_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*) .init_array)) } :data
	.fini_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*) .fini_array)) } :data
	.got : { *(.got .got.*) } :data
	.tdata : { *(.tdata .tdata.*) } :data :tls
	.tbss : { *(.tbss .tbss.*) } :data :tls
	.data : { *(.data .data.*) } :data
	.bss : { *(.bss .bss.* COMMON) } :data
	.symtab 0 : { *(.symtab) }
	.strtab 0 : { *(.strtab) }
	.shstrtab 0 : { *(.shstrtab) }
	/DISCARD/ : { *(.comment) *(.eh_frame*) *(.note.GNU-stack) *(.note.gnu.*) }
}
