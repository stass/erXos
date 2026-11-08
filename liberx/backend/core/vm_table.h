/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_VM_TABLE_H
#define ERX_BACKEND_VM_TABLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/cdefs.h"
#include "liberx/backend/core/grow_table.h"

/*
 * The range table of a task (docs/design-stopgap.md, "The range table" and
 * "Protection"): which addresses are reserved, and which of those pages are
 * committed, on which window page and with which protection. It decides what
 * erx_vm_reserve, _commit, _decommit, _release and erx_space_protect do, and
 * tells its caller's effects which rights to map and unmap, in order.
 *
 * Three facts make up the table, and none knows another's shape:
 *
 *   ranges    The reserved addresses, as sorted, disjoint runs. Adjacent runs
 *             merge, so a range is wholly reserved exactly when one run covers it.
 *   mappings  The table's mapping records, sorted and disjoint, each an address
 *             range inside one run that shows pages of an object: the object's
 *             record index, the offset and the rights. A mapped page is never in
 *             the page index, and a call that would change one is refused whole:
 *             a commit, decommit or protect that meets a mapping, and a release
 *             (or a fixed reserve) that cuts one. A release over a whole mapping
 *             unmaps it and drops its record.
 *   pages     One hash for the machine, from a committed page's address and its
 *           table's label to its window page and protection. A page absent here is uncommitted, and has no protection
 *           to remember: access to it means committing it. Each entry owns a
 *           distinct window page, and the index has two slots for every page the
 *           window holds (erx_backend_vm_layout), so committing never finds it
 *           full and every probe ends at an empty slot.
 *
 * A call is one plan, then one apply. erx_backend_vm_plan validates the whole
 * request and counts the pages it needs, changing nothing; erx_backend_vm_call
 * refuses a plan the pool cannot cover and only then applies it, so a refused
 * call changes nothing and an applied one cannot fail. The effects it calls have
 * no way to report failure: a kernel that refuses a map the plan allows leaves
 * no state worth continuing from, and the effect ends the machine.
 *
 * This core touches only the memory it is handed and takes no lock, so it builds
 * for the host; its caller runs one call at a time.
 */

/* A reserved run of addresses, page-aligned; end is exclusive. */
typedef struct erx_backend_vm_range {
	uint64_t	start;
	uint64_t	end;
} erx_backend_vm_range_t;

/* The low bits of an address or size that lie within a page. */
#define ERX_BACKEND_VM_PAGE_MASK	((uint64_t)ERX_PAGE_SIZE - 1)

/*
 * A slot of the page index, whose key is the page's address with its table's label in
 * the low bits, which a page's address leaves clear. A key of 0 is empty: no area may
 * hold address 0.
 */
typedef struct erx_backend_vm_page {
	uint64_t	key;
	uint64_t	window_and_state;	/* a window page's address, low bits the state */
} erx_backend_vm_page_t;

/* A mapping record: [start, end) of the table shows the object's pages from offset on, with prot. */
typedef struct erx_backend_vm_mapping {
	uint64_t	start;
	uint64_t	end;
	uint64_t	offset;		/* from the object's area_start */
	uint32_t	object;		/* the object's record index, which the caller's effects name */
	uint32_t	prot;		/* ERX_PROT_R, _RW or _RX */
} erx_backend_vm_mapping_t;

typedef struct erx_backend_vm_table {
	erx_backend_grow_table_t runs;		/* erx_backend_vm_range_t, sorted and disjoint */
	uint32_t		 nranges;	/* runs in use, from the first */
	erx_backend_grow_table_t mappings;	/* erx_backend_vm_mapping_t, sorted and disjoint */
	uint32_t		 nmappings;	/* records in use, from the first */
	erx_backend_vm_page_t	*pages;
	size_t			 pages_mask;	/* slots - 1; slots are a power of two */
	uint32_t		 label;		/* below ERX_PAGE_SIZE, and no other table's */
	uint64_t		 area_start;	/* where reservations may lie */
	uint64_t		 area_end;
	uint64_t		 placement;	/* a reserve's search starts on this power of two */
} erx_backend_vm_table_t;

/* What the window's first pages must hold for an index covering the whole window. */
typedef struct erx_backend_vm_layout {
	uint64_t	index_pages;
	uint64_t	index_slots;
} erx_backend_vm_layout_t;

typedef enum erx_backend_vm_op {
	ERX_BACKEND_VM_RESERVE,
	ERX_BACKEND_VM_COMMIT,
	ERX_BACKEND_VM_DECOMMIT,
	ERX_BACKEND_VM_RELEASE,
	ERX_BACKEND_VM_PROTECT
} erx_backend_vm_op_t;

typedef struct erx_backend_vm_request {
	erx_backend_vm_op_t	op;
	uint64_t		addr;	/* a reserve without ERX_VM_FIXED ignores it */
	uint64_t		size;
	uint32_t		flags;	/* ERX_VM_*, for a reserve */
	uint32_t		prot;	/* ERX_PROT_*, for a protect */
} erx_backend_vm_request_t;

/*
 * Each state a page can be in. A protection is a committed page's; holes have no
 * state here, since no record covers them.
 */
typedef enum erx_backend_vm_state {
	ERX_BACKEND_PAGE_UNCOMMITTED,
	ERX_BACKEND_PAGE_NONE,
	ERX_BACKEND_PAGE_R,
	ERX_BACKEND_PAGE_RW,
	ERX_BACKEND_PAGE_RX
} erx_backend_vm_state_t;
#define ERX_BACKEND_PAGE_STATES	5u

/* A plan. Its range is the request's, or the one a reserve chose. */
typedef struct erx_backend_vm_plan {
	erx_backend_vm_op_t	op;
	erx_backend_vm_state_t	target;		/* what each reserved page in the range becomes */
	uint64_t		start;
	uint64_t		end;
	uint64_t		pages_needed;
	uint32_t		runs_room;	/* runs the table must have room for first, or 0 */
} erx_backend_vm_plan_t;

/*
 * What moving one page between two states takes, in this order: take and zero a
 * page, unmap the rights in drop (ERX_PROT_* bits), map the page with map
 * (ERX_PROT_*; none means no map), give the page back. A map only ever adds
 * rights, so a change in both directions drops first. Moving an uncommitted page
 * to no access changes nothing: it stays uncommitted, as `after` says.
 */
typedef struct erx_backend_vm_steps {
	bool			take;
	bool			give_back;
	uint8_t			drop;
	uint8_t			map;
	erx_backend_vm_state_t	after;
} erx_backend_vm_steps_t;

/* The kernel-facing half, in the space of the table's label. Each ends the machine rather than report a refusal. */
typedef struct erx_backend_vm_effects {
	void	(*map)(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot);
	void	(*unmap)(uint32_t label, uint64_t addr, uint32_t rights);
	/* A page for addr, reading zeros, its address page-aligned and nonzero. The plan counted it, so there is one. */
	uintptr_t (*take)(uint64_t addr);
	/* Gives back the page addr held; nothing maps it any more. */
	void	(*give)(uintptr_t window, uint64_t addr);
	uint64_t (*free_pages)(void);
	/*
	 * A mapping of the object at this record index is gone: its pages are unmapped and its
	 * record dropped. It may change other tables and the shared index, ending the object
	 * included, but never this table, which is mid-call.
	 */
	void	(*unmapped)(uint32_t object);
} erx_backend_vm_effects_t;

/* The index a window of this many pages needs; never empty. */
erx_backend_vm_layout_t	erx_backend_vm_layout(uint64_t);

/* Empties the machine's index, of a power of two slots. Every table then shares it. */
void	erx_backend_vm_index_init(erx_backend_vm_page_t *, size_t);

/*
 * An empty table of this label over [area_start, area_end), in an index whose pages
 * hold none of the label's. The caller keeps the index and records for the table's
 * life: the runs take pages from records as they fill, until the table is cleared. A
 * reserve's search starts on ERX_PAGE_SIZE boundaries; a caller whose own pages are
 * larger sets the table's placement to that size, a power of two, before its first
 * reserve.
 */
void	erx_backend_vm_table_init(erx_backend_vm_table_t *, uint32_t, erx_backend_vm_page_t *, size_t, uint64_t,
	    uint64_t, const erx_backend_grow_pages_t *records);

erx_backend_vm_steps_t	erx_backend_vm_steps(erx_backend_vm_state_t, erx_backend_vm_state_t);

/*
 * Plans a request, changing nothing. Refuses:
 *
 *   ERX_EINVAL  an address or size not page-aligned, a size of zero, unknown
 *               flags, ERX_VM_NOREPLACE without ERX_VM_FIXED, or a protection
 *               other than none, R, RW and RX, write with execute among them;
 *               a commit or decommit that meets a mapping, or a release or a
 *               fixed reserve that covers part of one;
 *   ERX_ENOTSUP a protect that meets a mapping;
 *   ERX_ERANGE  a range outside the area, wrapping included, or a protect that
 *               meets a hole;
 *   ERX_EEXIST  a reserve with ERX_VM_NOREPLACE that overlaps a run;
 *   ERX_ENOMEM  a reserve, or a release that splits a run, with the runs at their
 *               table's limit, or no free range of the size.
 *
 * Commit and decommit act on the reserved pages in the range and pass over holes.
 */
int	erx_backend_vm_plan(const erx_backend_vm_table_t *, const erx_backend_vm_request_t *,
	    erx_backend_vm_plan_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Carries out a request whole, or refuses it with nothing changed: the plan's
 * refusals, and ERX_ENOMEM when the records cannot give a page for a run the call
 * adds or the pool holds fewer pages than the plan needs.
 * A reserve reports its address in the last argument, which it may leave NULL.
 */
int	erx_backend_vm_call(erx_backend_vm_table_t *,
	    const erx_backend_vm_effects_t *, const erx_backend_vm_request_t *,
	    uint64_t *) ERX_WARN_UNUSED_RESULT;

/* The window page behind a committed address of the table, or 0 for any other. */
uintptr_t	erx_backend_vm_window(const erx_backend_vm_table_t *, uint64_t);

/*
 * Maps pages of an object, itself a table whose committed pages it owns, at reserved
 * addresses of another table that hold neither a committed page nor a mapping, and
 * records the mapping under the object's record index, whole or not at all. The page
 * index does not hold such a page, as a slot there owns its page; the object keeps it.
 * The offset counts from the object's area_start. Refuses:
 *
 *   ERX_EINVAL  a size of zero, an address, size or offset not page-aligned, a
 *               protection other than R, RW and RX, or a committed page or a
 *               mapping among the addresses;
 *   ERX_ERANGE  addresses not wholly reserved, or pages the object does not hold,
 *               an offset that wraps included;
 *   ERX_ENOMEM  no room for one more mapping record.
 */
int	erx_backend_vm_map_object(erx_backend_vm_table_t *, const erx_backend_vm_table_t *, uint32_t,
	    const erx_backend_vm_effects_t *, uint64_t, uint64_t, uint64_t, uint32_t) ERX_WARN_UNUSED_RESULT;

/*
 * Drops every mapping record of the object at this record index, with no effect: the
 * caller has already removed the pages from every space at once, as a revoke does.
 */
void	erx_backend_vm_forget_object(erx_backend_vm_table_t *, uint32_t);

/* How many mapping records of the object at this record index the table holds. */
uint32_t	erx_backend_vm_mappings_of(const erx_backend_vm_table_t *, uint32_t);

/*
 * Releases every run, mappings included, so the table's pages and its records' pages go
 * back and its label is free.
 */
void	erx_backend_vm_table_clear(erx_backend_vm_table_t *, const erx_backend_vm_effects_t *);

#endif /* ERX_BACKEND_VM_TABLE_H */
