/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_memdraw: the pixel primitives of the display domain
 * (docs/design-display.md, "The window process" and "The pixel
 * primitives"), erXos's copy of 9front's libmemdraw (display/libmemdraw)
 * behind an interface of erXos's own types, so the NIF that calls it
 * includes no Plan 9 header.
 *
 * The caller is the window process, which performs operations that
 * erx_draw_core planned and checked, so coordinates are 32-bit and
 * channels and images are ones the core admitted. Each function still
 * refuses what would take it outside an image: every draw is clipped by
 * erx_draw_clip before any pixel is touched, and a load or read lies
 * inside its image. Each image is used by one thread at a time (G2).
 */
#ifndef ERX_MEMDRAW_H
#define ERX_MEMDRAW_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct erx_rect {
	int32_t x0, y0, x1, y1;
} erx_rect_t;

typedef struct erx_point {
	int32_t x, y;
} erx_point_t;

/* An image: a libmemdraw Memimage that owns its pixels. */
typedef struct erx_mdimage erx_mdimage_t;

/* The outcome of an operation that touches pixels. */
typedef enum erx_memdraw_status {
	ERX_MEMDRAW_DONE,	/* pixels inside *touched were written */
	ERX_MEMDRAW_NOTHING,	/* the clipped rectangle is empty */
	ERX_MEMDRAW_EINVAL,	/* refused: bad channel, rectangle or length */
	ERX_MEMDRAW_ENOMEM,
} erx_memdraw_status_t;

/* libmemdraw's tables and its 1x1 images; once, before any other call. */
bool erx_memdraw_init(void);

/*
 * A new image of channel chan over r, its pixels and row padding zero,
 * then filled with the RGBA color unless color is draw(3)'s DNofill.
 * EINVAL for a channel libmemdraw does not read and write as draw(2)
 * defines it (erx_memdraw_chan_supported) or an r 9front's badrect
 * refuses.
 */
erx_memdraw_status_t erx_memdraw_alloc(erx_mdimage_t **out, uint32_t chan, erx_rect_t r, erx_rect_t clipr,
    bool repl, uint32_t color);
void erx_memdraw_free(erx_mdimage_t *image);
bool erx_memdraw_chan_supported(uint32_t chan);

/* c: the replicate bit and clip rectangle as they stand after it. */
void erx_memdraw_set_clip(erx_mdimage_t *image, bool repl, erx_rect_t clipr);

/*
 * d: compose src through mask (NULL: opaque) onto r of dst with
 * draw(2)'s operation op, src's point sp and mask's point mp aligned
 * with r's corner, clipped to *clipr in place of dst's clip rectangle
 * when clipr is not NULL. *touched is the clipped rectangle written.
 */
erx_memdraw_status_t erx_memdraw_draw(erx_mdimage_t *dst, erx_rect_t r, erx_mdimage_t *src, erx_point_t sp,
    erx_mdimage_t *mask, erx_point_t mp, int op, const erx_rect_t *clipr, erx_rect_t *touched);

/* y: r's pixels, bytesperline(r) bytes a row, into image; r is touched. */
erx_memdraw_status_t erx_memdraw_load(erx_mdimage_t *image, erx_rect_t r, const uint8_t *data, size_t n,
    erx_rect_t *touched);

/* r: the size of r's pixels, then the pixels into out[0..n). */
erx_memdraw_status_t erx_memdraw_unload_size(const erx_mdimage_t *image, erx_rect_t r, size_t *n);
erx_memdraw_status_t erx_memdraw_unload(const erx_mdimage_t *image, erx_rect_t r, uint8_t *out, size_t n);

/*
 * The destination bytes an operation would touch: the caller moves one
 * over 64 KiB to a dirty scheduler. 0 when it touches nothing or would
 * be refused.
 */
size_t erx_memdraw_draw_bytes(const erx_mdimage_t *dst, erx_rect_t r, const erx_mdimage_t *src, erx_point_t sp,
    const erx_mdimage_t *mask, erx_point_t mp, const erx_rect_t *clipr);
size_t erx_memdraw_rect_bytes(const erx_mdimage_t *image, erx_rect_t r);

#ifdef ERX_MEMDRAW_CLOAD
/*
 * Test tool only, linked into no release: 9front's cloadmemimage, the
 * oracle of erx_draw_image's decoding of Y. *consumed is the bytes of
 * data the codes took.
 */
erx_memdraw_status_t erx_memdraw_cload(erx_mdimage_t *image, erx_rect_t r, const uint8_t *data, size_t n,
    size_t *consumed);
#endif

#endif
