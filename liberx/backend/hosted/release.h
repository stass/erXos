/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_HOSTED_RELEASE_H
#define ERX_HOSTED_RELEASE_H

typedef enum erx_hosted_release {
	ERX_HOSTED_RELEASE_NONE,	/* the run names no archive */
	ERX_HOSTED_RELEASE_MAPPED,	/* erx_release_entry now answers */
	ERX_HOSTED_RELEASE_REFUSED	/* *reason names the check */
} erx_hosted_release_t;

erx_hosted_release_t	erx_hosted_release_map(const char **);

#endif /* ERX_HOSTED_RELEASE_H */
