/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lease's core (docs/design-display.md, "The pixel area", The lease): the
 * decisions of a lease of a pixel area's range to one program, with no ERTS
 * and no kernel in them, so a host test explores every order of their events.
 * erx_area_nif.c holds the effects: the table, its lock, the monitor, the
 * mapping, the message and the resource references.
 *
 * A lease is held, taken or returned. Each state is left by one transition
 * only, so a lease is taken at most once, only by its holder's port while it
 * is held, and returned exactly once: by the holder's exit or a give-back
 * while held, by the driver's return while taken. Every other event leaves
 * the state as it is and does nothing. The caller runs each step under the
 * one lock of the table the lease lives in.
 */

#ifndef ERX_AREA_LEASE_CORE_H
#define ERX_AREA_LEASE_CORE_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
	ERX_LEASE_HELD = 1,	/* in the table, waiting for its holder's port */
	ERX_LEASE_TAKEN,	/* one program port's driver has it */
	ERX_LEASE_RETURNED	/* out of the table; no event moves it again */
} erx_lease_state_t;

typedef enum {
	ERX_LEASE_TAKE = 1,	/* a port's start asks for the lease by its number */
	ERX_LEASE_HOLDER_EXIT,	/* the lease's down callback: its holder has exited */
	ERX_LEASE_GIVE_BACK,	/* erx_area:unlend/1 */
	ERX_LEASE_DRIVER_RETURN	/* the driver, after the program's anchor is destroyed */
} erx_lease_event_t;

typedef struct {
	erx_lease_state_t	next;
	bool			taken;		/* this step hands the lease to the asking port */
	bool			returned;	/* this step is the lease's one return */
} erx_lease_step_t;

/*
 * The step event makes from state. eligible matters to ERX_LEASE_TAKE alone:
 * the port's owner is the lease's holder and the take asks for the lease's
 * own length.
 */
erx_lease_step_t	erx_lease_step(erx_lease_state_t state, erx_lease_event_t event, bool eligible);

/*
 * erx_area:lend/4's check of a range against its area: true for offset on a
 * page boundary, pages from 1 to the pages of ERX_PROG_MEM_BYTES, and the
 * range's end, offset + pages * page in checked arithmetic, at or before
 * area_bytes; false for any other range and for an area that is not
 * writable. page is the area's page size, a power of two.
 */
bool	erx_lease_range_ok(uint64_t offset, uint64_t pages, uint64_t page, uint64_t area_bytes, bool writable);

#endif /* ERX_AREA_LEASE_CORE_H */
