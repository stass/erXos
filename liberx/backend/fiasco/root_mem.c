/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root task links no C library until musl's start path runs, and the
 * compiler may still call memcpy or memset for a structure copy or an
 * initializer. The pointers are volatile so the loops do not compile back into
 * calls to themselves. bcopy and bzero serve the backend's cores (root_mem.h).
 */

#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/fiasco/root_mem.h"

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

/* The source may overlap the target, so a copy upward walks down. */
void
bcopy(const void *source, void *target, size_t length)
{
	volatile uint8_t *to = target;
	const uint8_t *from = source;

	if ((uintptr_t)to <= (uintptr_t)from) {
		while (length-- > 0)
			*to++ = *from++;
	} else {
		while (length-- > 0)
			to[length] = from[length];
	}
}

/* By words where it can: a committed page is zeroed through here, 512 words at a time. */
void
bzero(void *target, size_t length)
{
	volatile uint8_t *to = target;
	volatile uint64_t *words;

	while (length > 0 && ((uintptr_t)to & (sizeof(*words) - 1)) != 0) {
		*to++ = 0;
		length--;
	}
	for (words = (volatile uint64_t *)to; length >= sizeof(*words); length -= sizeof(*words))
		*words++ = 0;
	to = (volatile uint8_t *)words;
	while (length-- > 0)
		*to++ = 0;
}
