/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PACK_H
#define ERX_PACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

typedef struct erx_pack_error erx_pack_error_t;
typedef struct erx_pack_scratch erx_pack_scratch_t;
typedef struct erx_pack_view erx_pack_view_t;

struct erx_pack_error {
	const char	*reason;
	uint32_t	 entry;
};

/* Caller-owned workspace; no input-sized array lives on a kernel stack. */
struct erx_pack_scratch {
	uint32_t	pending[ERX_PACK_PATH_MAX];
};

/* Successful views borrow bytes kept immutable for the view's lifetime. */
struct erx_pack_view {
	const uint8_t	*bytes;
	size_t		 length;
	erx_pack_header_t header;
};

bool erx_pack_open(const uint8_t *, size_t, erx_pack_scratch_t *,
    erx_pack_view_t *, erx_pack_error_t *);
bool erx_pack_entry_at(const erx_pack_view_t *, uint32_t,
    erx_pack_entry_t *);
bool erx_pack_path_at(const erx_pack_view_t *, uint32_t,
    const uint8_t **, size_t *);

#endif /* ERX_PACK_H */
