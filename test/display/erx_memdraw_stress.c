/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_memdraw under AddressSanitizer and UndefinedBehaviorSanitizer
 * (docs/design-display.md, "Verification and testing"): random images,
 * among them images at 9front's badrect bounds, and random draws, loads
 * and reads whose rectangles, points and clip rectangles reach anywhere
 * in 32 bits. Every pixel loop must stay inside its images, which is G2's
 * clipping; test/host/erx_memdraw_test.rb runs it, and runs it again with
 * erx_draw_clip seeded to skip the destination, which ASan must catch.
 * Usage: erx_memdraw_stress SEED ROUNDS [trace]; trace prints each draw
 * before it runs and after.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>

#include "erx_memdraw.h"

#define IMAGES 3
#define NOFILL 0xFFFFFF00u

static uint64_t state;
static bool trace;
static long round_number;

static uint32_t
next(void)
{
	state ^= state << 13;
	state ^= state >> 7;
	state ^= state << 17;
	return (uint32_t)(state >> 16);
}

static int32_t
small(void)
{
	return (int32_t)(next() % 41) - 20;
}

static int32_t
coord(void)
{
	static const int32_t far[] = { INT32_MIN, INT32_MAX, -(1 << 30), 1 << 30, (1 << 25) - 3, -(1 << 25) };

	switch (next() % 6) {
	case 0:
		return (int32_t)next();
	case 1:
		return far[next() % 6];
	default:
		return small();
	}
}

static erx_rect_t
any_rect(void)
{
	return (erx_rect_t){ coord(), coord(), coord(), coord() };
}

static erx_rect_t
image_rect(void)
{
	int32_t x = next() % 3 == 0 ? (1 << 25) - 25 - (int32_t)(next() % 16) : small();
	int32_t y = next() % 4 == 0 ? (1 << 22) : small();

	return (erx_rect_t){ x, y, x + 1 + (int32_t)(next() % 24), y + 1 + (int32_t)(next() % 12) };
}

static const uint32_t chans[] = { 0x31, 0x32, 0x34, 0x38, 0x58, 0x051625, 0x081828, 0x68081828, 0x08182848,
	0x48081828, 0x3848 };

/* A done operation touched a nonempty rectangle inside its image. */
static bool
touched_inside(erx_memdraw_status_t status, erx_rect_t t, erx_rect_t image)
{
	return status != ERX_MEMDRAW_DONE ||
	    (image.x0 <= t.x0 && t.x0 < t.x1 && t.x1 <= image.x1 && image.y0 <= t.y0 && t.y0 < t.y1 && t.y1 <= image.y1);
}

static void
report_touched(erx_rect_t t, erx_rect_t image)
{
	fprintf(stderr, "touched %" PRId32 " %" PRId32 " %" PRId32 " %" PRId32 " outside image %" PRId32 " %" PRId32 " %" PRId32 " %" PRId32 "\n",
	    t.x0, t.y0, t.x1, t.y1, image.x0, image.y0, image.x1, image.y1);
	exit(1);
}

static void
check_touched(erx_memdraw_status_t status, erx_rect_t t, erx_rect_t image)
{
	if (!touched_inside(status, t, image))
		report_touched(t, image);
}

/* Image i's rectangle, flags and clip rectangle, for a failure report. */
static void
describe(int i, const erx_mdimage_t *image, erx_rect_t r)
{
	const Memimage *m = (const Memimage *)(const void *)image;

	fprintf(stderr, "image %d r %" PRId32 " %" PRId32 " %" PRId32 " %" PRId32 " chan %08lx repl %d clipr %d %d %d %d\n", i,
	    r.x0, r.y0, r.x1, r.y1, (unsigned long)m->chan, (m->flags & Frepl) != 0, m->clipr.min.x, m->clipr.min.y,
	    m->clipr.max.x, m->clipr.max.y);
}

/* A draw's arguments and its images, for a trace or a failure report. */
static void
describe_draw(int d, erx_rect_t r, int s, erx_point_t sp, int m, erx_point_t mp, int op, bool clipped, erx_rect_t clipr,
    erx_mdimage_t *const image[IMAGES], const erx_rect_t rect[IMAGES])
{
	fprintf(stderr, "round %ld draw dst %d r %" PRId32 " %" PRId32 " %" PRId32 " %" PRId32 " src %d sp %" PRId32
	    " %" PRId32 " mask %d mp %" PRId32 " %" PRId32 " op %d clipr %d %" PRId32 " %" PRId32 " %" PRId32 " %" PRId32 "\n",
	    round_number, d, r.x0, r.y0, r.x1, r.y1, s, sp.x, sp.y, m, mp.x, mp.y, op, clipped, clipr.x0, clipr.y0,
	    clipr.x1, clipr.y1);
	for (int i = 0; i < IMAGES; i++)
		describe(i, image[i], rect[i]);
}

static void
round_of_operations(void)
{
	erx_mdimage_t *image[IMAGES];
	erx_rect_t rect[IMAGES];
	static uint8_t buffer[64 * 1024];

	for (int i = 0; i < IMAGES; i++) {
		rect[i] = image_rect();
		if (erx_memdraw_alloc(&image[i], chans[next() % (sizeof chans / sizeof chans[0])], rect[i], any_rect(),
		    next() % 2 == 0, next() % 2 == 0 ? NOFILL : next()) != ERX_MEMDRAW_DONE) {
			fprintf(stderr, "alloc refused a valid image\n");
			exit(1);
		}
	}
	for (int n = 0; n < 60; n++) {
		int d = next() % IMAGES, s = next() % IMAGES, m = next() % (IMAGES + 1);
		erx_rect_t r = next() % 2 == 0 ? any_rect() : rect[d], clipr = any_rect(), touched;
		size_t size;

		switch (next() % 6) {
		case 0:
			erx_memdraw_set_clip(image[d], next() % 2 == 0, any_rect());
			break;
		case 1:
			if (erx_memdraw_unload_size(image[d], r, &size) == ERX_MEMDRAW_DONE && size <= sizeof buffer)
				check_touched(erx_memdraw_load(image[d], r, buffer, size, &touched), touched, rect[d]);
			else
				(void)erx_memdraw_load(image[d], r, buffer, 1, &touched);
			break;
		case 2:
			if (erx_memdraw_unload_size(image[d], r, &size) == ERX_MEMDRAW_DONE && size <= sizeof buffer)
				(void)erx_memdraw_unload(image[d], r, buffer, size);
			break;
		default: {
			erx_point_t sp = { coord(), coord() }, mp = { coord(), coord() };
			int op = (int)(next() % 12);
			bool clipped = next() % 2 == 0;
			if (trace)
				describe_draw(d, r, s, sp, m, mp, op, clipped, clipr, image, rect);
			erx_memdraw_status_t status = erx_memdraw_draw(image[d], r, image[s], sp,
			    m == IMAGES ? NULL : image[m], mp, op, clipped ? &clipr : NULL, &touched);

			if (!touched_inside(status, touched, rect[d])) {
				describe_draw(d, r, s, sp, m, mp, op, clipped, clipr, image, rect);
				report_touched(touched, rect[d]);
			}
			break;
		}
		}
	}
	for (int i = 0; i < IMAGES; i++)
		erx_memdraw_free(image[i]);
}

int
main(int argc, char **argv)
{
	if (argc < 3 || argc > 4 || !erx_memdraw_init()) {
		fprintf(stderr, "usage: erx_memdraw_stress SEED ROUNDS [trace]\n");
		return 2;
	}
	state = strtoull(argv[1], NULL, 10) * 2654435761u + 1;
	long rounds = strtol(argv[2], NULL, 10);
	trace = argc == 4;
	for (round_number = 0; round_number < rounds; round_number++)
		round_of_operations();
	printf("stress ok\n");
	return 0;
}
