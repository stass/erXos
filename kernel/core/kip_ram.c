/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/core/kip_ram.h"

/* Fiasco's Mem_desc fields and values (fiasco/kernel/src/abi/kip.cpp). */
#define	KIP_ADDR_LOW		UINT64_C(0x3ff)
#define	KIP_TYPE(lo)		((lo) & 0x0f)
#define	KIP_SUB_TYPE(lo)	(((lo) >> 4) & 0x0f)
#define	KIP_VIRTUAL		UINT64_C(0x200)

enum {
	KIP_UNDEFINED		= 0x0,
	KIP_CONVENTIONAL	= 0x1,
	KIP_RESERVED		= 0x2,
	KIP_DEDICATED		= 0x3,
	KIP_KERNEL_TMP		= 0x7,
	KIP_BOOTLOADER		= 0xe,
};

enum {
	KIP_RESERVED_KERNEL	= 0,
	KIP_RESERVED_HEAP	= 1,
};

static erx_ram_class_t
kip_class(uint64_t lo)
{
	if ((lo & KIP_VIRTUAL) != 0)
		return (ERX_RAM_CLASS_IGNORED);
	switch (KIP_TYPE(lo)) {
	case KIP_UNDEFINED:
		return (ERX_RAM_CLASS_IGNORED);
	case KIP_CONVENTIONAL:
		return (ERX_RAM_CLASS_RAM);
	case KIP_RESERVED:
		return (KIP_SUB_TYPE(lo) == KIP_RESERVED_KERNEL || KIP_SUB_TYPE(lo) == KIP_RESERVED_HEAP ?
		    ERX_RAM_CLASS_USED : ERX_RAM_CLASS_EXCLUDED);
	case KIP_DEDICATED:
	case KIP_KERNEL_TMP:
	case KIP_BOOTLOADER:
		return (ERX_RAM_CLASS_USED);
	default:
		return (ERX_RAM_CLASS_EXCLUDED);
	}
}

/*
 * The length of [start, end] is end - start + 1, which only the whole address space
 * cannot hold; it is then one byte short, which moves no page of an entry rounded
 * outward and drops only the top page of one rounded inward. An end below the start
 * wraps to a length that, from a start above zero, the map refuses as an overflow.
 */
erx_ram_entry_t
erx_kip_ram_entry(uint64_t lo, uint64_t hi)
{
	uint64_t start = lo & ~KIP_ADDR_LOW, end = hi | KIP_ADDR_LOW;
	uint64_t span = end - start;

	return ((erx_ram_entry_t){
		.base = start,
		.length = span == UINT64_MAX ? span : span + 1,
		.ram_class = kip_class(lo),
	});
}
