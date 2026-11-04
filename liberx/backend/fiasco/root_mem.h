/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ROOT_MEM_H
#define ERX_FIASCO_ROOT_MEM_H

#include <stddef.h>

/*
 * The memory primitives the backend's cores use, with the C library's contracts:
 * root_mem.c supplies them in the root task, which links no C library here, and
 * the host's C library supplies them when a core is built for its tests.
 */
void bcopy(const void *, void *, size_t);
void bzero(void *, size_t);

#endif /* ERX_FIASCO_ROOT_MEM_H */
