/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_MEM_H
#define ERX_BACKEND_MEM_H

#include <stddef.h>

/*
 * The memory primitives the backends' cores use, with the C library's contracts:
 * the Fiasco root task's root_mem.c supplies them where it links no C library, and
 * the host's C library supplies them for the hosted backend and for host tests.
 */
void bcopy(const void *, void *, size_t);
void bzero(void *, size_t);

#endif /* ERX_BACKEND_MEM_H */
