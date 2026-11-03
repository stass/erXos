/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_TLB_PLAN_H
#define ERX_TLB_PLAN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The invalidation planner turns the list of translation-table entries a
 * removal clears into the invalidations that drop every cached copy they
 * make stale, from one space's TLB or one DMA window's IOMMU TLB. It is
 * pure. The removal's caller plans while it validates the rest of the
 * removal, before it writes any entry, so a refusal aborts the removal with
 * nothing changed; it then clears the entries, issues the plan through the
 * binding, waits for completion and only then frees what the entries
 * covered.
 */

typedef struct erx_tlb_cleared erx_tlb_cleared_t;
typedef struct erx_tlb_inval erx_tlb_inval_t;
typedef struct erx_tlb_plan erx_tlb_plan_t;
typedef struct erx_tlb_removal erx_tlb_removal_t;

enum erx_tlb_cleared_kind {
	/* A last-level entry that mapped one page; its table stays. */
	ERX_TLB_CLEARED_PAGE = 1,
	/* An entry that pointed to a table, detached whole or freed empty. */
	ERX_TLB_CLEARED_TABLE = 2
};
typedef enum erx_tlb_cleared_kind erx_tlb_cleared_kind_t;

/*
 * How deep one invalidation reaches. A last-level invalidation drops only
 * cached translations of pages. An every-level invalidation also drops the
 * walk-cache copies of table entries used for its addresses, which a CPU or
 * IOMMU may otherwise follow into a freed table. A whole-ASID invalidation
 * drops everything cached for the plan's ASID.
 */
enum erx_tlb_reach {
	ERX_TLB_LAST_LEVEL = 1,
	ERX_TLB_EVERY_LEVEL = 2,
	ERX_TLB_WHOLE_ASID = 3
};
typedef enum erx_tlb_reach erx_tlb_reach_t;

/* One entry the removal cleared, with the address range it covered. */
struct erx_tlb_cleared {
	uint64_t		 va;	/* first address the entry covered */
	uint64_t		 span;	/* bytes: one page, or the table's span */
	erx_tlb_cleared_kind_t	 kind;
	bool			 global;	/* the entry was not ASID-tagged */
};

/*
 * A removal from one space or DMA window. range_pages_max is what the
 * invalidating hardware offers: the largest power-of-two number of pages
 * one invalidation by address may cover, 1 where it invalidates one page
 * at a time.
 */
struct erx_tlb_removal {
	const erx_tlb_cleared_t	*cleared;
	size_t			 ncleared;
	uint64_t		 range_pages_max;
	uint32_t		 asid;
};

/*
 * One invalidation of pages [va, va + pages * ERX_PAGE_SIZE) for the plan's
 * ASID; a whole-ASID invalidation has va and pages zero. Every by-address
 * invalidation covers a power-of-two page count no larger than the
 * removal's range_pages_max, at an address aligned to that count.
 */
struct erx_tlb_inval {
	uint64_t	 va;
	uint64_t	 pages;
	erx_tlb_reach_t	 reach;
};

/*
 * A complete plan. A plan that would need more than
 * ERX_TLB_BY_ADDRESS_MAX invalidations by address is one whole-ASID
 * invalidation instead, so the array always has room.
 */
struct erx_tlb_plan {
	uint32_t	 asid;
	uint32_t	 ninvals;
	erx_tlb_inval_t	 invals[ERX_TLB_BY_ADDRESS_MAX];
};

/*
 * Returns 0 with a complete plan, or ERX_EINVAL with an empty plan for a
 * malformed removal, which must then not proceed.
 */
int erx_tlb_plan(const erx_tlb_removal_t *, erx_tlb_plan_t *)
    ERX_WARN_UNUSED_RESULT;

#endif /* ERX_TLB_PLAN_H */
