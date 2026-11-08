/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: erx_cap_read, the one lookup's check of a capability
 * value (kernel/core/cap.c), over every value, every slot state, both
 * readers (with and without the caller's own objects) and every type and
 * rights argument.
 *
 * Bounds: a table of limit 2 to 2 * ERX_CAP_PAGE_SLOTS slots over a
 * two-page directory with one page added, so a value whose slot lies at
 * or past the capacity meets either a slot of the page, which the harness
 * may make live, or no page at all. Table set-up runs its loops over one
 * page; the roster's unwind set bounds them and the sequence-count loop
 * of cap_read_slot.
 *
 * Assumptions: the slot read is quiescent, its count even or terminal:
 * CBMC runs one thread, so an odd count would make the sequence-count
 * loop spin for ever. The retry under a concurrent writer is therefore not
 * checked here; with that assumption one pass of the loop always ends it,
 * and the unwinding assertion of a bound of two proves it. The slot's
 * fields are otherwise free, a superset of what the writers leave.
 *
 * Checked: no out-of-bounds or null access for any value; a lookup
 * succeeds only for a live slot below the capacity at the value's
 * generation, or for a reserved value the caller's own objects resolve;
 * the view is that slot's state, with exactly its rights, so a read never
 * adds a right (K2); the type and rights checks hold; a refused lookup
 * writes no view.
 */

#include "cbmc_harness.h"
#include "cap.c"

#define DIRECTORY_PAGES	2
/* What a view holds until a lookup writes it. */
#define UNWRITTEN	7

static erx_cap_table_t table;
static _Atomic(erx_cap_slot_t *) directory[DIRECTORY_PAGES];
static erx_cap_slot_t page[ERX_CAP_PAGE_SLOTS];

void
harness(void)
{
	uint32_t limit = nondet_u32();
	uint32_t index = nondet_u32();
	uint64_t seq = nondet_u64();
	cap_fields_t stored = {
		.object = nondet_u64(),
		.generation = nondet_u64(),
		.rights = nondet_u32(),
		.type = nondet_u32(),
		.state = nondet_u32(),
	};
	erx_cap_self_t own = { .space = nondet_u64(), .thread = nondet_u64() };
	const erx_cap_self_t *self = nondet_bool() ? &own : NULL;
	erx_cap_t cap = { .raw = nondet_u64() };
	erx_ktype_t type = nondet_u32();
	uint32_t required = nondet_u32();
	erx_cap_view_t view = { .object = UNWRITTEN, .slot = UNWRITTEN };
	uint32_t named = (uint32_t)(cap.raw & CAP_SLOT_MASK);
	bool reserved;
	erx_status_t status;

	__CPROVER_assume(limit >= 2 && limit <= DIRECTORY_PAGES * ERX_CAP_PAGE_SLOTS);
	__CPROVER_assume(erx_cap_table_init(&table, directory,
	    sizeof(directory), limit) == ERX_OK);
	__CPROVER_assume(erx_cap_table_add_page(&table, page,
	    sizeof(page)) == ERX_OK);

	/*
	 * One slot of the page takes any quiescent state, at or past the
	 * capacity too, so a lookup that reads past it can find a live slot.
	 */
	__CPROVER_assume(index >= 1 && index < ERX_CAP_PAGE_SLOTS);
	__CPROVER_assume(seq % 2 == 0 || seq == ERX_CAP_SLOT_SEQ_TERMINAL);
	cap_store_fields(&page[index], &stored);
	(void)erx_cap_slot_seq_store(&page[index], seq);

	reserved = self != NULL && ((cap.raw == ERX_CAP_SELF && own.space != 0) ||
	    (cap.raw == ERX_CAP_SELF_THREAD && own.thread != 0));
	status = erx_cap_read(&table, self, cap, type, required, &view);

	if (status != ERX_OK) {
		__CPROVER_assert(view.object == UNWRITTEN && view.slot == UNWRITTEN,
		    "a refused lookup writes no view");
		__CPROVER_assert(status == ERX_ESTALE || status == ERX_ETYPE ||
		    status == ERX_ERIGHTS, "a lookup refuses with its three statuses");
		return;
	}
	__CPROVER_assert(type == ERX_CAP_ANY_TYPE || view.type == type,
	    "a lookup returns only the type asked for");
	__CPROVER_assert((view.rights.bits & required) == required,
	    "a lookup returns only a capability with the rights asked for");
	__CPROVER_assert(view.generation == cap.raw >> ERX_CAP_SLOT_BITS,
	    "the view is at the value's generation");
	if (reserved) {
		erx_create_kind_t kind = cap.raw == ERX_CAP_SELF ?
		    ERX_KIND_RESERVED_SPACE : ERX_KIND_RESERVED_THREAD;

		__CPROVER_assert(view.slot == 0 &&
		    view.object == (cap.raw == ERX_CAP_SELF ? own.space : own.thread) &&
		    view.rights.bits == erx_kind_default_mask(kind),
		    "a reserved value names the caller's own object, in no slot");
		return;
	}
	__CPROVER_assert(named >= 1 && named < atomic_load_explicit(
	    &table.capacity, memory_order_relaxed),
	    "a lookup succeeds only below the capacity");
	if (named != index)
		return;	/* the other slots are fresh: free at generation 0 */
	__CPROVER_assert(seq != ERX_CAP_SLOT_SEQ_TERMINAL,
	    "a retired count never reads as live");
	__CPROVER_assert(stored.state == ERX_CAP_SLOT_STATE_LIVE &&
	    stored.generation == view.generation,
	    "a lookup succeeds only for a live slot at its generation");
	__CPROVER_assert(view.slot == index && view.object == stored.object &&
	    view.type == stored.type && view.rights.bits == stored.rights,
	    "the view is the slot's state, with exactly its rights");
}
