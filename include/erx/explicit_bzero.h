/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_EXPLICIT_BZERO_H
#define ERX_EXPLICIT_BZERO_H

#include <stddef.h>
#include <stdint.h>

/*
 * Zeroes length bytes at buf even when nothing reads them afterwards, as
 * BSD's explicit_bzero does: code that erases a key or a digest calls this
 * where a plain bzero or memset of a dead buffer would be removed by the
 * compiler. Each store goes through a volatile lvalue, which the compiler
 * must perform; the loop needs no library call and no assembly, so the
 * freestanding cores use it as well as hosted code.
 */
static inline void
erx_explicit_bzero(void *buf, size_t length)
{
	volatile uint8_t *bytes = buf;

	for (size_t index = 0; index < length; index++)
		bytes[index] = 0;
}

#endif /* ERX_EXPLICIT_BZERO_H */
