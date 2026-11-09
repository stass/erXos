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
