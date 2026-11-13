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

/*
 * A lease of a whole range of an area to one program (docs/design-display.md,
 * "The pixel area", The lease), made by erx_area:lend/4 for erx_pixels and
 * kept in the area NIF's table under a number of its own. The program driver,
 * erx_program_drv.c, alone calls the three functions below, under its port's
 * lock, so the one lock order is the port's lock, then the table's. A driver
 * never sees the area's capability: it holds the lease, and the lease keeps
 * the area's resource until its return.
 */
typedef struct erx_area_lease erx_area_lease_t;

/*
 * Takes the held lease number for a port whose owner, as driver_connected
 * names it, is owner, asking for pages pages; answers the lease, now taken,
 * which the driver keeps until erx_area_lease_return. NULL, changing
 * nothing, for a number with no lease, a lease taken or returned, an owner
 * that is not the lease's holder, a length other than the lease's, and any
 * take before the area NIF has loaded, when no lease can exist yet.
 */
erx_area_lease_t *erx_area_lease_take(uint64_t number, ERL_NIF_TERM owner, uint64_t pages);

/*
 * Maps the taken lease's range, read-write, into space at the buffer place,
 * ERX_PROG_MEM_BASE, reserved with ERX_VM_FIXED | ERX_VM_NOREPLACE: ERX_OK,
 * or the status of the reserve or the map, after which nothing of the range
 * is reserved or mapped in space. The mapping ends with space, which the
 * driver destroys before it returns the lease.
 */
int erx_area_lease_map(const erx_area_lease_t *lease, uint64_t space);

/*
 * Returns a taken lease: called once, after the driver has destroyed the
 * program's anchor, or as the last undo of a start that failed after the
 * take. The lease leaves the table, its lender is sent
 * {erx_area_returned, Number}, and the area's resource is let go of; the
 * driver does not use lease afterwards.
 */
void erx_area_lease_return(erx_area_lease_t *lease);

#endif /* ERX_AREA_H */
