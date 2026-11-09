/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The shapes of erx_memdraw against the 9front build (docs/design-display.md,
 * "The pixel primitives"). The same rounds of random images and shapes
 * (L, p, P, e, E) run through erx_memdraw, when built with display/memdraw,
 * and through 9front's libmemdraw unmodified, when built with -DERX_ORACLE
 * against the fetched sources and test/display/memdraw_oracle; each prints
 * one line a round with a hash of the destination's pixels, and
 * test/host/erx_memdraw_test.rb compares the two outputs. The erx_memdraw
 * build also checks that a shape changes no row outside the rectangle it
 * reports touched.
 *
 * Shapes compose with SoverD, the operation every client draws with by
 * default, and 1x1 sources are premultiplied: under the other operations
 * a k1 mask (a disc end, a brushed ellipse) and under SoverD a 1x1 colour
 * above an alpha of 0 are draws erXos's import fixes (display/libmemdraw/
 * ORIGIN.md), which erx_draw_ref compares instead.
 *
 * Mode "far" (erx_memdraw only, under ASan and UBSan) draws shapes up to
 * and past the limits erx_memdraw admits into small images, where nothing
 * may overflow and a shape past a limit is refused.
 *
 * Usage: memdraw_shapes diff|far SEED ROUNDS
 */
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ERX_ORACLE
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>
#else
#include "erx_memdraw.h"
#endif

#define SOVERD 11
#define FILL (-1)

/* draw(2)'s channel descriptors that erx_memdraw allocates. */
static const uint32_t chans[] = {
	0x31,		/* k1 */
	0x32,		/* k2 */
	0x34,		/* k4 */
	0x38,		/* k8 */
	0x58,		/* m8 */
	0x051625,	/* r5g6b5 */
	0x081828,	/* r8g8b8 */
	0x08182848,	/* r8g8b8a8 */
	0x48081828,	/* a8r8g8b8 */
	0x68081828,	/* x8r8g8b8 */
};

typedef struct box {
	int32_t x0, y0, x1, y1;
} box_t;

typedef struct pt {
	int32_t x, y;
} pt_t;

static uint64_t rng;

static uint32_t
next(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t)(rng >> 16);
}

/* A value in [lo, hi]. */
static int32_t
between(int32_t lo, int32_t hi)
{
	return lo + (int32_t)(next() % (uint32_t)(hi - lo + 1));
}

static int
depth_of(uint32_t chan)
{
	int depth = 0;

	for (uint32_t c = chan; c != 0; c >>= 8)
		depth += c & 15;
	return depth;
}

/* draw(2)'s bytesperline, for a rectangle near the origin. */
static size_t
row_bytes(box_t r, int depth)
{
	int64_t l = r.x0 >= 0 ? (int64_t)r.x0 * depth / 8 : -((-(int64_t)r.x0 * depth + 7) / 8);
	int64_t t = r.x1 >= 0 ? ((int64_t)r.x1 * depth + 7) / 8 : -((-(int64_t)r.x1 * depth) / 8);

	return (size_t)(t - l);
}

static uint8_t *
random_bytes(size_t n)
{
	uint8_t *b = malloc(n > 0 ? n : 1);

	if (b == NULL)
		abort();
	for (size_t i = 0; i < n; i++)
		b[i] = (uint8_t)next();
	return b;
}

/* A 1x1 RGBA colour whose channels are premultiplied by its alpha. */
static uint32_t
premultiplied(void)
{
	uint32_t a = next() & 255;
	uint32_t c = a;

	for (int i = 0; i < 3; i++)
		c |= (a == 0 ? 0 : next() % (a + 1)) << (8 * (i + 1));
	return c;
}

static box_t
random_box(int32_t reach, int32_t size)
{
	int32_t x = between(-reach, reach), y = between(-reach, reach);

	return (box_t){ x, y, x + between(1, size), y + between(1, size) };
}

#ifdef ERX_ORACLE
typedef Memimage image_t;

/* libmemlayer's memdraw and memline, as they behave for an image that is not a layer. */
void
memdraw(Memimage *dst, Rectangle r, Memimage *src, Point p0, Memimage *mask, Point p1, int op)
{
	memimagedraw(dst, r, src, p0, mask, p1, op);
}

void
memline(Memimage *dst, Point p0, Point p1, int end0, int end1, int radius, Memimage *src, Point sp, int op)
{
	memimageline(dst, p0, p1, end0, end1, radius, src, sp, op);
}

Pool *imagmem;

int Rfmt(Fmt *f) { (void)f; return 0; }
int Pfmt(Fmt *f) { (void)f; return 0; }
int _ifmt(Fmt *f) { (void)f; return 0; }

static Rectangle
R(box_t b)
{
	return Rect(b.x0, b.y0, b.x1, b.y1);
}

static Point
P(pt_t p)
{
	return Pt(p.x, p.y);
}

static void
init(void)
{
	memimageinit();
}

static image_t *
image(uint32_t chan, box_t r, box_t clipr, bool repl, const uint8_t *data, size_t n)
{
	Memimage *m = allocmemimage(R(r), chan);

	if (m == nil)
		abort();
	memfillcolor(m, DTransparent);
	if (loadmemimage(m, R(r), (uchar *)data, (int)n) < 0)
		abort();
	if (repl)
		m->flags |= Frepl;
	m->clipr = R(clipr);
	return m;
}

static void
color_image(image_t **out, uint32_t chan, uint32_t color)
{
	Memimage *m = allocmemimage(Rect(0, 0, 1, 1), chan);

	if (m == nil)
		abort();
	m->flags |= Frepl;
	m->clipr = Rect(-0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF);
	memfillcolor(m, color);
	*out = m;
}

static void
unload(image_t *m, box_t r, uint8_t *out, size_t n)
{
	if (unloadmemimage(m, R(r), out, (int)n) < 0)
		abort();
}

static void
release(image_t *m)
{
	freememimage(m);
}

static int
shape_line(image_t *d, pt_t p0, pt_t p1, uint32_t e0, uint32_t e1, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	(void)touched;
	memline(d, P(p0), P(p1), (int)e0, (int)e1, t, s, P(sp), SOVERD);
	return 0;
}

static int
shape_poly(image_t *d, const pt_t *v, int n, uint32_t e0, uint32_t e1, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	Point pts[16];

	(void)touched;
	for (int i = 0; i < n; i++)
		pts[i] = P(v[i]);
	mempoly(d, pts, n, (int)e0, (int)e1, t, s, P(sp), SOVERD);
	return 0;
}

static int
shape_fill_poly(image_t *d, const pt_t *v, int n, int32_t wind, image_t *s, pt_t sp, box_t *touched)
{
	Point pts[16];

	(void)touched;
	for (int i = 0; i < n; i++)
		pts[i] = P(v[i]);
	memfillpoly(d, pts, n, wind, s, P(sp), SOVERD);
	return 0;
}

static int
shape_ellipse(image_t *d, pt_t c, int32_t a, int32_t b, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	(void)touched;
	memellipse(d, P(c), a, b, t, s, P(sp), SOVERD);
	return 0;
}

static int
shape_arc(image_t *d, pt_t c, int32_t a, int32_t b, int32_t t, image_t *s, pt_t sp, int32_t alpha, int32_t phi,
    box_t *touched)
{
	(void)touched;
	memarc(d, P(c), a, b, t, s, P(sp), alpha, phi, SOVERD);
	return 0;
}
#else
typedef erx_mdimage_t image_t;

static erx_rect_t
R(box_t b)
{
	return (erx_rect_t){ b.x0, b.y0, b.x1, b.y1 };
}

static erx_point_t
P(pt_t p)
{
	return (erx_point_t){ p.x, p.y };
}

static void
init(void)
{
	if (!erx_memdraw_init())
		abort();
}

#define DNOFILL 0xFFFFFF00u

static image_t *
image(uint32_t chan, box_t r, box_t clipr, bool repl, const uint8_t *data, size_t n)
{
	erx_mdimage_t *m;
	erx_rect_t touched;

	if (erx_memdraw_alloc(&m, chan, R(r), R(clipr), repl, DNOFILL) != ERX_MEMDRAW_DONE)
		abort();
	if (erx_memdraw_load(m, R(r), data, n, &touched) != ERX_MEMDRAW_DONE)
		abort();
	return m;
}

static void
color_image(image_t **out, uint32_t chan, uint32_t color)
{
	erx_rect_t far = { -0x3FFFFFFF, -0x3FFFFFFF, 0x3FFFFFFF, 0x3FFFFFFF };

	if (erx_memdraw_alloc(out, chan, (erx_rect_t){ 0, 0, 1, 1 }, far, true, color) != ERX_MEMDRAW_DONE)
		abort();
}

static void
unload(image_t *m, box_t r, uint8_t *out, size_t n)
{
	if (erx_memdraw_unload(m, R(r), out, n) != ERX_MEMDRAW_DONE)
		abort();
}

static void
release(image_t *m)
{
	erx_memdraw_free(m);
}

static int
status(erx_memdraw_status_t st, erx_rect_t t, box_t *touched)
{
	switch (st) {
	case ERX_MEMDRAW_DONE:
		*touched = (box_t){ t.x0, t.y0, t.x1, t.y1 };
		return 0;
	case ERX_MEMDRAW_NOTHING:
		*touched = (box_t){ 0, 0, 0, 0 };
		return 0;
	case ERX_MEMDRAW_EINVAL:
		return 1;
	default:
		fprintf(stderr, "shape failed: %d\n", (int)st);
		abort();
	}
}

static int
shape_line(image_t *d, pt_t p0, pt_t p1, uint32_t e0, uint32_t e1, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	erx_rect_t r;

	return status(erx_memdraw_line(d, P(p0), P(p1), e0, e1, t, s, P(sp), SOVERD, &r), r, touched);
}

static int
shape_poly(image_t *d, const pt_t *v, int n, uint32_t e0, uint32_t e1, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	erx_point_t pts[16];
	erx_rect_t r;

	for (int i = 0; i < n; i++)
		pts[i] = P(v[i]);
	return status(erx_memdraw_poly(d, pts, (size_t)n, e0, e1, t, s, P(sp), SOVERD, &r), r, touched);
}

static int
shape_fill_poly(image_t *d, const pt_t *v, int n, int32_t wind, image_t *s, pt_t sp, box_t *touched)
{
	erx_point_t pts[16];
	erx_rect_t r;

	for (int i = 0; i < n; i++)
		pts[i] = P(v[i]);
	return status(erx_memdraw_fill_poly(d, pts, (size_t)n, wind, s, P(sp), SOVERD, &r), r, touched);
}

static int
shape_ellipse(image_t *d, pt_t c, int32_t a, int32_t b, int32_t t, image_t *s, pt_t sp, box_t *touched)
{
	erx_rect_t r;

	return status(erx_memdraw_ellipse(d, P(c), a, b, t, s, P(sp), SOVERD, &r), r, touched);
}

static int
shape_arc(image_t *d, pt_t c, int32_t a, int32_t b, int32_t t, image_t *s, pt_t sp, int32_t alpha, int32_t phi,
    box_t *touched)
{
	erx_rect_t r;

	return status(erx_memdraw_arc(d, P(c), a, b, t, s, P(sp), alpha, phi, SOVERD, &r), r, touched);
}
#endif

/* The ranges a round draws over: near the images, or out to the limits. */
typedef struct ranges {
	int32_t coord, axis, thick;
} ranges_t;

static pt_t
random_pt(const ranges_t *g)
{
	return (pt_t){ between(-g->coord, g->coord - 1), between(-g->coord, g->coord - 1) };
}

/* draw(3)'s line ends: square, disc, arrow, or an arrow of given sizes. */
static uint32_t
random_end(void)
{
	switch (next() % 4) {
	case 0:
		return 0;
	case 1:
		return 1;
	case 2:
		return 2;
	default:
		return 2 | (uint32_t)between(0, 20) << 5 | (uint32_t)between(0, 20) << 14 | (uint32_t)between(0, 10) << 23;
	}
}

/* One random shape onto d from s; 1 when erx_memdraw refused it. */
static int
shape(image_t *d, image_t *s, const ranges_t *g, box_t *touched)
{
	pt_t v[16];
	int n = between(1, 8);
	int32_t a = between(0, g->axis), b = between(0, g->axis), t = between(0, g->thick);

	for (int i = 0; i < 8; i++)
		v[i] = random_pt(g);
	switch (next() % 6) {
	case 0:
		return shape_line(d, v[0], v[1], random_end(), random_end(), t, s, v[2], touched);
	case 1:
		return shape_poly(d, v, n, random_end(), random_end(), t, s, v[n - 1], touched);
	case 2:
		return shape_fill_poly(d, v, n, next() % 2 == 0 ? -1 : 1, s, v[n - 1], touched);
	case 3:
		return shape_ellipse(d, v[0], a, b, next() % 3 == 0 ? FILL : t, s, v[1], touched);
	case 4:
		return shape_arc(d, v[0], a, b, next() % 3 == 0 ? FILL : t, s, v[1], between(-400, 400), between(-400, 400),
		    touched);
	default:
		return shape_ellipse(d, v[0], a, b, t, s, v[1], touched);
	}
}

static uint64_t
fnv(const uint8_t *b, size_t n)
{
	uint64_t h = 0xcbf29ce484222325u;

	for (size_t i = 0; i < n; i++)
		h = (h ^ b[i]) * 0x100000001b3u;
	return h;
}

/* A source: a 1x1 premultiplied colour, or a small random image, replicated or not. */
static image_t *
source(void)
{
	uint32_t chan = chans[next() % (sizeof(chans) / sizeof(chans[0]))];
	image_t *s;

	if (next() % 2 == 0) {
		color_image(&s, chan, premultiplied());
		return s;
	}
	box_t r = random_box(8, 8), clipr = random_box(16, 24);
	size_t n = row_bytes(r, depth_of(chan)) * (size_t)(r.y1 - r.y0);
	uint8_t *data = random_bytes(n);
	s = image(chan, r, clipr, next() % 2 == 0, data, n);
	free(data);
	return s;
}

static void
round_once(int round, bool far)
{
	static const ranges_t near = { 80, 40, 6 };
	static const ranges_t limits = { (1 << 19) + 2, (1 << 14) + 2, (1 << 10) + 2 };
	uint32_t chan = chans[next() % (sizeof(chans) / sizeof(chans[0]))];
	box_t r = random_box(40, 48), clipr = random_box(48, 64);
	int depth = depth_of(chan);
	size_t row = row_bytes(r, depth), n = row * (size_t)(r.y1 - r.y0);
	uint8_t *data = random_bytes(n), *after = malloc(n);
	image_t *d = image(chan, r, clipr, false, data, n);
	image_t *s = source();
	box_t touched = { 0, 0, 0, 0 };

	if (after == NULL)
		abort();
	/* What load kept: the bits of a row's edge bytes outside r stay 0. */
	unload(d, r, data, n);
	int refused = shape(d, far && next() % 16 == 0 ? d : s, far ? &limits : &near, &touched);
	unload(d, r, after, n);
#ifndef ERX_ORACLE
	for (int32_t y = r.y0; y < r.y1; y++)
		if ((y < touched.y0 || y >= touched.y1) &&
		    memcmp(data + row * (size_t)(y - r.y0), after + row * (size_t)(y - r.y0), row) != 0) {
			printf("round %d: row %d changed outside the touched rectangle %d,%d,%d,%d\n", round, y, touched.x0, touched.y0, touched.x1, touched.y1);
			exit(1);
		}
#endif
	if (!far)
		printf("round %d %d %016" PRIx64 "\n", round, refused, fnv(after, n));
	release(s);
	release(d);
	free(data);
	free(after);
}

int
main(int argc, char **argv)
{
	if (argc != 4 || (strcmp(argv[1], "diff") != 0 && strcmp(argv[1], "far") != 0)) {
		fprintf(stderr, "usage: memdraw_shapes diff|far SEED ROUNDS\n");
		return 2;
	}
	rng = strtoull(argv[2], NULL, 10) * 0x9E3779B97F4A7C15u | 1;
	int rounds = atoi(argv[3]);
	bool far = strcmp(argv[1], "far") == 0;

	init();
	for (int i = 0; i < rounds; i++)
		round_once(i, far);
	printf("%s ok\n", argv[1]);
	return 0;
}
