/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_RELEASE_H
#define ERX_RELEASE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The one reader of the boot archive's index above the checks of erx_pack_open
 * (design-runtime.md, Files, and design-stopgap.md, the call table). Everything
 * else learns the release from these entries, so erXos's kernel, which keeps
 * the index unmapped, changes only what is behind this call.
 */

typedef struct erx_release_entry {
	uint64_t	size;
	uint64_t	offset;		/* from erx_release_addr() */
	size_t		path_length;
	uint8_t		path[ERX_PACK_PATH_MAX];	/* with no `system/` and no NUL */
} erx_release_entry_t;

/*
 * Checks the archive with erx_pack_open, and that erx_ns_resolve can reach each
 * file of the release, and keeps it as this domain's release.
 * The bytes stay immutable and mapped for the domain's life. Called once, before
 * any thread reads the release. Returns 0, or ERX_EINVAL with the name of the
 * check that refused it in *reason.
 */
int		erx_release_bind(const uint8_t *, size_t, const char **);
/* The index-th file of the release, in sorted order; past the run, ERX_ERANGE. */
int		erx_release_entry(uint64_t, erx_release_entry_t *);
const uint8_t	*erx_release_addr(void);
/*
 * The system manifest's bytes, after the one file check of its run, hash and the build
 * kind it carries. Returns 0, or ERX_EINVAL with the name of the check in *reason.
 */
int		erx_release_manifest(const uint8_t **, size_t *, const char **);
/* The archive header's flags. */
uint32_t	erx_release_pack_flags(void);

#endif /* ERX_RELEASE_H */
