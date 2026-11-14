/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The copy of a firmware framebuffer's driver (docs/design-display.md, "The
 * display device"): rectangles of the screen image, in ordinary memory, stored
 * into the framebuffer, which is device memory, with aligned 32-bit stores
 * alone, since device memory takes no unaligned or cache-line access. The
 * framebuffer has the firmware's stride and the screen image libmemdraw's;
 * both share the width, height and depth, so a pixel's bytes are copied as
 * they are. It builds for the host and reads no global state.
 */
#ifndef ERX_FB_STORE_H
#define ERX_FB_STORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx_memdraw.h"

/* One side of the copy: its first byte, its length and the bytes of one row. */
typedef struct erx_fb_side {
	volatile uint8_t *base;	/* read only on the source side */
	size_t bytes;
	size_t stride;
} erx_fb_side_t;

/* Width and height in pixels, depth in bits: 16, 24 or 32. */
typedef struct erx_fb_geometry {
	uint32_t width;
	uint32_t height;
	uint32_t depth;
} erx_fb_geometry_t;

/*
 * Whether src and dst can be copied between as geometry lays them out: each
 * base on a 4-byte boundary, each stride a multiple of 4 and at least a row's
 * bytes rounded up to 4, and each length holding every row. Pure.
 */
bool	erx_fb_store_layout_ok(const erx_fb_side_t *src, const erx_fb_side_t *dst, const erx_fb_geometry_t *geometry);

/* Whether r is nonempty and lies in (0, 0)-(width, height). Pure. */
bool	erx_fb_store_rect_ok(const erx_fb_geometry_t *geometry, erx_rect_t r);

/*
 * Copies each of the n rectangles of src into dst, every row's span widened to
 * whole 32-bit words and cut at the row's bytes rounded up to 4. Checks the
 * layout and every rectangle first and writes nothing unless all pass;
 * returns whether it wrote.
 */
bool	erx_fb_store(const erx_fb_side_t *src, const erx_fb_side_t *dst,
	    const erx_fb_geometry_t *geometry, const erx_rect_t *rects, size_t n);

#endif /* ERX_FB_STORE_H */
