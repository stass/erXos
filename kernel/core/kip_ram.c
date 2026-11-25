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
 * The length of [start, end] is end - start + 1. The whole address space has a length
 * no entry holds, and a range whose end lies below its start has none, so a descriptor
 * with either range is refused as an overflow, never shortened. An `ignored` descriptor
 * takes no part in the map, so its range is not judged.
 */
erx_ram_map_status_t
erx_kip_ram_entry(uint64_t lo, uint64_t hi, erx_ram_entry_t *entry)
{
	uint64_t start = lo & ~KIP_ADDR_LOW, end = hi | KIP_ADDR_LOW;
	erx_ram_class_t ram_class = kip_class(lo);

	if (ram_class != ERX_RAM_CLASS_IGNORED && (end < start || end - start == UINT64_MAX))
		return (ERX_RAM_MAP_OVERFLOW);
	*entry = (erx_ram_entry_t){ .base = start, .length = end - start + 1, .ram_class = ram_class };
	return (ERX_RAM_MAP_OK);
}
