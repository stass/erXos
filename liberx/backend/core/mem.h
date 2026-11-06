/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_MEM_H
#define ERX_BACKEND_MEM_H

#include <stddef.h>

/*
 * The memory primitives the backends' cores and the device NIF use, with the C
 * library's contracts: the Fiasco root task's root_mem.c supplies them where it
 * links no C library (the native_irq root links the device NIF's C), and the C
 * library supplies them for ERTS, the hosted backend and host tests. The names
 * are parenthesized so a C library that defines them as macros, as macOS's
 * fortified <strings.h> does, leaves these declarations alone.
 */
void (bcopy)(const void *, void *, size_t);
void (bzero)(void *, size_t);

#endif /* ERX_BACKEND_MEM_H */
