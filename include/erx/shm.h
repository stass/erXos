/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_SHM_H
#define ERX_SHM_H

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

/*
 * The one copy out of a page another party writes: a lane's ring, data
 * area or reader page, and a pipe's lock page (docs/design-pipes.md, "The
 * ring").  A build check keeps every other load of a pipe's pages out of
 * liberx and the pipe NIF; the lane's reader copies its data area through
 * this too.  The published positions are the exception: a read end loads a
 * ring's wpos, and a write end a reader page's rpos, with one acquire load
 * of their own before they touch the bytes the position covers.
 */

/*
 * Copies n bytes from position pos of a shared area of size bytes into
 * dst, wrapping at the area's end: position pos is offset pos & (size - 1).
 * The area is 8-byte aligned and size is a power of two of at least 8, so
 * every load is an aligned relaxed atomic load of one word, which the
 * hardware makes single-copy atomic even where the writer stores the
 * word's halves as 32-bit fields: a party that rewrites the area
 * concurrently changes what is copied but never tears a word, and each
 * byte of dst is loaded once.  Ordering the
 * bytes after the position that published them is the caller's acquire
 * load's job.
 */
static inline void
erx_shm_copy(const _Atomic uint64_t *area, uint64_t size, uint64_t pos,
    void *dst, uint64_t n)
{
	unsigned char *out;
	uint64_t chunk, mask, offset, skip, word;

	out = dst;
	mask = size - 1;
	while (n > 0) {
		offset = pos & mask;
		skip = offset % sizeof(word);
		chunk = sizeof(word) - skip;
		if (chunk > n)
			chunk = n;
		word = atomic_load_explicit(&area[offset / sizeof(word)],
		    memory_order_relaxed);
		memcpy(out, (const unsigned char *)&word + skip, chunk);
		pos += chunk;
		out += chunk;
		n -= chunk;
	}
}

#endif /* !ERX_SHM_H */
