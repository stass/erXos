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
#define ERX_BOOT_HANDOFF_RECORD_SIZE	2400

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
	/*
	 * The full path of the node /chosen/stdout-path names, as bootstrap
	 * resolved it: a '/' and node-name characters, empty when the tree
	 * names no node. Not NUL-terminated.
	 */
	const char	*stdout_path;
	uint32_t	 stdout_path_len;
};

/*
 * A node path as a device tree spells it: empty, or '/' and names of the
 * characters the specification allows (letters, digits, ",._+-" and '@'),
 * so nothing in it is a control, an escape or a byte outside ASCII. The
 * handoff's writer stores only such a path and its reader accepts only one.
 */
static inline bool
erx_boot_node_path_valid(const uint8_t *path, size_t length)
{
	if (length == 0)
		return (true);
	if (path[0] != '/')
		return (false);
	for (size_t at = 1; at < length; at++) {
		const uint8_t c = path[at];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		    (c >= '0' && c <= '9') || c == ',' || c == '.' || c == '_' ||
		    c == '+' || c == '-' || c == '@' || c == '/'))
			return (false);
	}
	return (true);
}

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
