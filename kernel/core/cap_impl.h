/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CAP_IMPL_H
#define ERX_CAP_IMPL_H

/*
 * The capability core's table record. Only kernel/core/cap.c includes
 * this file (and the core's host tests), which the cap-table-private
 * chokepoint enforces, so every write of a table's directory, counts,
 * free list and emptied flag is in cap.c (B4). Everywhere else a table is
 * the incomplete type erx/cap.h declares.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/cap.h"

/*
 * pages is the directory the caller handed to erx_cap_table_init, of
 * npages_max page pointers, enough for limit slots; each page added holds
 * ERX_CAP_PAGE_SLOTS slots and never moves. capacity counts the slots of
 * the pages added so far, and grows only after their slots are
 * initialised, so a lookup that reads it reads initialised slots. The
 * free list is FIFO by slot index, 0 ending it, so generations advance
 * evenly across slots. emptied is set once, by the emptying of the
 * table's space; nothing is installed after it.
 */
struct erx_cap_table {
	_Atomic(erx_cap_slot_t *) *pages;
	uint32_t	 npages_max;
	_Atomic uint32_t capacity;
	uint32_t	 limit;
	uint32_t	 free_head;
	uint32_t	 free_tail;
	uint32_t	 nfree;
	bool		 emptied;
};

#endif /* ERX_CAP_IMPL_H */
