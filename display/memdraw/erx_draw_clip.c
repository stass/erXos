/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_draw_clip: the one computation of the rectangles a draw touches
 * (docs/design-display.md, invariant G2 and "The window process"). It is
 * libmemdraw's drawclip, from 9front's draw.c, computed in 64 bits, so a
 * rectangle or point anywhere in draw(3)'s 32 bits clips without
 * overflow; drawclip instead refuses, through badrect, any rectangle it
 * cannot compute in int, and so drew nothing of a rectangle reaching far
 * outside the image. Every result lies inside its image (the source's
 * and mask's corners inside their rectangles when they replicate), and
 * images pass badrect, so the result fits in int.
 */
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct rect64 {
	int64_t x0, y0, x1, y1;
} rect64_t;

static rect64_t
widen(Rectangle r)
{
	return (rect64_t){ r.min.x, r.min.y, r.max.x, r.max.y };
}

static Rectangle
narrow(rect64_t r)
{
	return Rect((int)r.x0, (int)r.y0, (int)r.x1, (int)r.y1);
}

static int64_t
max64(int64_t a, int64_t b)
{
	return a > b ? a : b;
}

static int64_t
min64(int64_t a, int64_t b)
{
	return a < b ? a : b;
}

/*
 * rectclip, but false unless the intersection of *r and b is nonempty;
 * else *r becomes it. rectclip tests only rectXrect, which an empty or
 * inverted b passes, and a clip rectangle may be either: draw(3) checks
 * neither. Every rectangle clip_to leaves is nonempty, so the rectangles
 * erx_draw_clip returns are, and alphadraw's row loop ends.
 */
static bool
clip_to(rect64_t *r, rect64_t b)
{
	rect64_t c = { max64(r->x0, b.x0), max64(r->y0, b.y0), min64(r->x1, b.x1), min64(r->y1, b.y1) };

	if (c.x1 <= c.x0 || c.y1 <= c.y0)
		return false;
	*r = c;
	return true;
}

static rect64_t
moved(rect64_t r, int64_t dx, int64_t dy)
{
	return (rect64_t){ r.x0 + dx, r.y0 + dy, r.x1 + dx, r.y1 + dy };
}

/* drawreplxy: v wrapped into [lo, hi). */
static int64_t
wrap(int64_t v, int64_t lo, int64_t hi)
{
	int64_t m = (v - lo) % (hi - lo);

	return lo + (m < 0 ? m + (hi - lo) : m);
}

/*
 * The rectangles of a draw of r on dst, clipped to dclipr, from src at
 * sp through mask at mp: false when nothing is drawn. drawclip's steps in
 * its order: clip r to dst, move both points with r's corner, clip r's
 * image in src, then in mask (with the mask's own point when it differs
 * from the source's), reflect those clips back to r, and move a
 * replicated source's and the mask's corners into their rectangles.
 */
bool
erx_draw_clip(erx_clip_t *out, const Memimage *dst, Rectangle dclipr, Rectangle dr, const Memimage *src, Point sp,
    const Memimage *mask, Point mp)
{
	rect64_t r = widen(dr);
	int64_t p0x = sp.x, p0y = sp.y, p1x = mp.x, p1y = mp.y;
	bool split = sp.x != mp.x || sp.y != mp.y;

	if (r.x1 <= r.x0 || r.y1 <= r.y0)
		return false;
	int64_t rminx = r.x0, rminy = r.y0;
	if (!clip_to(&r, widen(dst->r)) || !clip_to(&r, widen(dclipr)))
		return false;
	p0x += r.x0 - rminx;
	p0y += r.y0 - rminy;
	p1x += r.x0 - rminx;
	p1y += r.y0 - rminy;

	rect64_t sr = { p0x, p0y, p0x + (r.x1 - r.x0), p0y + (r.y1 - r.y0) };
	if (!(src->flags & Frepl) && !clip_to(&sr, widen(src->r)))
		return false;
	if (!clip_to(&sr, widen(src->clipr)))
		return false;

	rect64_t mr;
	if (split) {
		p1x += sr.x0 - p0x;
		p1y += sr.y0 - p0y;
		mr = (rect64_t){ p1x, p1y, p1x + (sr.x1 - sr.x0), p1y + (sr.y1 - sr.y0) };
		rect64_t omr = mr;
		if (!(mask->flags & Frepl) && !clip_to(&mr, widen(mask->r)))
			return false;
		if (!clip_to(&mr, widen(mask->clipr)))
			return false;
		sr = (rect64_t){ sr.x0 + (mr.x0 - omr.x0), sr.y0 + (mr.y0 - omr.y0), sr.x1 + (mr.x1 - omr.x1),
			sr.y1 + (mr.y1 - omr.y1) };
	} else {
		if (!(mask->flags & Frepl) && !clip_to(&sr, widen(mask->r)))
			return false;
		if (!clip_to(&sr, widen(mask->clipr)))
			return false;
		mr = sr;
	}
	r = moved(sr, r.x0 - p0x, r.y0 - p0y);

	if (src->flags & Frepl)
		sr = moved(sr, wrap(sr.x0, src->r.min.x, src->r.max.x) - sr.x0,
		    wrap(sr.y0, src->r.min.y, src->r.max.y) - sr.y0);
	int64_t mx = wrap(mr.x0, mask->r.min.x, mask->r.max.x);
	int64_t my = wrap(mr.y0, mask->r.min.y, mask->r.max.y);
	mr = (rect64_t){ mx, my, mx + (sr.x1 - sr.x0), my + (sr.y1 - sr.y0) };

	*out = (erx_clip_t){ .r = narrow(r), .sr = narrow(sr), .mr = narrow(mr) };
	return true;
}
