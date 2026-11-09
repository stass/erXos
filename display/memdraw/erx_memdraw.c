/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_memdraw over erXos's copy of libmemdraw (erx_memdraw.h). An
 * erx_mdimage_t is a Memimage that owns its Memdata; nothing else
 * shares an image's pixels, so two images alias only when they are the
 * same image.
 */
#include <u.h>
#include <libc.h>
#include <draw.h>
#include <memdraw.h>

#include <limits.h>

#include "erx_memdraw.h"

static Memimage *
mem(erx_mdimage_t *image)
{
	return (Memimage *)(void *)image;
}

static const Memimage *
cmem(const erx_mdimage_t *image)
{
	return (const Memimage *)(const void *)image;
}

static Rectangle
rect(erx_rect_t r)
{
	return Rect(r.x0, r.y0, r.x1, r.y1);
}

static erx_rect_t
erect(Rectangle r)
{
	return (erx_rect_t){ r.min.x, r.min.y, r.max.x, r.max.y };
}

bool
erx_memdraw_init(void)
{
	return memimageinit() == 0;
}

/*
 * The channels libmemdraw reads and writes as draw(2) defines them, the
 * ones erx_draw_ref models: an image of fewer than 8 bits a pixel is one
 * grey channel (readnbit and writenbit know no other), a map channel is
 * m8 alone (readcmap and writecmap assume it), and grey is not mixed with
 * colour (writebyte writes only the grey). draw(3)'s b refuses the rest.
 */
bool
erx_memdraw_chan_supported(uint32_t chan)
{
	int depth = chantodepth(chan);
	bool grey = false, colour = false, map = false;
	uint seen = 0;

	if (depth == 0)
		return false;
	if (depth < 8)
		return chan == GREY1 || chan == GREY2 || chan == GREY4;
	for (ulong c = chan; c != 0; c >>= 8) {
		/* memsetchan refuses a type twice but x. */
		if (TYPE(c) != CIgnore && (seen & (1u << TYPE(c))) != 0)
			return false;
		seen |= 1u << TYPE(c);
		switch (TYPE(c)) {
		case CGrey:
			grey = true;
			break;
		case CRed:
		case CGreen:
		case CBlue:
			colour = true;
			break;
		case CMap:
			map = true;
			break;
		default:
			break;
		}
	}
	if (map)
		return chan == CMAP8;
	return !(grey && colour);
}

/*
 * The widest image erx_memdraw allocates. alphadraw sizes its row buffer
 * in int, about 136 bytes for each pixel of a row at worst, so a width
 * badrect admits (up to 2^26) overflows it; this bound keeps it below
 * 2^24 bytes whatever the caller's quota is.
 */
#define ERX_MEMDRAW_MAX_WIDTH (1 << 16)

erx_memdraw_status_t
erx_memdraw_alloc(erx_mdimage_t **out, uint32_t chan, erx_rect_t r, erx_rect_t clipr, bool repl, uint32_t color)
{
	if (!erx_memdraw_chan_supported(chan) || badrect(rect(r)) || (int64_t)r.x1 - r.x0 > ERX_MEMDRAW_MAX_WIDTH)
		return ERX_MEMDRAW_EINVAL;
	Memimage *image = allocmemimage(rect(r), chan);
	if (image == nil)
		return ERX_MEMDRAW_ENOMEM;
	if (repl)
		image->flags |= Frepl;
	image->clipr = rect(clipr);
	memfillcolor(image, color);
	*out = (erx_mdimage_t *)(void *)image;
	return ERX_MEMDRAW_DONE;
}

void
erx_memdraw_free(erx_mdimage_t *image)
{
	freememimage(mem(image));
}

void
erx_memdraw_set_clip(erx_mdimage_t *image, bool repl, erx_rect_t clipr)
{
	Memimage *m = mem(image);

	m->flags = repl ? (m->flags | Frepl) : (m->flags & ~Frepl);
	m->clipr = rect(clipr);
}

/* A copy of image's pixels, flags and clip rectangle, or nil. */
static Memimage *
snapshot(const Memimage *image)
{
	Memimage *copy = allocmemimage(image->r, image->chan);

	if (copy == nil)
		return nil;
	memmove(copy->data->bdata, image->data->bdata,
	    (size_t)image->width * sizeof(ulong) * (size_t)Dy(image->r));
	copy->flags = image->flags;
	copy->clipr = image->clipr;
	return copy;
}

static bool
clip_draw(erx_clip_t *clip, const Memimage *dst, erx_rect_t r, const Memimage *src, erx_point_t sp,
    const Memimage *mask, erx_point_t mp, const erx_rect_t *clipr)
{
	return erx_draw_clip(clip, dst, clipr != NULL ? rect(*clipr) : dst->clipr, rect(r), src, Pt(sp.x, sp.y),
	    mask, Pt(mp.x, mp.y));
}

erx_memdraw_status_t
erx_memdraw_draw(erx_mdimage_t *dsti, erx_rect_t r, erx_mdimage_t *srci, erx_point_t sp, erx_mdimage_t *maski,
    erx_point_t mp, int op, const erx_rect_t *clipr, erx_rect_t *touched)
{
	/*
	 * Each image's header (its rectangles, replicate bit and pixel
	 * pointer) is read once, here, and an image passed twice is read
	 * once: a clip of one of the images by another process during the
	 * draw changes the image, not these copies, so the rectangles
	 * erx_draw_clip checks are the ones memimagedraw walks. The copies
	 * share the images' pixels, so libmemdraw still sees two of them
	 * alias when their data does.
	 */
	bool src_is_dst = srci == dsti, mask_is_dst = maski == dsti;
	Memimage dsth = *mem(dsti);
	Memimage srch = src_is_dst ? dsth : *mem(srci);
	Memimage maskh;
	if (maski == NULL)
		maskh = *memopaque;
	else if (mask_is_dst)
		maskh = dsth;
	else if (maski == srci)
		maskh = srch;
	else
		maskh = *mem(maski);
	Memimage *dst = &dsth, *src = &srch, *mask = &maskh;
	erx_clip_t clip;

	if (op < 0 || op >= Ncomp)
		return ERX_MEMDRAW_EINVAL;
	if (!clip_draw(&clip, dst, r, src, sp, mask, mp, clipr))
		return ERX_MEMDRAW_NOTHING;

	/*
	 * alphadraw buffers a source that is the destination and does not
	 * replicate, and reads every other image as it writes the
	 * destination's rows. A mask that is the destination, or a
	 * replicated source that is, is read from a copy taken before the
	 * draw, so every pixel is composed from the pixels before the draw.
	 */
	Memimage *copy = nil;
	if (mask_is_dst || (src_is_dst && (src->flags & Frepl))) {
		if ((copy = snapshot(dst)) == nil)
			return ERX_MEMDRAW_ENOMEM;
		if (mask_is_dst)
			mask = copy;
		if (src_is_dst)
			src = copy;
	}
	int drawn = memimagedraw(dst, src, mask, &clip, op);
	freememimage(copy);
	if (drawn != 0)
		return ERX_MEMDRAW_ENOMEM;
	*touched = erect(clip.r);
	return ERX_MEMDRAW_DONE;
}

/* The bytes of r's rows, when r lies in image and passes badrect. */
static bool
rows_of(const Memimage *image, erx_rect_t r, size_t *n)
{
	Rectangle rr = rect(r);

	if (badrect(rr) || !rectinrect(rr, image->r))
		return false;
	*n = (size_t)bytesperline(rr, image->depth) * (size_t)Dy(rr);
	return true;
}

erx_memdraw_status_t
erx_memdraw_load(erx_mdimage_t *image, erx_rect_t r, const uint8_t *data, size_t n, erx_rect_t *touched)
{
	size_t need;

	if (!rows_of(mem(image), r, &need) || n != need)
		return ERX_MEMDRAW_EINVAL;
	/* loadmemimage only reads data. */
	if (loadmemimage(mem(image), rect(r), (uchar *)(uintptr_t)data, (int)n) < 0)
		return ERX_MEMDRAW_EINVAL;
	*touched = r;
	return ERX_MEMDRAW_DONE;
}

erx_memdraw_status_t
erx_memdraw_unload_size(const erx_mdimage_t *image, erx_rect_t r, size_t *n)
{
	return rows_of(cmem(image), r, n) ? ERX_MEMDRAW_DONE : ERX_MEMDRAW_EINVAL;
}

erx_memdraw_status_t
erx_memdraw_unload(const erx_mdimage_t *image, erx_rect_t r, uint8_t *out, size_t n)
{
	size_t need;

	if (!rows_of(cmem(image), r, &need) || n != need)
		return ERX_MEMDRAW_EINVAL;
	/* unloadmemimage only reads the image. */
	Memimage *m = (Memimage *)(uintptr_t)cmem(image);
	return unloadmemimage(m, rect(r), out, (int)n) < 0 ? ERX_MEMDRAW_EINVAL : ERX_MEMDRAW_DONE;
}

size_t
erx_memdraw_draw_bytes(const erx_mdimage_t *dst, erx_rect_t r, const erx_mdimage_t *src, erx_point_t sp,
    const erx_mdimage_t *mask, erx_point_t mp, const erx_rect_t *clipr)
{
	erx_clip_t clip;
	size_t n;

	if (!clip_draw(&clip, cmem(dst), r, cmem(src), sp, mask != NULL ? cmem(mask) : memopaque, mp, clipr))
		return 0;
	return rows_of(cmem(dst), erect(clip.r), &n) ? n : 0;
}

size_t
erx_memdraw_rect_bytes(const erx_mdimage_t *image, erx_rect_t r)
{
	size_t n;

	return rows_of(cmem(image), r, &n) ? n : 0;
}

/*
 * The shapes: libmemdraw's memline, mempoly, memfillpoly, memellipse and
 * memarc. Each breaks its shape into draws through memdraw below, so
 * erx_draw_clip clips every pixel they touch, and draws temporaries
 * (a disc brush, an arc's wedge) the same way.
 *
 * libmemdraw computes a shape in int, scaling coordinates by 2^10 for
 * the polygon fill, whose scan also forms products in long, 64 bits on
 * every erXos target. Within these limits, which erx_draw_core holds
 * every shape to, nothing it computes overflows: a point, centre or
 * source point within 2^19 of the origin, a semi-axis up to 2^14, a
 * thickness up to 2^10.
 *
 * Every pixel such a shape draws lies within SHAPE_REACH of the origin:
 * a point within 2^19, widened by at most a semi-axis (2^14) and a
 * thickness (2^10), or by an arrow head's at most 511 + 2^10, stays
 * below 2^19 + 2^15 < 2^20. A source pixel is a destination pixel plus
 * sp - p for points within 2^19, so lies within 2^20 + 2^20 = 2^21.
 */
#define SHAPE_COORD (1 << 19)
#define SHAPE_AXIS (1 << 14)
#define SHAPE_THICK (1 << 10)
#define SHAPE_REACH (1 << 20)
#define SHAPE_SOURCE_REACH (1 << 21)

/* p and P carry at most a write's worth of points, far below this. */
#define SHAPE_MAX_POINTS (1 << 20)

/*
 * One shape, as the wrappers below decode it: which algorithm, and the
 * parameters each takes (pts and n for p and P, c, a, b and the angles
 * for e and E, the ends for L and p).
 */
typedef enum shape_kind { SHAPE_LINE, SHAPE_POLY, SHAPE_FILL_POLY, SHAPE_ELLIPSE, SHAPE_ARC } shape_kind_t;

typedef struct shape_args {
	shape_kind_t kind;
	Point p0, p1, sp;	/* L's ends; e's and E's centre in p0; every shape's source point */
	const erx_point_t *pts;	/* p and P */
	size_t n;
	int end0, end1, thick;	/* thick -1 fills an ellipse or arc */
	int a, b, alpha, phi, wind;
} shape_args_t;

/*
 * The shape this thread is drawing: copies of its images' headers, the
 * union of the destination rectangles its draws touched, and whether an
 * allocation failed. draw_shape sets it around its one call into
 * libmemdraw and clears it after.
 */
typedef struct shape {
	Memimage dst, src;
	Memimage *copy;		/* the source's snapshot, when it is the destination */
	Rectangle touched;
	bool any, failed;
} shape_t;

static _Thread_local shape_t *drawing;

void
erx_memdraw_nomem(void)
{
	if (drawing != NULL)
		drawing->failed = true;
}

/*
 * libmemlayer's memdraw and memline for an image that is not a layer,
 * which erXos has no other kind of: every draw a shape makes, into its
 * destination or a temporary, is clipped here by erx_draw_clip.
 */
void
memdraw(Memimage *dst, Rectangle r, Memimage *src, Point sp, Memimage *mask, Point mp, int op)
{
	erx_clip_t clip;

	if (!erx_draw_clip(&clip, dst, dst->clipr, r, src, sp, mask, mp))
		return;
	if (memimagedraw(dst, src, mask, &clip, op) != 0) {
		erx_memdraw_nomem();
		return;
	}
	if (drawing != NULL && dst->data == drawing->dst.data) {
		if (!drawing->any)
			drawing->touched = clip.r;
		else
			combinerect(&drawing->touched, clip.r);
		drawing->any = true;
	}
}

void
memline(Memimage *dst, Point p0, Point p1, int end0, int end1, int radius, Memimage *src, Point sp, int op)
{
	memimageline(dst, p0, p1, end0, end1, radius, src, sp, op);
}

/*
 * *r becomes its intersection with b; false when that is empty. Unlike
 * rectclip, an empty or inverted r or b gives false.
 */
static bool
intersect(Rectangle *r, Rectangle b)
{
	Rectangle i = Rect(r->min.x > b.min.x ? r->min.x : b.min.x, r->min.y > b.min.y ? r->min.y : b.min.y,
	    r->max.x < b.max.x ? r->max.x : b.max.x, r->max.y < b.max.y ? r->max.y : b.max.y);

	if (i.min.x >= i.max.x || i.min.y >= i.max.y)
		return false;
	*r = i;
	return true;
}

static bool
coord_ok(erx_point_t p)
{
	return p.x >= -SHAPE_COORD && p.x < SHAPE_COORD && p.y >= -SHAPE_COORD && p.y < SHAPE_COORD;
}

static bool
axis_ok(int32_t a)
{
	return a >= 0 && a <= SHAPE_AXIS;
}

static bool
thick_ok(int32_t t, bool fill_allowed)
{
	return (t >= 0 || (fill_allowed && t == -1)) && t <= SHAPE_THICK;
}

/* Every point of p or P within the limits, and not too many of them. */
static bool
points_ok(const erx_point_t *pts, size_t n)
{
	if (n > SHAPE_MAX_POINTS)
		return false;
	for (size_t i = 0; i < n; i++)
		if (!coord_ok(pts[i]))
			return false;
	return true;
}

/*
 * The destination's clip rectangle as the shape reads it. Its columns
 * and its bottom are narrowed to the image, which changes no pixel drawn:
 * memdraw clips every span to the image anyway, and the polygon fill
 * scans its rows from the top down. Its top only to SHAPE_REACH, above
 * every row a shape draws: the fill computes each edge's position from
 * the row its scan starts at, and its rounding of a falling edge
 * (smuldivmod) depends on that row, so a top narrowed to the image could
 * change pixels. False when the shape can touch no pixel.
 */
static bool
shape_clip(Rectangle *clipr, Rectangle r)
{
	Rectangle below = Rect(r.min.x, -SHAPE_REACH, r.max.x, r.max.y);

	return intersect(clipr, Rect(-SHAPE_REACH, -SHAPE_REACH, SHAPE_REACH, SHAPE_REACH)) && intersect(clipr, below);
}

/* libmemdraw's algorithm for a over the header copies in s. */
static erx_memdraw_status_t
run_shape(shape_t *s, const shape_args_t *a, int op)
{
	Point *vert = NULL;

	if (a->kind == SHAPE_POLY || a->kind == SHAPE_FILL_POLY) {
		if ((vert = malloc((a->n > 0 ? a->n : 1) * sizeof(Point))) == nil)
			return ERX_MEMDRAW_ENOMEM;
		for (size_t i = 0; i < a->n; i++)
			vert[i] = Pt(a->pts[i].x, a->pts[i].y);
	}
	switch (a->kind) {
	case SHAPE_LINE:
		memline(&s->dst, a->p0, a->p1, a->end0, a->end1, a->thick, &s->src, a->sp, op);
		break;
	case SHAPE_POLY:
		mempoly(&s->dst, vert, (int)a->n, a->end0, a->end1, a->thick, &s->src, a->sp, op);
		break;
	case SHAPE_FILL_POLY:
		memfillpoly(&s->dst, vert, (int)a->n, a->wind, &s->src, a->sp, op);
		break;
	case SHAPE_ELLIPSE:
		memellipse(&s->dst, a->p0, a->a, a->b, a->thick, &s->src, a->sp, op);
		break;
	case SHAPE_ARC:
		memarc(&s->dst, a->p0, a->a, a->b, a->thick, &s->src, a->sp, a->alpha, a->phi, op);
		break;
	}
	free(vert);
	return ERX_MEMDRAW_DONE;
}

/*
 * The one way a shape is drawn. It copies the headers the shape reads
 * once, as erx_memdraw_draw does: the destination's with its clip
 * rectangle narrowed by shape_clip, the source's narrowed to
 * SHAPE_SOURCE_REACH, which changes no pixel and keeps libmemdraw's
 * arithmetic over them in range. A source that is the destination is
 * read from a snapshot taken before the shape, as a draw's is. The
 * thread's shape record is set only around run_shape, so memdraw
 * accounts every draw of this shape and of no other.
 */
static erx_memdraw_status_t
draw_shape(erx_mdimage_t *dsti, erx_mdimage_t *srci, const shape_args_t *a, int op, erx_rect_t *touched)
{
	const Rectangle source_reach = Rect(-SHAPE_SOURCE_REACH, -SHAPE_SOURCE_REACH, SHAPE_SOURCE_REACH,
	    SHAPE_SOURCE_REACH);
	shape_t s = { .dst = *mem(dsti) };

	if (op < 0 || op >= Ncomp)
		return ERX_MEMDRAW_EINVAL;
	if (!shape_clip(&s.dst.clipr, s.dst.r))
		return ERX_MEMDRAW_NOTHING;
	if (srci == dsti) {
		if ((s.copy = snapshot(mem(dsti))) == nil)
			return ERX_MEMDRAW_ENOMEM;
		s.src = *s.copy;
	} else {
		s.src = *mem(srci);
	}
	erx_memdraw_status_t st = ERX_MEMDRAW_NOTHING;
	if (intersect(&s.src.clipr, source_reach)) {
		drawing = &s;
		st = run_shape(&s, a, op);
		drawing = NULL;
	}
	freememimage(s.copy);
	if (s.any)
		*touched = erect(s.touched);
	if (st != ERX_MEMDRAW_DONE)
		return st;
	if (s.failed)
		return ERX_MEMDRAW_ENOMEM;
	return s.any ? ERX_MEMDRAW_DONE : ERX_MEMDRAW_NOTHING;
}

static Point
pt(erx_point_t p)
{
	return Pt(p.x, p.y);
}

erx_memdraw_status_t
erx_memdraw_line(erx_mdimage_t *dst, erx_point_t p0, erx_point_t p1, uint32_t end0, uint32_t end1, int32_t thick,
    erx_mdimage_t *src, erx_point_t sp, int op, erx_rect_t *touched)
{
	if (!coord_ok(p0) || !coord_ok(p1) || !coord_ok(sp) || !thick_ok(thick, false))
		return ERX_MEMDRAW_EINVAL;
	shape_args_t a = { .kind = SHAPE_LINE, .p0 = pt(p0), .p1 = pt(p1), .sp = pt(sp), .end0 = (int)end0,
		.end1 = (int)end1, .thick = thick };
	return draw_shape(dst, src, &a, op, touched);
}

erx_memdraw_status_t
erx_memdraw_poly(erx_mdimage_t *dst, const erx_point_t *pts, size_t n, uint32_t end0, uint32_t end1, int32_t thick,
    erx_mdimage_t *src, erx_point_t sp, int op, erx_rect_t *touched)
{
	if (!points_ok(pts, n) || !coord_ok(sp) || !thick_ok(thick, false))
		return ERX_MEMDRAW_EINVAL;
	shape_args_t a = { .kind = SHAPE_POLY, .pts = pts, .n = n, .sp = pt(sp), .end0 = (int)end0, .end1 = (int)end1,
		.thick = thick };
	return draw_shape(dst, src, &a, op, touched);
}

erx_memdraw_status_t
erx_memdraw_fill_poly(erx_mdimage_t *dst, const erx_point_t *pts, size_t n, int32_t wind, erx_mdimage_t *src,
    erx_point_t sp, int op, erx_rect_t *touched)
{
	if (!points_ok(pts, n) || !coord_ok(sp))
		return ERX_MEMDRAW_EINVAL;
	shape_args_t a = { .kind = SHAPE_FILL_POLY, .pts = pts, .n = n, .sp = pt(sp), .wind = wind };
	return draw_shape(dst, src, &a, op, touched);
}

erx_memdraw_status_t
erx_memdraw_ellipse(erx_mdimage_t *dst, erx_point_t c, int32_t a, int32_t b, int32_t thick, erx_mdimage_t *src,
    erx_point_t sp, int op, erx_rect_t *touched)
{
	if (!coord_ok(c) || !coord_ok(sp) || !axis_ok(a) || !axis_ok(b) || !thick_ok(thick, true))
		return ERX_MEMDRAW_EINVAL;
	shape_args_t s = { .kind = SHAPE_ELLIPSE, .p0 = pt(c), .sp = pt(sp), .a = a, .b = b, .thick = thick };
	return draw_shape(dst, src, &s, op, touched);
}

erx_memdraw_status_t
erx_memdraw_arc(erx_mdimage_t *dst, erx_point_t c, int32_t a, int32_t b, int32_t thick, erx_mdimage_t *src,
    erx_point_t sp, int32_t alpha, int32_t phi, int op, erx_rect_t *touched)
{
	if (!coord_ok(c) || !coord_ok(sp) || !axis_ok(a) || !axis_ok(b) || !thick_ok(thick, true))
		return ERX_MEMDRAW_EINVAL;
	shape_args_t s = { .kind = SHAPE_ARC, .p0 = pt(c), .sp = pt(sp), .a = a, .b = b, .thick = thick,
		.alpha = alpha, .phi = phi };
	return draw_shape(dst, src, &s, op, touched);
}

#ifdef ERX_MEMDRAW_CLOAD
erx_memdraw_status_t
erx_memdraw_cload(erx_mdimage_t *image, erx_rect_t r, const uint8_t *data, size_t n, size_t *consumed)
{
	size_t need;

	if (!rows_of(mem(image), r, &need) || n > INT_MAX)
		return ERX_MEMDRAW_EINVAL;
	int used = cloadmemimage(mem(image), rect(r), (uchar *)(uintptr_t)data, (int)n);
	if (used < 0)
		return ERX_MEMDRAW_EINVAL;
	*consumed = (size_t)used;
	return ERX_MEMDRAW_DONE;
}
#endif
