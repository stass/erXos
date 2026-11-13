/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A connection's pixel area as another static NIF of the runtime sees it
 * (docs/design-display.md, "The pixel area"). erx_area_nif.c maps the
 * area for the connection agent and makes it a resource; erx_memdraw's
 * NIF builds images over it through erx_area_view alone. A holder that
 * keeps the view's base past the NIF call keeps the resource too, with
 * enif_keep_resource(view.resource), and releases it with
 * enif_release_resource once it no longer uses the base: the area is
 * unmapped only when the last reference, term or kept, is gone.
 */
#ifndef ERX_AREA_H
#define ERX_AREA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erl_nif.h"

typedef struct erx_area_view {
	void *resource;		/* for enif_keep_resource and enif_release_resource */
	uint8_t *base;		/* the mapping's first byte, on a page boundary */
	size_t bytes;		/* the mapping's length, whole pages */
	size_t page;		/* the page size the mapping is made of */
	bool writable;		/* false for the reader's read-only mapping */
} erx_area_view_t;

/* The mapping term names, or false for a term that is no area. */
bool erx_area_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_area_view_t *out);

#endif /* ERX_AREA_H */
