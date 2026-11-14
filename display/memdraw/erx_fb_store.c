/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The firmware framebuffer's copy (erx_fb_store.h). Every offset is a row
 * times a stride plus a byte within the row's rounded-up bytes, and the
 * layout check proves the last such offset of each side lies inside it, so
 * the loop needs no check of its own.
 */
#include <string.h>

#include "erx_fb_store.h"

/* A row's bytes, rounded up to a whole 32-bit word; 0 for a depth the copy does not take. */
static uint64_t
row_words_bytes(const erx_fb_geometry_t *geometry)
{
	if (geometry->depth != 16 && geometry->depth != 24 && geometry->depth != 32)
		return (0);
	/* width < 2^32 and depth <= 32, so the product fits 64 bits. */
	const uint64_t bytes = ((uint64_t)geometry->width * geometry->depth + 7) / 8;
	return ((bytes + 3) & ~(uint64_t)3);
}

static bool
side_ok(const erx_fb_side_t *side, const erx_fb_geometry_t *geometry, uint64_t row)
{
	uint64_t last;

	return ((uintptr_t)side->base % 4 == 0 && side->stride % 4 == 0 && side->stride >= row &&
	    !__builtin_mul_overflow((uint64_t)(geometry->height - 1), (uint64_t)side->stride, &last) &&
	    !__builtin_add_overflow(last, row, &last) && last <= side->bytes);
}

bool
erx_fb_store_layout_ok(const erx_fb_side_t *src, const erx_fb_side_t *dst, const erx_fb_geometry_t *geometry)
{
	const uint64_t row = row_words_bytes(geometry);

	if (row == 0 || geometry->width == 0 || geometry->height == 0 || geometry->width > INT32_MAX ||
	    geometry->height > INT32_MAX)
		return (false);
	return (side_ok(src, geometry, row) && side_ok(dst, geometry, row));
}

bool
erx_fb_store_rect_ok(const erx_fb_geometry_t *geometry, erx_fb_rect_t r)
{
	return (r.x0 >= 0 && r.y0 >= 0 && r.x0 < r.x1 && r.y0 < r.y1 && (uint32_t)r.x1 <= geometry->width &&
	    (uint32_t)r.y1 <= geometry->height);
}

/* One row of r: the 32-bit words from the one holding x0's first byte to the one holding x1's last. */
static void
store_row(const uint8_t *src, volatile uint8_t *dst, uint64_t first, uint64_t end)
{
	for (uint64_t at = first; at < end; at += 4) {
		uint32_t word;

		memcpy(&word, src + at, sizeof word);
		*(volatile uint32_t *)(dst + at) = word;
	}
}

bool
erx_fb_store(const erx_fb_side_t *src, const erx_fb_side_t *dst, const erx_fb_geometry_t *geometry,
    const erx_fb_rect_t *rects, size_t n)
{
	const uint64_t row = row_words_bytes(geometry);

	if (!erx_fb_store_layout_ok(src, dst, geometry))
		return (false);
	for (size_t i = 0; i < n; i++)
		if (!erx_fb_store_rect_ok(geometry, rects[i]))
			return (false);
	/* The source is ordinary memory; only the framebuffer is written through volatile stores. */
	const uint8_t *const from = (const uint8_t *)(uintptr_t)src->base;
	for (size_t i = 0; i < n; i++) {
		const erx_fb_rect_t r = rects[i];
		const uint64_t first = ((uint64_t)r.x0 * geometry->depth / 8) & ~(uint64_t)3;
		const uint64_t past = (((uint64_t)r.x1 * geometry->depth + 7) / 8 + 3) & ~(uint64_t)3;
		const uint64_t end = past < row ? past : row;

		for (int32_t y = r.y0; y < r.y1; y++)
			store_row(from + (uint64_t)y * src->stride, dst->base + (uint64_t)y * dst->stride, first, end);
	}
	return (true);
}
