/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A device's region as another static NIF of the runtime sees it
 * (docs/design-runtime.md, "Regions"): memory of the device's record that
 * the device reads whenever a request names it, such as a virtio-gpu
 * resource's backing. erx_device_nif.c makes regions; erx_memdraw's NIF
 * builds images over one through erx_region_view alone. A region is kept
 * for the boot and never freed, so a holder keeps its base without a
 * reference. Its device address is never part of the view.
 */
#ifndef ERX_REGION_H
#define ERX_REGION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erl_nif.h"

typedef struct erx_region_view {
	uint8_t *base;		/* the mapping's first byte, on a page boundary */
	size_t bytes;		/* the region's length, whole pages */
	size_t page;		/* the page size the region is made of */
} erx_region_view_t;

/* The region a term names, erx_device:region/3's R, or false for a term that is none. */
bool erx_region_view(ErlNifEnv *env, ERL_NIF_TERM term, erx_region_view_t *out);

#endif /* ERX_REGION_H */
