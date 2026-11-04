/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_CACHE_H
#define ERX_FIASCO_CACHE_H

#include <stddef.h>
#include <stdint.h>

/* After this returns, every CPU's next fetch from the range sees what was written to it. */
void	erx_fiasco_cache_make_coherent(uintptr_t start, size_t size);

#endif /* ERX_FIASCO_CACHE_H */
