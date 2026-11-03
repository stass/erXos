/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The invalidation planner.
 *
 * A removal clears translation-table entries of one space (or one DMA
 * window) and lists each entry it will clear with its kind and the
 * addresses it covers. What a cleared entry leaves behind in a TLB follows
 * from its kind alone:
 *
 *  - A cleared page entry leaves at most a cached translation of that one
 *    page. A last-level invalidation of the page drops it.
 *  - A cleared table entry leaves cached translations of any page beneath
 *    it, and walk-cache copies of itself and of every table entry beneath
 *    it. A walk-cache copy outlives the table it points to, so a CPU or
 *    IOMMU could later walk the freed table after it holds someone else's
 *    data. Only an invalidation that reaches every level drops walk-cache
 *    copies, and it must cover every page of the entry's span, because a
 *    copy of a lower table entry is found only through the addresses that
 *    table covers.
 *
 * The plan is therefore one last-level invalidation per cleared page and,
 * per cleared table, every-level invalidations covering its whole span, in
 * pieces no larger than one invalidation of the hardware may cover. When
 * that would take more than ERX_TLB_BY_ADDRESS_MAX invalidations by
 * address, one invalidation of the whole ASID covers everything instead:
 * the plan is built in one pass, and the first invalidation that finds the
 * plan full turns it into that one. So the plan's array bound is checked
 * where it is written, and the pass stops after at most
 * ERX_TLB_BY_ADDRESS_MAX + 1 attempts however many entries the removal
 * lists.
 *
 * The removal is validated whole before anything is planned, so a plan is
 * either complete or not produced. Invalidations keep the order of the
 * cleared entries; the caller waits for all of them to complete at once,
 * so their order does not affect what is dropped.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/tlb_plan.h"

/* ASIDs are compared with a 64-bit limit and stored in 32 bits. */
_Static_assert(ERX_ARCH_ASID_BITS < 32, "ASID width exceeds erx_tlb_plan_t");

static bool erx_tlb_add(erx_tlb_plan_t *, uint64_t, uint64_t,
    erx_tlb_reach_t);
static bool erx_tlb_add_cleared(erx_tlb_plan_t *, const erx_tlb_cleared_t *,
    uint64_t);
static bool erx_tlb_cleared_valid(const erx_tlb_cleared_t *);
static bool erx_tlb_power_of_two(uint64_t);
static bool erx_tlb_removal_valid(const erx_tlb_removal_t *);

static bool
erx_tlb_power_of_two(uint64_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

/*
 * The removal names a real ASID, ASID 0 being reserved for the empty table
 * that never maps anything; the hardware's range limit is a power of two,
 * so the pieces of a table's span tile it exactly; and every entry is
 * valid. The entries live in the caller's private memory and are read
 * again when the plan is built.
 */
static bool
erx_tlb_removal_valid(const erx_tlb_removal_t *removal)
{
	if (removal->cleared == NULL && removal->ncleared != 0)
		return (false);

	if (removal->asid == 0 ||
	    removal->asid >= UINT64_C(1) << ERX_ARCH_ASID_BITS)
		return (false);

	if (!erx_tlb_power_of_two(removal->range_pages_max))
		return (false);

	for (size_t i = 0; i < removal->ncleared; i++) {
		if (!erx_tlb_cleared_valid(&removal->cleared[i]))
			return (false);
	}
	return (true);
}

/*
 * A valid entry is ASID-tagged: a global entry is shared by every ASID, so
 * no invalidation this plan can express would drop it, and no user or
 * DMA-window mapping is global. A page entry covers exactly one page. A
 * table entry covers a power-of-two count of at least two pages. Either is
 * aligned to its span and ends at or below the top of the user half, which
 * also bounds a DMA window, whose tables have the CPU's format.
 */
static bool
erx_tlb_cleared_valid(const erx_tlb_cleared_t *entry)
{
	uint64_t end;

	if (entry->global)
		return (false);

	switch (entry->kind) {
	case ERX_TLB_CLEARED_PAGE:
		if (entry->span != ERX_PAGE_SIZE)
			return (false);
		break;
	case ERX_TLB_CLEARED_TABLE:
		if (!erx_tlb_power_of_two(entry->span) ||
		    entry->span < 2 * (uint64_t)ERX_PAGE_SIZE)
			return (false);
		break;
	default:
		return (false);
	}

	if (entry->va % entry->span != 0)
		return (false);
	if (__builtin_add_overflow(entry->va, entry->span, &end) ||
	    end > ERX_ARCH_USER_LIMIT)
		return (false);
	return (true);
}

/* Appends one invalidation; returns false, adding nothing, when full. */
static bool
erx_tlb_add(erx_tlb_plan_t *plan, uint64_t va, uint64_t pages,
    erx_tlb_reach_t reach)
{
	if (plan->ninvals == ERX_TLB_BY_ADDRESS_MAX)
		return (false);

	plan->invals[plan->ninvals] = (erx_tlb_inval_t){
		.va = va,
		.pages = pages,
		.reach = reach
	};
	plan->ninvals++;
	return (true);
}

/*
 * Appends what one valid entry needs: a last-level invalidation of its
 * page, or every-level invalidations over a table's span in pieces of the
 * span or the hardware's limit, whichever is smaller. Returns false as soon
 * as the plan is full, so the piece loop runs at most
 * ERX_TLB_BY_ADDRESS_MAX + 1 times. va + span cannot wrap: validation
 * checked it.
 */
static bool
erx_tlb_add_cleared(erx_tlb_plan_t *plan, const erx_tlb_cleared_t *entry,
    uint64_t range_pages_max)
{
	uint64_t piece_bytes, piece_pages, span_pages;

	if (entry->kind == ERX_TLB_CLEARED_PAGE)
		return (erx_tlb_add(plan, entry->va, 1, ERX_TLB_LAST_LEVEL));

	span_pages = entry->span / ERX_PAGE_SIZE;
	piece_pages = span_pages < range_pages_max ? span_pages :
	    range_pages_max;
	piece_bytes = piece_pages * ERX_PAGE_SIZE;
	for (uint64_t va = entry->va; va < entry->va + entry->span;
	    va += piece_bytes) {
		if (!erx_tlb_add(plan, va, piece_pages, ERX_TLB_EVERY_LEVEL))
			return (false);
	}
	return (true);
}

int
erx_tlb_plan(const erx_tlb_removal_t *removal, erx_tlb_plan_t *plan)
{
	plan->asid = 0;
	plan->ninvals = 0;
	if (!erx_tlb_removal_valid(removal))
		return (ERX_EINVAL);
	plan->asid = removal->asid;

	for (size_t i = 0; i < removal->ncleared; i++) {
		if (erx_tlb_add_cleared(plan, &removal->cleared[i],
		    removal->range_pages_max))
			continue;

		/* More than the bound by address: drop the whole ASID. */
		plan->invals[0] = (erx_tlb_inval_t){
			.reach = ERX_TLB_WHOLE_ASID
		};
		plan->ninvals = 1;
		break;
	}
	return (0);
}
