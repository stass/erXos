/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task links no C library until musl's start path runs, and the
 * compiler may still call these for a structure copy or an initializer. The
 * pointers are volatile so the loops do not compile back into calls to
 * themselves.
 */

#include <stddef.h>
#include <stdint.h>

void *memcpy(void *, const void *, size_t);
void *memset(void *, int, size_t);

void *
memcpy(void *target, const void *source, size_t length)
{
	volatile uint8_t *to = target;
	const uint8_t *from = source;

	while (length-- > 0)
		*to++ = *from++;
	return (target);
}

void *
memset(void *target, int value, size_t length)
{
	volatile uint8_t *to = target;

	while (length-- > 0)
		*to++ = (uint8_t)value;
	return (target);
}
