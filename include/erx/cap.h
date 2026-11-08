/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CAP_H
#define ERX_CAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/object.h"

/*
 * The capability core (docs/design-kernel.md, "Objects and capabilities",
 * "Rights" and "Passing capabilities"): capability values, the slots of
 * one space's table, the one lookup's check of a value, the two rights
 * constructors, and the plan and the application of a pass. It reads no
 * hardware and takes no lock; its caller holds the locks the design names
 * for each writer below (the object's capability lock, then the table's
 * lock) and allocates and charges the table's memory, which the core
 * owns while the table is used. Lookups take no lock at all.
 *
 * A capability value holds its slot's index in bits 0-23 and the slot's
 * generation in bits 24-63. Slot 0 is never issued, so value 0 names
 * nothing. A slot is free, reserved for a pass its space's own receive
 * awaits, live, or retired for good; a slot whose generation or sequence
 * count is exhausted retires instead of returning to the free list, so no
 * table ever issues one value twice (K1).
 *
 * The object a slot names is the object store's nonzero 64-bit handle,
 * which only the object store turns into a record. The object's type is
 * stored beside it, since the lookup checks it under the same sequence
 * count, and an object's type never changes. Every live slot is on its
 * object's slot list, whose head is the object's and whose links are the
 * slots' own, and the object counts the slots on it: an install links
 * and counts, erx_cap_slot_clear unlinks and counts out and reports the
 * release, and a pass's move hands its count from slot to slot (K21).
 */

/* A lookup's type argument that accepts an object of any type. */
#define ERX_CAP_ANY_TYPE	UINT32_C(0)

/*
 * A space's capability table: a directory of pages of slots, the count of
 * slots they hold, the free list and whether the table's space has
 * emptied it. Its record is private to the core (kernel/core/cap_impl.h,
 * B4), so no other code can write a member or store a page of its own in
 * the directory; a caller allocates erx_cap_table_size() bytes aligned to
 * erx_cap_table_align() and reaches the table only through the functions
 * below.
 */
typedef struct erx_cap_table erx_cap_table_t;

/* One consistent state of a live slot, as a lookup read it. */
typedef struct erx_cap_view {
	uint64_t	 object;
	erx_ktype_t	 type;
	erx_rights_t	 rights;
	uint32_t	 slot;
	uint64_t	 generation;
} erx_cap_view_t;

/*
 * The object store's handles of the calling thread's space and thread, for
 * the reserved values ERX_CAP_SELF and ERX_CAP_SELF_THREAD: what those values
 * mean depends on the caller, so the lookup receives it as an argument and
 * reads no global state.
 */
typedef struct erx_cap_self {
	uint64_t	 space;
	uint64_t	 thread;
} erx_cap_self_t;

/* The free slots a receive took for the capabilities a pass brings it. */
typedef struct erx_cap_reservation {
	uint32_t	 count;
	uint32_t	 slots[ERX_MSG_CAPS];
} erx_cap_reservation_t;

/*
 * Which tables a pass joins, from which the rules that bind it follow: a
 * rendezvous goes from the sender's own table to the receiver's own, and
 * erx_cap_pass from one table to another of the caller's own and the
 * spaces it created. GIVE binds a capability that leaves the caller's own
 * table; the creator's rule replaces the pass sets for a pass into a space
 * the caller created.
 */
typedef enum erx_pass_route {
	ERX_PASS_RENDEZVOUS = 1,	/* own to the receiver's own */
	ERX_PASS_OWN_TO_CREATED,	/* own to a created space's */
	ERX_PASS_CREATED_TO_OWN,	/* a created space's to own */
	ERX_PASS_CREATED_TO_CREATED	/* one created space's to another's */
} erx_pass_route_t;

typedef enum erx_pass_op {
	ERX_PASS_COPY = 1,	/* the sender keeps its capability */
	ERX_PASS_MOVE		/* the receiver's slot takes the sender's place */
} erx_pass_op_t;

/*
 * One typed item of a pass, decoded from the sender's message or the
 * caller's UTCB: the value in the source table, copy or move, the rights
 * mask, and, for erx_cap_pass's checked kinds, the type the capability
 * must have (ERX_CAP_ANY_TYPE for none) and rights it must carry.
 */
typedef struct erx_pass_item {
	erx_cap_t	 cap;
	uint32_t	 op;		/* an erx_pass_op_t; anything else is refused */
	uint32_t	 mask;
	erx_ktype_t	 type;
	uint32_t	 required;
} erx_pass_item_t;

/*
 * A pass to plan: its items, the receiver's room, its route (an
 * erx_pass_route_t; anything else is refused) and the two tables, which
 * the plan records so that its take and its install refuse any others.
 */
typedef struct erx_pass_request {
	const erx_pass_item_t *items;
	uint32_t	 count;
	uint32_t	 room;
	uint32_t	 route;
	const erx_cap_table_t *from;
	const erx_cap_table_t *to;
} erx_pass_request_t;

/* What the source table held for one item, read under the locks. */
typedef struct erx_pass_source {
	erx_status_t	 status;	/* erx_cap_read's, with any type and no rights */
	erx_cap_view_t	 view;		/* valid when status is ERX_OK */
} erx_pass_source_t;

/* One step of an accepted pass: the source slot and what the receiver gets. */
typedef struct erx_pass_step {
	erx_pass_op_t	 op;
	uint32_t	 slot;
	uint64_t	 generation;
	uint64_t	 object;
	erx_ktype_t	 type;
	erx_rights_t	 rights;
	bool		 released;	/* an install that dropped the step took
					 * its object's last count: the release
					 * is the caller's to perform */
} erx_pass_step_t;

/*
 * How far a plan has gone. Each step accepts a plan only at the stage
 * before its own and moves it on, so a plan is taken once, before it is
 * installed, and installed once.
 */
typedef enum erx_pass_stage {
	ERX_PASS_REFUSED = 0,	/* erx_pass_plan refused it, or never ran */
	ERX_PASS_PLANNED,
	ERX_PASS_TAKEN,
	ERX_PASS_INSTALLED	/* installed or dropped: nothing more to do */
} erx_pass_stage_t;

/*
 * A plan: on ERX_OK, count steps in the sender's order; otherwise failed
 * is the index of the item refused, or count when the count itself was.
 */
typedef struct erx_pass_plan {
	erx_pass_stage_t stage;
	erx_pass_route_t route;
	const erx_cap_table_t *from;
	const erx_cap_table_t *to;
	uint32_t	 count;
	uint32_t	 failed;
	erx_pass_step_t	 steps[ERX_MSG_CAPS];
} erx_pass_plan_t;

/* What one passed capability is in the receiver's table. */
typedef struct erx_pass_result {
	erx_cap_t	 cap;
	erx_ktype_t	 type;
	erx_rights_t	 rights;
} erx_pass_result_t;


/*
 * The two rights constructors (K2). erx_rights_create returns the default
 * set the ABI file declares for a creation kind, and the empty set for a
 * number that names none; erx_rights_shrink intersects with a mask. No
 * code outside kernel/core/cap.c builds an erx_rights_t, and nothing
 * combines rights by OR.
 */
erx_rights_t	erx_rights_create(erx_create_kind_t kind);
erx_rights_t	erx_rights_shrink(erx_rights_t rights, uint32_t mask);
bool		erx_rights_contain(erx_rights_t rights, uint32_t required);

/* Size and alignment of a table record, for the memory that holds it. */
size_t		erx_cap_table_size(void);
size_t		erx_cap_table_align(void);

/*
 * Size of the directory a table of limit slots needs, aligned to
 * erx_cap_directory_align(); 0 for a limit erx_cap_table_init refuses.
 */
size_t		erx_cap_directory_size(uint32_t limit);
size_t		erx_cap_directory_align(void);

/*
 * Set up an empty table of limit slots, slot 0 included, over directory,
 * size bytes of untyped storage the caller allocated and charged. The
 * directory belongs to the table from then on: the caller neither reads
 * nor writes it, and frees it only once nothing uses the table.
 * ERX_EINVAL unless limit is 2 to ERX_CAPS_MAX, the table is aligned,
 * and the directory is aligned, at least erx_cap_directory_size(limit)
 * bytes and apart from the table.
 */
erx_status_t	erx_cap_table_init(erx_cap_table_t *table, void *directory,
		    size_t size, uint32_t limit);

/*
 * The pages to add before the table holds nfree free slots: 0 when it
 * already does; ERX_ELIMIT when its limit cannot hold them. The table's
 * lock. A caller that drops the lock to allocate the pages asks again
 * after taking it back, since the table may have changed meanwhile.
 */
erx_status_t	erx_cap_table_pages_needed(const erx_cap_table_t *table,
		    uint32_t nfree, uint32_t *npagesp);

/*
 * Add one page of ERX_CAP_PAGE_SLOTS slots, ERX_CAP_PAGE_SLOTS *
 * ERX_CAP_SLOT_SIZE bytes of untyped storage aligned to ERX_CAP_SLOT_ALIGN
 * that the caller allocated and charged, and append its slots below the
 * limit to the free list. The page belongs to the table from then on, as
 * its directory does. ERX_EINVAL for a null, misaligned or short page,
 * size being its bytes, and for one that overlaps the table's record, its
 * directory or a page it already holds;
 * ERX_ELIMIT when the table is already at its limit. The table's lock.
 */
erx_status_t	erx_cap_table_add_page(erx_cap_table_t *table, void *page,
		    size_t size);

/*
 * Mark the table emptied; nothing is installed, reserved or filled after
 * it. The table's lock, under which every reader of the flag runs.
 */
void		erx_cap_table_set_emptied(erx_cap_table_t *table);

/*
 * The one lookup's check of a value: bounds, the slot's retirement and
 * liveness, generation, type, rights, in that order, reading the slot
 * under its sequence count without a lock. ERX_ESTALE for a value that
 * names no live slot at its generation, ERX_ETYPE, ERX_ERIGHTS. A view
 * is written only on ERX_OK, and is one state of the slot.
 *
 * self is the calling thread's when table is its own space's, and NULL for a
 * read of another space's table. With it, ERX_CAP_SELF and ERX_CAP_SELF_THREAD
 * name the caller's own objects, with the rights of ERX_KIND_RESERVED_SPACE and
 * ERX_KIND_RESERVED_THREAD, and pass the same type and rights checks; their
 * view's slot is 0, since they name no slot, so erx_pass_plan refuses one and
 * no writer can clear, take or move through one. Without it they are stale,
 * as is every other value whose slot bits lie above the table's limit.
 *
 * It is a pure check of the slot and reads no object: erx_cap_lookup adds
 * the object's checks.
 */
erx_status_t	erx_cap_read(const erx_cap_table_t *table,
		    const erx_cap_self_t *self, erx_cap_t cap, erx_ktype_t type,
		    uint32_t required, erx_cap_view_t *viewp);

/*
 * The kernel's one lookup (K1): erx_cap_read, then the view's handle
 * turned into its record, which must be LIVE and paid for by a budget that
 * is not dead, or ERX_ESTALE; on ERX_OK the record stamped with the calling
 * thread's count of preemption points. self is as for erx_cap_read: its
 * caller passes the calling thread's space and thread. No lock and no
 * reference is taken; the record stays valid until the caller's next
 * preemption point, since an object is freed only a grace period after it
 * is deleted or released.
 */
erx_status_t	erx_cap_lookup(const erx_cap_table_t *table,
		    const erx_cap_self_t *self, erx_cap_t cap, erx_ktype_t type,
		    uint32_t required, erx_uref_t *refp);

/*
 * Install a capability to an object a creation call just made, with the
 * default rights of its creation kind shrunk by mask (all ones for a
 * creation, a carve's mask for a carve), so that no caller chooses a type
 * and a rights pair (K2). ERX_EDEAD once the table is emptied; ERX_EINVAL
 * for a kind that makes no object of the object's type, or a reserved
 * kind; ERX_ELIMIT with no free slot (grow first); and the refusals of
 * erx_object_cap_add, which links and counts the slot on the object. The
 * object's capability lock, then the table's.
 */
erx_status_t	erx_cap_install_kind(erx_cap_table_t *table,
		    erx_object_t *object, erx_create_kind_t kind, uint32_t mask,
		    erx_cap_t *capp);

/*
 * Install a copy of cap, a capability of from that names object, into to,
 * with its rights shrunk by mask, for erx_cap_dup (from is to) and a fork's
 * copy (mask is then the type's pass set). The slot's type and rights are
 * read from the source slot under the locks, never taken from the caller.
 * ERX_EDEAD once to is emptied; ERX_ESTALE unless cap still names object at
 * its generation; ERX_ERIGHTS without DUP; ERX_ELIMIT with no free slot;
 * and the refusals of erx_object_cap_add. The object's capability lock,
 * then to's lock.
 */
erx_status_t	erx_cap_install_copy(erx_cap_table_t *to,
		    const erx_cap_table_t *from, erx_cap_t cap,
		    erx_object_t *object, uint32_t mask, erx_cap_t *capp);

/*
 * The one function that clears a slot (K21, K25): if cap still names
 * object at cap's generation, unlink the slot from the object's list,
 * clear it, advance its generation, free it or, when its generation or
 * count is exhausted, retire it, and count it out of the object. *releasedp
 * says whether that was the object's last capability, the release its
 * caller performs; ERX_ESTALE otherwise, changing nothing and setting
 * *releasedp false. The object's capability lock, then the table's.
 */
erx_status_t	erx_cap_slot_clear(erx_cap_table_t *table, erx_cap_t cap,
		    erx_object_t *object, bool *releasedp);

/*
 * The table and the value of a slot on an object's slot list, which a
 * destroy's teardown hands to erx_cap_slot_clear; under the object's
 * capability lock, which keeps the slot listed. The search is over the
 * table's directory, bounded by its page count. A slot that is on no
 * table's page is a kernel bug and traps.
 */
void		erx_cap_slot_name(const erx_cap_slot_t *slot,
		    erx_cap_table_t **tablep, erx_cap_t *capp);

/*
 * Take count free slots for a receive. ERX_EINVAL for a count above
 * ERX_MSG_CAPS; ERX_EBUSY when the reservation still holds slots, which
 * must be released first; ERX_EDEAD once the table is emptied; ERX_ELIMIT
 * with too few free slots (grow first). The table's lock.
 */
erx_status_t	erx_cap_reserve(erx_cap_table_t *table, uint32_t count,
		    erx_cap_reservation_t *reservation);

/* Return a reservation's unfilled slots to the free list. The table's lock. */
void		erx_cap_release_reservation(erx_cap_table_t *table,
		    erx_cap_reservation_t *reservation);

/*
 * Decide a whole pass from what the source table held: a pure function.
 * ERX_EINVAL for a count above ERX_MSG_CAPS or an unknown route,
 * ERX_ELIMIT for a count above the receiver's room; then for each item in
 * order ERX_ESTALE for a value that names no live slot, a view of a
 * reserved value among them, ERX_EINVAL for a slot named twice or an
 * unknown operation, ERX_ETYPE and ERX_ERIGHTS for an item's checked type
 * and rights, ERX_ERIGHTS without GIVE from the caller's own table or
 * without DUP for a copy, and ERX_ETYPE for a type that never passes where
 * the pass sets bind. Each passed capability keeps its rights within the
 * item's mask and, unless the creator's rule applies, its type's pass set;
 * under the creator's rule a space passes with INSPECT alone, and CODE
 * never passes (K24).
 */
erx_status_t	erx_pass_plan(const erx_pass_request_t *request,
		    const erx_pass_source_t *sources, erx_pass_plan_t *plan);

/*
 * The take step of a plan erx_pass_plan accepted, under the source table's
 * lock and the objects' capability locks it was planned under. It checks
 * the whole pass first and changes nothing when it refuses: ERX_EINVAL for
 * a plan not at ERX_PASS_PLANNED or one no erx_pass_plan made (an unknown
 * operation, a slot named twice, a type or rights the slot does not hold),
 * or from another table than the plan's; ERX_ESTALE when a source slot no
 * longer names its object at its generation or the object is not LIVE;
 * ERX_ELIMIT when the receiver's reservation, which its hold in the
 * transfer keeps fixed, has fewer slots than the plan, or an object's
 * count could overflow. Then it counts one more capability on each step's
 * object, which the plan holds for the receiver's slot, clears each moved
 * slot with erx_cap_slot_clear, whose count-out the step's count
 * outweighs, so a move never takes its object's count through zero (K21),
 * and moves the plan to ERX_PASS_TAKEN. From here only an emptying of the
 * destination stops the pass, and erx_pass_install drops it then.
 */
erx_status_t	erx_pass_take(erx_pass_plan_t *plan, erx_cap_table_t *from,
		    const erx_cap_reservation_t *reservation);

/*
 * The install step of a taken plan, under the destination table's lock
 * alone, so a pass holds one table's lock at a time, and the objects'
 * capability locks the plan was made under. ERX_EINVAL, changing nothing,
 * for a plan not at ERX_PASS_TAKEN or a table not the plan's. Any other
 * outcome moves the plan to ERX_PASS_INSTALLED. When the table is emptied
 * it fills nothing and returns ERX_EDEAD: what the pass carried is dropped
 * as a close would drop it, each step's count taken out of its object and
 * the step marked released when that was the last. Otherwise it fills the
 * reservation's first slots in the sender's order, links each on its
 * object's list with the count take made for it, writes results and
 * removes the filled slots from the reservation. A reservation that take
 * found whole but that no longer holds the plan's count of reserved slots
 * breaks the receiver's hold, a kernel bug: ERX_EINVAL before any fill,
 * and what the pass carried is dropped as for ERX_EDEAD. results has
 * ERX_MSG_CAPS entries; those past the plan's count, and all of them on
 * any status but ERX_OK, are zero.
 */
erx_status_t	erx_pass_install(erx_pass_plan_t *plan, erx_cap_table_t *to,
		    erx_cap_reservation_t *reservation,
		    erx_pass_result_t *results);

#endif /* ERX_CAP_H */
