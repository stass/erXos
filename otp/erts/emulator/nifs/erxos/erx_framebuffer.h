/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A firmware framebuffer as another static NIF of the runtime sees it
 * (docs/design-runtime.md, "The framebuffer"): the memory a board's
 * firmware set up and its display hardware scans out, mapped as device
 * memory. erx_device_nif.c maps it; erx_memdraw's NIF stores rectangles of
 * the screen image into it through erx_framebuffer_view alone, with
 * aligned 32-bit stores, and never makes an image over it. A framebuffer
 * is kept for the boot, so a holder keeps its base without a reference.
 */
#ifndef ERX_FRAMEBUFFER_H
#define ERX_FRAMEBUFFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erl_nif.h"

typedef struct erx_framebuffer_view {
	volatile uint8_t *base;	/* the framebuffer's first byte */
	size_t bytes;		/* its length, the record's SIZE */
} erx_framebuffer_view_t;

/* The framebuffer a term names, erx_device:framebuffer/0's Fb, or false for a term that is none. */
bool erx_framebuffer_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_framebuffer_view_t *out);

#endif /* ERX_FRAMEBUFFER_H */
