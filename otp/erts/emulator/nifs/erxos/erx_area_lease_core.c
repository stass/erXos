/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lease's core: see erx_area_lease_core.h.
 */

#include "erx_area_lease_core.h"

#include "erx/abi.h"

erx_lease_step_t
erx_lease_step(erx_lease_state_t state, erx_lease_event_t event, bool eligible)
{
	erx_lease_step_t stay = { .next = state, .taken = false, .returned = false };

	switch (state) {
	case ERX_LEASE_HELD:
		if (event == ERX_LEASE_TAKE && eligible)
			return ((erx_lease_step_t){ .next = ERX_LEASE_TAKEN, .taken = true, .returned = false });
		if (event == ERX_LEASE_HOLDER_EXIT || event == ERX_LEASE_GIVE_BACK)
			return ((erx_lease_step_t){ .next = ERX_LEASE_RETURNED, .taken = false, .returned = true });
		return (stay);
	case ERX_LEASE_TAKEN:
		/* The program maps the range: only the driver, after the anchor's destroy, ends it. */
		if (event == ERX_LEASE_DRIVER_RETURN)
			return ((erx_lease_step_t){ .next = ERX_LEASE_RETURNED, .taken = false, .returned = true });
		return (stay);
	case ERX_LEASE_RETURNED:
		return (stay);
	}
	return (stay);
}

bool
erx_area_range_ok(uint64_t offset, uint64_t pages, uint64_t page, uint64_t area_bytes, bool writable)
{
	uint64_t bytes, end;

	if (!writable || offset % page != 0 || pages == 0)
		return (false);
	if (__builtin_mul_overflow(pages, page, &bytes) || __builtin_add_overflow(offset, bytes, &end))
		return (false);
	return (end <= area_bytes);
}

bool
erx_lease_range_ok(uint64_t offset, uint64_t pages, uint64_t page, uint64_t area_bytes, bool writable)
{
	return (pages <= ERX_PROG_MEM_BYTES / page && erx_area_range_ok(offset, pages, page, area_bytes, writable));
}
