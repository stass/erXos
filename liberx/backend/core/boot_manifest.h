/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_MANIFEST_H
#define ERX_BACKEND_BOOT_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"

/*
 * What of the system manifest reaches the boot information page, the same on both
 * entries (docs/design-stopgap.md, "Boot information"): the node name, the system's
 * arguments and the projection of system_runtime_limits. Pure, over the bytes handed in.
 */

/* system@, then an identifier of at most 63 bytes. */
#define ERX_BOOT_NODE_MAX	(sizeof("system@") - 1 + 63)

typedef struct erx_boot_manifest {
	char			node[ERX_BOOT_NODE_MAX];
	size_t			node_len;
	erx_boot_words_t	system_args;	/* points into the manifest's bytes */
	erx_runtime_limits_t	limits;
} erx_boot_manifest_t;

/* Fills *result, or returns false and names the check that refused the bytes in *reason. */
bool	erx_boot_manifest_read(const uint8_t *bytes, size_t length, erx_boot_manifest_t *result,
	    const char **reason);

#endif /* ERX_BACKEND_BOOT_MANIFEST_H */
