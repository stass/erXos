/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The root task's fixed place in QEMU virt's RAM: bootstrap's load plan runs it
 * at the addresses its headers give, clear of bootstrap and the archive, and
 * sigma0 maps each of its pages at the same address. The ELF headers lead the
 * first page: a program linked with musl finds its TLS image through them. Each
 * segment starts on its own page, as the packer's ELF plan requires.
 */
ENTRY(_start)
SECTIONS {
	erx_fiasco_image_start = 0x44000000;
	. = 0x44000000 + SIZEOF_HEADERS;
	.rodata : { *(.rodata .rodata.*) }
	.note.erx.abi : { KEEP(*(.note.erx.abi)) }
	. = ALIGN(4096);
	.text : { *(.text .text.*) }
	. = ALIGN(4096);
	.init_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*) .init_array)) }
	.fini_array : { KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*) .fini_array)) }
	.tdata : { *(.tdata .tdata.*) }
	.tbss : { *(.tbss .tbss.*) }
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.* COMMON) }
	. = ALIGN(4096);
	erx_fiasco_image_end = .;
	/DISCARD/ : { *(.comment .note .note.*) }
}
