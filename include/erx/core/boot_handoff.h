/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_HANDOFF_H
#define ERX_CORE_BOOT_HANDOFF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/boot_range.h"

/*
 * What the kernel accepts from bootstrap (docs/design-stopgap.md, "The handoff
 * record"). The record lives in the kernel's own image, which only bootstrap
 * wrote before the kernel ran; these checks catch a first stage and a kernel
 * built apart, and a boot that skipped bootstrap's validator, whose record is
 * all zeros.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* The size of the record Fiasco's options block embeds. */
#define ERX_BOOT_HANDOFF_RECORD_SIZE	2136

typedef struct erx_boot_handoff_view erx_boot_handoff_view_t;

struct erx_boot_handoff_view {
	uint32_t	 flags;
	bool		 development;
	uint8_t		 build_id[8];
	uint8_t		 index_hash[32];
	erx_boot_range_t image;
	uint64_t	 pool_usable;
	uint64_t	 pool_heap;
	uint32_t	 pool_regions;
	const char	*bootargs;
	uint32_t	 bootargs_len;
};

/* Returns NULL when the record is good, else the check that failed. */
const char *erx_boot_handoff_accept(const uint8_t *, size_t,
    erx_boot_handoff_view_t *);

/* Whether one of the ranges covers the archive whole. */
bool erx_boot_handoff_covered(const erx_boot_handoff_view_t *,
    const erx_boot_range_t *, size_t);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_BOOT_HANDOFF_H */
