/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_PAIR_H
#define ERX_CORE_BOOT_PAIR_H

/*
 * The boot value and its slot (docs/design-kernel.md, "The root task"): a
 * boot_value and a boot_slot of abi/kernel.txt, which the machine page, the
 * crash record and bootstrap's handoff record each carry. The one rule for a
 * pair is here: unknown goes with slot none, and normal and trial with slot
 * a or b; a reader refuses any other pair. A header of include/erx/core/ is
 * the seam between the C17 cores and Fiasco, so it compiles as C17 and as
 * C++ and includes only the freestanding headers and this directory.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/abi_crash.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct erx_boot_pair erx_boot_pair_t;

struct erx_boot_pair {
	uint32_t	value;	/* a boot_value */
	uint32_t	slot;	/* a boot_slot */
};

/* Whether value and slot form a pair a reader accepts. */
static inline bool
erx_boot_pair_valid(uint32_t value, uint32_t slot)
{
	switch (value) {
	case ERX_BOOT_VALUE_UNKNOWN:
		return (slot == ERX_BOOT_SLOT_NONE);
	case ERX_BOOT_VALUE_NORMAL:
	case ERX_BOOT_VALUE_TRIAL:
		return (slot == ERX_BOOT_SLOT_A || slot == ERX_BOOT_SLOT_B);
	default:
		return (false);
	}
}

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_BOOT_PAIR_H */
