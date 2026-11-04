/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_RANGE_H
#define ERX_CORE_BOOT_RANGE_H

#include <stdint.h>

/* A physical range [start, start + size). */
typedef struct erx_boot_range erx_boot_range_t;

struct erx_boot_range {
	uint64_t	start;
	uint64_t	size;
};

#endif /* ERX_CORE_BOOT_RANGE_H */
