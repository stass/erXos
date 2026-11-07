/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The root task's fixed place in QEMU virt's RAM: bootstrap's load plan runs it
 * at the addresses its headers give, clear of bootstrap and the archive, and
 * sigma0 maps each of its pages at the same address. The ELF headers lead the
 * first page: a program linked with musl finds its TLS image through them. Each
 * segment starts on its own page, as the packer's ELF plan requires.
 *
 * The place is 192 MiB into RAM, 0x4c000000. In the single-file form bootstrap
 * loads at 0x40200000 with the archive behind it, and QEMU puts the 1 MiB device
 * tree at 0x48000000 or, for a longer file, at the next 2 MiB boundary behind it
 * (docs/research-baselines.md, "Boot conventions"). So the file may run to
 * 0x4be00000, about 188 MiB, and the archive in it to about 187 MiB, on every
 * machine of 256 MiB or more. In the two-file form the archive starts at
 * 0x48000000 with the device tree behind it, so it must stay under about 63 MiB.
 * The root's image, about 5 MiB, must end inside a 256 MiB machine's RAM
 * (0x50000000): on that machine the production boot check expects the root
 * itself, not bootstrap's place_outside_memory, to refuse the boot
 * (ProductionImage::TOO_LITTLE_MEMORY_MIB).
 */
ENTRY(_start)
SECTIONS {
	erx_fiasco_image_start = 0x4c000000;
	. = erx_fiasco_image_start + SIZEOF_HEADERS;
	.rodata : { *(.rodata .rodata.*) }
	.note.erx.abi : { KEEP(*(.note.erx.abi)) }
	. = ALIGN(4096);
	.text : { *(.text .text.*) }
	. = ALIGN(4096);
	.got : { *(.got .got.*) }
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
