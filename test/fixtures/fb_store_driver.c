/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host test of a firmware framebuffer's copy (display/memdraw/erx_fb_store.c), run by
 * test/host/fb_store_test.rb under ASan and UBSan: each case lays a source and a framebuffer
 * out in plain memory, the framebuffer filled with a sentinel, stores rectangles and checks
 * every byte of the framebuffer, so a byte written outside a rectangle's widened span, or
 * one past a refused call, fails the case. Prints one line per failed case and exits 1.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_fb_store.h"

#define SENTINEL 0xa5
#define ROOM 4096

static _Alignas(16) uint8_t src_bytes[ROOM];
static _Alignas(16) uint8_t dst_bytes[ROOM + 4];
static int failures;

static void
fail(const char *name, const char *what)
{
	printf("%s: %s\n", name, what);
	failures++;
}

/* A source whose byte at each offset is the offset's low byte plus one, never the sentinel's. */
static void
reset(void)
{
	for (size_t i = 0; i < ROOM; i++)
		src_bytes[i] = (uint8_t)(i % 251 + 1);
	memset(dst_bytes, SENTINEL, sizeof dst_bytes);
}

/*
 * Whether every framebuffer byte is the source's byte at the same row and column when its
 * row lies in [y0, y1) and its byte in [first, end), and the sentinel otherwise.
 */
static bool
only(const erx_fb_side_t *src, const erx_fb_side_t *dst, size_t dst_off, int32_t y0, int32_t y1, size_t first,
    size_t end)
{
	for (size_t at = 0; at < sizeof dst_bytes; at++) {
		const size_t rel = at - dst_off;
		const bool inside = at >= dst_off && rel < dst->bytes && (int32_t)(rel / dst->stride) >= y0 &&
		    (int32_t)(rel / dst->stride) < y1 && rel % dst->stride >= first && rel % dst->stride < end;
		const uint8_t want = inside ? src_bytes[rel / dst->stride * src->stride + rel % dst->stride] : SENTINEL;

		if (dst_bytes[at] != want)
			return false;
	}
	return true;
}

static void
stores(const char *name, erx_fb_geometry_t g, size_t src_stride, size_t dst_stride, size_t dst_off, size_t dst_len,
    erx_fb_rect_t r, size_t first, size_t end)
{
	reset();
	const erx_fb_side_t src = { .base = src_bytes, .bytes = ROOM, .stride = src_stride };
	const erx_fb_side_t dst = { .base = dst_bytes + dst_off, .bytes = dst_len, .stride = dst_stride };

	if (!erx_fb_store(&src, &dst, &g, &r, 1))
		fail(name, "refused");
	else if (!only(&src, &dst, dst_off, r.y0, r.y1, first, end))
		fail(name, "wrote outside the rectangle's words, or not all of them");
}

static void
refuses(const char *name, erx_fb_geometry_t g, size_t src_stride, size_t dst_stride, size_t dst_off, size_t dst_len,
    const erx_fb_rect_t *rects, size_t n)
{
	reset();
	const erx_fb_side_t src = { .base = src_bytes, .bytes = ROOM, .stride = src_stride };
	const erx_fb_side_t dst = { .base = dst_bytes + dst_off, .bytes = dst_len, .stride = dst_stride };

	if (erx_fb_store(&src, &dst, &g, rects, n))
		fail(name, "stored");
	for (size_t at = 0; at < sizeof dst_bytes; at++)
		if (dst_bytes[at] != SENTINEL) {
			fail(name, "wrote before refusing");
			return;
		}
}

int
main(void)
{
	const erx_fb_geometry_t xrgb = { .width = 4, .height = 3, .depth = 32 };
	const erx_fb_geometry_t rgb565 = { .width = 5, .height = 2, .depth = 16 };
	const erx_fb_geometry_t rgb888 = { .width = 3, .height = 2, .depth = 24 };
	const erx_fb_rect_t whole = { 0, 0, 4, 3 };

	/* The firmware's stride wider than the image's, the framebuffer at an offset in its page. */
	stores("whole-32", xrgb, 16, 32, 64, 96, whole, 0, 16);
	stores("corner-32", xrgb, 16, 32, 0, 96, (erx_fb_rect_t){ 3, 2, 4, 3 }, 12, 16);
	stores("inner-32", xrgb, 16, 20, 4, 60, (erx_fb_rect_t){ 1, 1, 3, 2 }, 4, 12);
	/* 16 bits: pixel 1 alone widens to the word of pixels 0 and 1; the last pixel's word ends the row. */
	stores("odd-16", rgb565, 12, 16, 0, 32, (erx_fb_rect_t){ 1, 0, 2, 1 }, 0, 4);
	stores("edge-16", rgb565, 12, 12, 0, 24, (erx_fb_rect_t){ 4, 1, 5, 2 }, 8, 12);
	/* 24 bits: a row of 9 bytes rounds up to 12, which both strides hold. */
	stores("row-24", rgb888, 12, 12, 0, 24, (erx_fb_rect_t){ 0, 0, 3, 2 }, 0, 12);
	stores("middle-24", rgb888, 12, 16, 0, 28, (erx_fb_rect_t){ 1, 1, 2, 2 }, 0, 8);

	refuses("past-right", xrgb, 16, 16, 0, 48, &(erx_fb_rect_t){ 0, 0, 5, 1 }, 1);
	refuses("past-bottom", xrgb, 16, 16, 0, 48, &(erx_fb_rect_t){ 0, 2, 1, 4 }, 1);
	refuses("negative", xrgb, 16, 16, 0, 48, &(erx_fb_rect_t){ -1, 0, 1, 1 }, 1);
	refuses("empty", xrgb, 16, 16, 0, 48, &(erx_fb_rect_t){ 2, 1, 2, 3 }, 1);
	refuses("one-bad-of-two", xrgb, 16, 16, 0, 48, (erx_fb_rect_t[]){ whole, { 0, 0, 1, 9 } }, 2);
	refuses("stride-short", xrgb, 16, 12, 0, 48, &whole, 1);
	refuses("stride-unaligned", xrgb, 16, 18, 0, 54, &whole, 1);
	refuses("base-unaligned", xrgb, 16, 16, 2, 48, &whole, 1);
	refuses("bytes-short", xrgb, 16, 16, 0, 47, &whole, 1);
	refuses("source-stride-short", xrgb, 12, 16, 0, 48, &whole, 1);
	refuses("row-24-stride-9", rgb888, 12, 9, 0, 18, &(erx_fb_rect_t){ 0, 0, 1, 1 }, 1);
	refuses("depth-8", (erx_fb_geometry_t){ .width = 4, .height = 1, .depth = 8 }, 4, 4, 0, 4,
	    &(erx_fb_rect_t){ 0, 0, 1, 1 }, 1);
	refuses("no-height", (erx_fb_geometry_t){ .width = 4, .height = 0, .depth = 32 }, 16, 16, 0, 48,
	    &(erx_fb_rect_t){ 0, 0, 1, 1 }, 1);
	if (failures == 0)
		printf("ok\n");
	return failures == 0 ? 0 : 1;
}
