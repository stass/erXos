/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_KIP_RAM_H
#define ERX_CORE_KIP_RAM_H

#include <stdint.h>

#include "erx/core/machine_stop.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The Fiasco fork's table for the readable-RAM map (docs/design-debugger.md, "On
 * Fiasco", "The hold's map"): one memory descriptor of the kernel information page,
 * its two words as Fiasco stores them, as an entry of the boot map
 * erx_machine_stop_ram_map takes.
 *
 * The descriptor's layout is Fiasco's (fiasco/kernel/src/abi/kip.cpp, Mem_desc): the
 * first word holds the start in its bits from 10 up, the type in bits 0-3, the
 * sub-type in bits 4-7 and the virtual flag in bit 9; the second holds the end, its
 * low ten bits read as ones.
 *
 * Any virtual descriptor and `Undefined` are `ignored`; physical `Conventional` is
 * `ram`; `Reserved` of sub-type `Reserved_kernel` or `Reserved_heap`, `Kernel_tmp`,
 * `Dedicated` and `Bootloader` are `used`; every other type or sub-type is `excluded`.
 * The entry is stored only for ERX_RAM_MAP_OK. A descriptor that is not `ignored` and
 * whose end lies below its start, or that spans the whole address space, has a length
 * no entry holds: it is refused with ERX_RAM_MAP_OVERFLOW, the reason the glue then
 * gives for refusing the map, never shortened. An `ignored` one takes no part in the
 * map whatever its range.
 */
erx_ram_map_status_t	erx_kip_ram_entry(uint64_t lo, uint64_t hi, erx_ram_entry_t *entry);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_KIP_RAM_H */
