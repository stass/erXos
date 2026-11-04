/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_MAP_H
#define ERX_MAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/budget.h"
#include "erx/cdefs.h"

/*
 * The mapping-record core: a space's tree of mapping records and the plans
 * that edit it (docs/design-kernel.md, "Memory" and "Virtual memory"). It
 * decides what a range call does to the records and applies that decision.
 * It reads no hardware, takes no lock and writes no translation; its caller
 * holds the space's lock. It never dereferences a memory object's handle.
 *
 * A record covers a run of pages with one kind, one protection and one ceiling.
 * The records of a tree never overlap, and a hole is a range no record covers.
 * A record's ceiling is fixed when it is made, and its protection is one of
 * none, read, read-write and read-execute, beneath that ceiling; only
 * kernel/core/map.c writes a record, and only from a plan it made, so both hold
 * by construction.
 *
 * An edit has two steps, and the first changes nothing:
 *
 *   plan   A pure function validates the whole request and returns a plan:
 *          the records to split, detach and create, and how many spare
 *          records it needs (at most ERX_MAP_SPARES_MAX).
 *   apply  The caller allocates that many records, charged to the space's
 *          budget, and hands them to erx_map_apply, which cannot fail
 *          part-way. A caller whose allocation failed drops the plan, and
 *          the tree is as it was.
 *
 * A plan names its tree and the tree's generation. Every change to the tree
 * advances that, so a plan the tree has moved past is refused whole, and a plan
 * applies at most once. A generation means something only for the life of its
 * tree, and restarts when a tree is initialised, so the caller holds the space
 * from plan to apply: a plan must not outlive that hold, and no plan may meet a
 * space freed and made again at the same address.
 *
 * erx_map_plan_insert and erx_map_plan_release act in one atomic step, however
 * many records the range holds: they split at most the two records that
 * straddle its ends and take everything between as one subtree. The bounded
 * range calls, commit, decommit and protect, go through erx_map_plan_part a
 * part at a time. A part's apply edits at most three records in logarithmic
 * time, whatever the part's size. What a part reports may be larger, up to a
 * whole record's translations and pages, and the caller works through that
 * in its own bounded steps: one translation table between preemption points,
 * and a released page subtree handed whole to the reaper. So a preemption
 * point between parts, with those steps inside them, bounds a call.
 *
 * What the caller does around an apply belongs to it: charging and backing
 * the pages a plan reports, clearing translations, the invalidations, a
 * record's place on its object's reverse map. The plan says what to charge
 * first, and the apply's result says what else the edit calls for.
 *
 * Every loop in this file walks one path of a balanced tree, or a fixed
 * number of records, so a call's cost is logarithmic in the space's records,
 * of which there are at most ERX_MAPPINGS_MAX. Nothing recurses; the walks
 * keep their paths in fixed arrays that the balance bound sizes. erx_map_check
 * alone walks the whole tree, and only the host tests run it.
 *
 * The records are opaque: struct erx_mapping is defined only in
 * kernel/core/map.c. A caller allocates a record of erx_map_record_size()
 * bytes and erx_map_record_align() alignment and the core initialises it.
 * A tree, a detached subtree and the core's part of a plan are held by value,
 * so their callers can place them, and each is core_opaque bytes whose layout
 * only that file knows; a build check keeps the name to this core.
 */

typedef struct erx_map_detached erx_map_detached_t;
typedef struct erx_map_edge erx_map_edge_t;
typedef struct erx_map_edges erx_map_edges_t;
typedef struct erx_map_insert erx_map_insert_t;
typedef struct erx_map_part_request erx_map_part_request_t;
typedef struct erx_map_plan erx_map_plan_t;
typedef struct erx_map_range erx_map_range_t;
typedef struct erx_map_result erx_map_result_t;
typedef struct erx_map_tree erx_map_tree_t;
typedef struct erx_mapping erx_mapping_t;
typedef struct erx_mapping_view erx_mapping_view_t;
typedef struct erx_memobj erx_memobj_t;
typedef struct erx_uvpn erx_uvpn_t;

/* A user page number. No function converts one to a pointer (K7). */
struct erx_uvpn {
	uint64_t	raw;
};

typedef enum erx_map_kind {
	ERX_MAP_RESERVED = 1,	/* address space only; no access */
	ERX_MAP_PRIVATE,	/* committed private memory; ceiling read-write */
	ERX_MAP_OBJECT,		/* a memory object at an offset; keeps the object */
	ERX_MAP_DELETED,	/* an object mapping whose object was deleted: no
				 * translation; an access faults */
	ERX_MAP_KERNEL		/* a thread's kernel-user page; no range call
				 * changes it, and one that overlaps it fails */
} erx_map_kind_t;

/* A record's flag: branch-target guarded pages. */
#define ERX_MAP_GUARDED		0x1u

/* The most records one plan takes from its caller. */
#define ERX_MAP_SPARES_MAX	3u
/* The most records erx_map_apply returns as merged away. */
#define ERX_MAP_FREED_MAX	2u

/* A record's fields, as a value. */
struct erx_mapping_view {
	erx_uvpn_t	 start;		/* first page */
	erx_uvpn_t	 end;		/* exclusive */
	erx_memobj_t	*object;	/* PRIVATE and OBJECT; otherwise NULL */
	erx_npages_t	 offset;	/* into the object; otherwise 0 */
	erx_map_kind_t	 kind;
	uint8_t		 prot;		/* ERX_PROT_NONE, _R, _RW or _RX */
	uint8_t		 ceiling;	/* fixed when made; prot never exceeds it */
	uint8_t		 flags;		/* ERX_MAP_GUARDED */
};

/* A checked run of pages inside a tree's user range; never empty. */
struct erx_map_range {
	erx_uvpn_t	start;
	erx_uvpn_t	end;		/* exclusive */
};

/* A space's records; erx_map_tree_init makes one. */
struct erx_map_tree {
	_Alignas(uint64_t) unsigned char core_opaque[32];
};

/*
 * A new record, as erx_vm_reserve, erx_vm_map, erx_image_map, erx_space_copy or
 * a thread's creation asks for it. addr and size are in bytes, as the call
 * passed them. Without ERX_VM_FIXED addr is a hint: the record goes there when
 * the page-aligned range is free and inside the user range, and otherwise at
 * the highest free range below base. With it the record starts at addr and
 * replaces what the space mapped there, unless ERX_VM_NOREPLACE makes any
 * overlap ERX_EEXIST.
 *
 * object_pages is the size of an ERX_MAP_OBJECT's object, which the record must
 * lie inside. A private record's offset is its first page, which no request
 * chooses, so a request's offset is zero: a page lies in one record and a
 * record names one object, so two records of one object name disjoint offsets.
 * Its object must be one of the space's own private objects, which only
 * erx_vm_commit, erx_image_map and erx_space_copy make; this core never
 * dereferences a handle, so it cannot see that.
 *
 * An ERX_MAP_OBJECT's or ERX_MAP_DELETED's ceiling is rights & object_ceiling,
 * written with the bits of a protection, and this is the only place one is
 * made. Every other kind's is read-write and takes neither. prot, rights,
 * object_ceiling and flags are as wide as the ABI's fields, wider than a record's,
 * and are validated before any is stored in one; a binding refuses higher bits
 * of a register before it fills them.
 */
struct erx_map_insert {
	uint64_t	 addr;
	uint64_t	 size;
	erx_uvpn_t	 base;		/* the space's placement base */
	erx_memobj_t	*object;
	erx_npages_t	 offset;	/* in pages; ERX_MAP_OBJECT only */
	erx_npages_t	 object_pages;
	erx_map_kind_t	 kind;
	uint32_t	 vm_flags;	/* ERX_VM_FIXED, ERX_VM_NOREPLACE */
	uint32_t	 prot;
	uint32_t	 rights;
	uint32_t	 object_ceiling;
	uint32_t	 flags;		/* ERX_MAP_GUARDED */
};

typedef enum erx_map_op {
	ERX_MAP_COMMIT = 1,
	ERX_MAP_DECOMMIT,
	ERX_MAP_PROTECT
} erx_map_op_t;

/*
 * One part of a bounded range call. A call starts with cursor at range.start
 * and sets it to the last plan's next. object names the private memory that
 * committing a reservation makes, and a part that meets a reservation it must
 * commit refuses a NULL object with ERX_EINVAL. Its offset is its page number,
 * as an insert's is, so a private object's records partition its offsets (K5).
 */
struct erx_map_part_request {
	erx_map_op_t	 op;
	erx_map_range_t	 range;
	erx_uvpn_t	 cursor;
	erx_memobj_t	*object;
	uint32_t	 prot;		/* ERX_MAP_PROTECT */
};

/*
 * The bytes of a plan that only the core reads: what it will write, and what
 * the apply will report. The core checks this size against its own layout.
 */
#define ERX_MAP_PLAN_CORE_BYTES	336u

/*
 * What one edit will do. A caller reads the members after core_opaque; none of
 * them is read back, so writing one changes nothing. A plan is applied at most
 * once: erx_map_apply accepts only a plan its planner accepted, for its own
 * tree, and spends it whatever it decides. A refused plan reports nothing.
 *
 * A part whose cursor is at the call's end has an empty range and asks for no
 * edges; every other plan's range is a checked one.
 *
 * nspares is the number of records the caller allocates before the apply, which
 * erx_map_apply counts again from what it will write. range is what the plan
 * acts on: the record's place for an insert, the part for a part, the call's
 * range for a release. An insert's or a release's range may hold anything; a
 * part's lies in one record. next and done tell a bounded call where the next
 * part starts and whether one is due. edits is the number of records a part
 * rewrites, at most three.
 *
 * Before the apply, the caller of a part charges charge_pages to the space's
 * budget and backs them, and a budget that cannot cover them ends the call with
 * ERX_ENOMEM, the plan unapplied (the tables' part of the reserve is the
 * caller's). An apply that then refuses, ERX_ESTALE included, leaves the charge
 * with the caller, which refunds it.
 */
struct erx_map_plan {
	_Alignas(uint64_t) unsigned char core_opaque[ERX_MAP_PLAN_CORE_BYTES];
	uint32_t	 nspares;
	uint32_t	 edits;
	erx_map_range_t	 range;
	erx_uvpn_t	 next;
	bool		 done;
	erx_npages_t	 charge_pages;
};

/*
 * Records that left a tree, as one subtree, in address order. The caller
 * takes them one at a time with erx_map_detached_next, so it can pass a
 * preemption point after each, and owns each one it takes.
 */
struct erx_map_detached {
	_Alignas(uint64_t) unsigned char core_opaque[16];
};

/*
 * What an apply did. It writes these only when it accepts the plan, and zeroes
 * them when it refuses, so a caller cannot act on an edit that did not happen.
 *
 * added holds the spares that became records of a memory object, the detached
 * ones among them: each joins its object's reverse map, so every record of an
 * object that leaves the tree leaves that map the same way; it does so before
 * the space's lock drops, so a deletion finds every record of its object. freed
 * holds the records a merge took out of the tree: each leaves its object's
 * reverse map, if it is on one, and is freed. inserted is the record an insert
 * made.
 *
 * clears says the plan's range lost access that translations may still grant,
 * so they go. trim_pages counts the pages of private memory a decommit gives
 * up, from trim_object at trim_offset. Only private memory is ever trimmed
 * (K5). A release reports its pages through the records it detaches.
 */
struct erx_map_result {
	erx_map_detached_t detached;
	erx_mapping_t	*inserted;
	erx_mapping_t	*added[ERX_MAP_SPARES_MAX];
	erx_mapping_t	*freed[ERX_MAP_FREED_MAX];
	uint32_t	 nadded;
	uint32_t	 nfreed;
	bool		 clears;
	erx_npages_t	 trim_pages;
	erx_memobj_t	*trim_object;
	erx_npages_t	 trim_offset;
};

/*
 * One translation table level over a plan's range, read from the records as they
 * stand. The caller asks after the apply, under the same hold of the space's
 * lock, for each part of a decommit that clears, a release, and an insert of a
 * reservation that replaces records. A protect detaches no table and never asks,
 * and nor does an insert of any other kind, whose record takes over every promise
 * in its range.
 *
 * The range is the plan's, a part at a time, never the whole call's: a call can
 * stop at a mapping of an object further on. The regions the range covers only
 * partly are its edges, at most two: an edge whose table some record but a
 * reservation still touches keeps its table, since its page is that record's
 * promise, and any other is detached. A region the range covers completely holds
 * no promise after the apply, since a decommit's part lies in one record of
 * private memory, and a release or a replacing reservation ends every promise in
 * its range. The caller detaches those whole, and its alignment arithmetic alone
 * names them.
 */
struct erx_map_edge {
	erx_uvpn_t	start;		/* the region's first page */
	bool		keep;		/* its table stays */
};

struct erx_map_edges {
	erx_map_edge_t	 edge[2];
	uint32_t	 nedges;
};

/* The record's size and alignment, for the caller's allocator. */
size_t	erx_map_record_size(void);
size_t	erx_map_record_align(void);

/*
 * An empty tree over the user half, whose end the binding gives. Refuses with
 * ERX_EINVAL an end at or below ERX_USER_BASE_MIN's page or beyond the pages a
 * 64-bit address can name.
 */
int	erx_map_tree_init(erx_map_tree_t *, erx_uvpn_t)
	    ERX_WARN_UNUSED_RESULT;

/* The records in the tree. */
uint32_t erx_map_count(const erx_map_tree_t *);

/* A record's fields. */
erx_mapping_view_t erx_map_view(const erx_mapping_t *);

/* The record that covers a page, or NULL. */
erx_mapping_t *erx_map_lookup(const erx_map_tree_t *, erx_uvpn_t);

/* The lowest record that covers a page at or after this one, or NULL. */
erx_mapping_t *erx_map_first_from(const erx_map_tree_t *, erx_uvpn_t);

/*
 * Whether a record that holds a promise of a table, which is every record but
 * a reservation, touches [start, end). So the reserve's arithmetic and the
 * edge rule read the same fact. A deleted mapping's promise stays until the
 * space releases its range, as the record does.
 */
bool	erx_map_span_touched(const erx_map_tree_t *, erx_uvpn_t, erx_uvpn_t);

/*
 * The pages a range call's byte arguments name: ERX_EINVAL for an address or a
 * size that is not page-aligned or a size of zero, ERX_ERANGE for anything
 * outside the tree's user range, wrapping included.
 */
int	erx_map_range_decode(const erx_map_tree_t *, uint64_t, uint64_t,
	    erx_map_range_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Plans a new record. Refuses, changing nothing:
 *
 *   ERX_EINVAL  unknown flags, ERX_VM_NOREPLACE without ERX_VM_FIXED, a
 *               malformed range, a nonzero offset for private memory, a
 *               kernel-user record that is not one read-write page, or fields
 *               that do not suit the kind, writable with executable among them;
 *   ERX_ERIGHTS a protection above the ceiling;
 *   ERX_ERANGE  a fixed range outside the user range, or a record outside its
 *               object;
 *   ERX_EEXIST  an overlap with a kernel-user page, or any overlap under
 *               ERX_VM_NOREPLACE;
 *   ERX_ENOMEM  no free range below the base, or a tree already at
 *               ERX_MAPPINGS_MAX.
 */
int	erx_map_plan_insert(const erx_map_tree_t *, const erx_map_insert_t *,
	    erx_map_plan_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Plans erx_vm_release: every record in the range leaves in one step, those
 * that straddle its ends split. Refuses with ERX_EEXIST a range that overlaps
 * a kernel-user page and with ERX_ENOMEM a split past ERX_MAPPINGS_MAX. A range
 * that holds nothing plans nothing.
 */
int	erx_map_plan_release(const erx_map_tree_t *, const erx_map_range_t *,
	    erx_map_plan_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Plans one part of a bounded range call, as far as the end of the first
 * record it meets, holes before it included, at most ERX_RANGE_PART_PAGES when
 * it commits a reservation, and editing at most three records:
 *
 *   commit    a reservation becomes private memory, read-write, and private
 *             memory becomes read-write;
 *   decommit  private memory becomes a reservation and its pages go, and a
 *             reservation stays as it is;
 *   protect   every record moves to prot beneath its ceiling, a reservation
 *             given access being committed, and a hole ends the call.
 *
 * Commit and decommit act on private memory alone: a mapping of an object,
 * deleted or not, ends them with ERX_EEXIST, as a kernel-user page ends every
 * part. Protect is the one call over mixed kinds.
 *
 * Refuses, with the parts before it applied: ERX_EINVAL for a malformed
 * request or prot; ERX_ERIGHTS for a prot above the ceiling of the record met;
 * ERX_ERANGE for a hole a protect meets; ERX_EEXIST as above; ERX_ENOMEM for a
 * split past ERX_MAPPINGS_MAX.
 */
int	erx_map_plan_part(const erx_map_tree_t *,
	    const erx_map_part_request_t *, erx_map_plan_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * Plans a thread's teardown of its kernel-user page, the one way such a record
 * leaves: ERX_EINVAL unless a kernel-user record starts at this page.
 */
int	erx_map_plan_remove_kernel(const erx_map_tree_t *, erx_uvpn_t,
	    erx_map_plan_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Applies a plan with exactly the records it needs, which the core initialises,
 * and spends the plan. Refuses, changing nothing, using none of the records and
 * zeroing the result: ERX_EINVAL for a plan that is not awaiting its apply, a
 * plan of another tree or more records than it needs; ERX_ESTALE for a plan the
 * tree has moved past; ERX_ENOMEM for fewer. On success it cannot have failed
 * part-way.
 */
int	erx_map_apply(erx_map_tree_t *, erx_map_plan_t *, erx_mapping_t **,
	    uint32_t, erx_map_result_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Takes the next detached record, the lowest, or NULL when none is left. Its
 * fields stay readable through erx_map_view until the caller frees it. At most
 * one path of rotations, and over all the records linear in their number.
 */
erx_mapping_t *erx_map_detached_next(erx_map_detached_t *);

/* The detached records not yet taken. */
uint32_t erx_map_detached_count(const erx_map_detached_t *);

/* A space's teardown: every record leaves the tree, as one subtree. */
void	erx_map_take_all(erx_map_tree_t *, erx_map_detached_t *);

/*
 * Marks a record of a deleted object: no object, no offset, an access faults.
 * ERX_EINVAL for a record of another kind; ERX_ESTALE for one that has left
 * the tree, which the deletion only takes off the reverse map.
 */
int	erx_map_mark_deleted(erx_map_tree_t *, erx_mapping_t *)
	    ERX_WARN_UNUSED_RESULT;

/*
 * One table level over a range. ERX_EINVAL for a span of zero or beyond the
 * pages a 64-bit address can name, or a range outside the tree's.
 */
int	erx_map_edges(const erx_map_tree_t *, const erx_map_range_t *,
	    erx_npages_t, erx_map_edges_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Checks every invariant of the tree and its records, and returns the name of
 * the first that does not hold, or NULL. Host tests and fuzz targets only; it
 * walks the whole tree.
 */
const char *erx_map_check(const erx_map_tree_t *);

#endif /* ERX_MAP_H */
