/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_ENTROPY_READ_H
#define ERX_BACKEND_ENTROPY_READ_H

#include <stdint.h>

#include "erx/cdefs.h"

/*
 * The backend's read of the generator, private to its one funnel. liberx/backend/api.h
 * offers erx_entropy_take alone, so a caller that names this read without this header
 * fails to build; the entropy-take chokepoint (tools/lib/erx/chokepoint_rules/entropy.rb)
 * keeps this header and the name to erx_entropy_take, the two backends that define the
 * read and the function-API set that tests it.
 *
 * At most ERX_ENTROPY_BYTES_MAX bytes a call, at the head of the caller's UTCB's mr, packed
 * from each word's low byte, where they stay until something overwrites them. A read
 * touches no byte past len, and after a read that fails mr's first len bytes hold none of
 * this read's bytes: they are zero, or as they were. More bytes is ERX_EINVAL. What the
 * bytes are worth natively, the root's banner line says.
 */
int	erx_entropy_read(uint32_t len) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_BACKEND_ENTROPY_READ_H */
