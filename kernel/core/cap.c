/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The capability core: see erx/cap.h for the contract.
 *
 * Every field of a slot is reached through the accessors the ABI file's
 * erx_cap_slot layout generates into cap_slot_impl.h, the slot's private
 * header, which only this core and its host tests include, so no other
 * code can name a slot's fields (K1). A writer, which holds the table's
 * lock, changes a slot in one write: it stores the count plus one, which
 * is odd, then each field, then the count plus two. A lookup loads the
 * count, each field and the count again, and keeps its copy only when the
 * two counts are equal and even (docs/design-kernel.md, "Sequence-counted
 * records").
 *
 * A slot's life from the free list is at most three writes: a reserve
 * and a fill, or an install, then a clear or a release, which is the
 * life's closing write. A closing write frees the slot only when its
 * generation and its count leave room for one more whole life; otherwise
 * it publishes the terminal count and the slot retires. So a slot taken
 * from the free list never reaches the terminal count before its closing
 * write, and nothing after a pass's checks can fail for want of one.
 *
 * Every live slot is on its object's slot list, doubly linked through
 * the slots' obj_prev and obj_next by address, its head in the object's
 * record; the object counts the slots on it. The list and the count change
 * together under the object's capability lock: cap_install links and
 * counts a new slot, erx_cap_slot_clear unlinks and counts one out, and a
 * pass counts at its take and links at its install. A slot's table field
 * is written once, when its page is added.
 */

#include <stdalign.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/attach.h"
#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/object.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define CAP_SLOT_MASK		((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1)
/* The bytes of one page of slots. */
#define CAP_PAGE_BYTES		((size_t)ERX_CAP_PAGE_SLOTS * ERX_CAP_SLOT_SIZE)
/* The first generation never issued: a slot that would reach it retires. */
#define CAP_GENERATION_LIMIT	((UINT64_C(1) << ERX_CAP_GENERATION_BITS) - 1)
/*
 * The writes that open a slot's life before its closing write: a reserve
 * and a fill, or an install alone. Each adds 2 to the count.
 */
#define CAP_LIFE_OPEN_WRITES	2
/*
 * The highest count at which a slot may rest on the free list: from it
 * the opening writes end at the terminal count minus 1, from which the
 * closing write's odd store reaches the terminal count and it can still
 * publish the terminal count. A closing write frees a slot only when the
 * count it leaves is at most this.
 */
#define CAP_SEQ_FREE_MAX \
	(ERX_CAP_SLOT_SEQ_TERMINAL - 1 - 2 * CAP_LIFE_OPEN_WRITES)

_Static_assert(ERX_CAP_SLOT_SEQ_TERMINAL % 2 == 1,
    "the terminal count is odd, so no write's even count reaches it");
_Static_assert(CAP_SEQ_FREE_MAX % 2 == 0, "a resting count is even");
_Static_assert(ERX_CAP_SLOT_BITS + ERX_CAP_GENERATION_BITS == 64,
    "a capability value is a slot index and a generation");
_Static_assert(ERX_CAPS_MAX <= CAP_SLOT_MASK, "slot indices fit a value");
_Static_assert(ERX_CAPS_MAX % ERX_CAP_PAGE_SLOTS == 0, "whole pages");
_Static_assert((ERX_CAP_SELF & CAP_SLOT_MASK) >= ERX_CAPS_MAX &&
    (ERX_CAP_SELF_THREAD & CAP_SLOT_MASK) >= ERX_CAPS_MAX,
    "no slot can bear a reserved value");
_Static_assert(ERX_CAP_SELF >> ERX_CAP_SLOT_BITS == 0 &&
    ERX_CAP_SELF_THREAD >> ERX_CAP_SLOT_BITS == 0,
    "a reserved value holds generation 0");
_Static_assert(ERX_CAP_SELF != ERX_CAP_SELF_THREAD,
    "each reserved value names one object");

/* The fields one write gives a slot; the count is the write's own. */
typedef struct cap_fields {
	uint64_t	 object;
	uint64_t	 generation;
	uint32_t	 rights;
	uint32_t	 type;
	uint32_t	 state;
} cap_fields_t;

static uint32_t		 cap_npages(uint32_t);
static bool		 cap_overlaps(const void *, size_t, const void *, size_t);
static bool		 cap_page_in_use(const erx_cap_table_t *, const void *);
static erx_cap_t	 cap_value(uint32_t, uint64_t);
static erx_cap_slot_t	*cap_slot_at(const erx_cap_table_t *, uint32_t);
static uint64_t		 cap_seq(const erx_cap_slot_t *);
static uint32_t		 cap_next(const erx_cap_slot_t *);
static uint64_t		 cap_generation(const erx_cap_slot_t *);
static uint32_t		 cap_state(const erx_cap_slot_t *);
static void		 cap_load(const erx_cap_slot_t *, cap_fields_t *);
static bool		 cap_self_fields(const erx_cap_self_t *, erx_cap_t,
			    cap_fields_t *);
static erx_status_t	 cap_read_slot(const erx_cap_table_t *, uint32_t,
			    cap_fields_t *);
static void		 cap_store_fields(erx_cap_slot_t *, const cap_fields_t *);
static void		 cap_slot_write(erx_cap_slot_t *, const cap_fields_t *);
static bool		 cap_slot_close(erx_cap_slot_t *, uint64_t);
static void		 cap_free_append(erx_cap_table_t *, uint32_t);
static uint32_t		 cap_free_take(erx_cap_table_t *);
static bool		 cap_slot_names(const erx_cap_table_t *, uint32_t,
			    uint64_t, uint64_t);
static erx_cap_slot_t	*cap_obj_prev(const erx_cap_slot_t *);
static erx_cap_slot_t	*cap_obj_next(const erx_cap_slot_t *);
static void		 cap_set_obj_prev(erx_cap_slot_t *, const erx_cap_slot_t *);
static void		 cap_set_obj_next(erx_cap_slot_t *, const erx_cap_slot_t *);
static void		 cap_list_insert(erx_object_t *, erx_cap_slot_t *);
static bool		 cap_object_reachable(const erx_object_t *);
static erx_status_t	 cap_install(erx_cap_table_t *, erx_object_t *,
			    erx_ktype_t, erx_rights_t, erx_cap_t *);
static erx_status_t	 cap_install_verdict(const erx_pass_plan_t *,
			    const erx_cap_table_t *, const erx_cap_reservation_t *);
static void		 cap_pass_fill(const erx_pass_plan_t *, erx_cap_table_t *,
			    erx_cap_reservation_t *, erx_pass_result_t *);
static bool		 cap_route_from_own(erx_pass_route_t);
static bool		 cap_route_to_created(erx_pass_route_t);
static erx_status_t	 cap_plan_item(const erx_pass_request_t *,
			    const erx_pass_source_t *, uint32_t,
			    erx_pass_step_t *);

/* Rights. */

erx_rights_t
erx_rights_create(erx_create_kind_t kind)
{
	erx_rights_t rights = { .bits = erx_kind_default_mask(kind) };

	return (rights);
}

erx_rights_t
erx_rights_shrink(erx_rights_t rights, uint32_t mask)
{
	erx_rights_t shrunk = { .bits = rights.bits & mask };

	return (shrunk);
}

bool
erx_rights_contain(erx_rights_t rights, uint32_t required)
{
	return ((rights.bits & required) == required);
}

/* Slots. */

/* The pages of a table of limit slots; limit is at most ERX_CAPS_MAX. */
static uint32_t
cap_npages(uint32_t limit)
{
	return ((limit + ERX_CAP_PAGE_SLOTS - 1) / ERX_CAP_PAGE_SLOTS);
}

/* Whether the a bytes at pa and the b bytes at pb share a byte. */
static bool
cap_overlaps(const void *pa, size_t a, const void *pb, size_t b)
{
	uintptr_t x = (uintptr_t)pa, y = (uintptr_t)pb;

	return (x < y + b && y < x + a);
}

/*
 * Whether a page's storage overlaps the table's record, its directory or
 * a page it holds. Writing fresh slots over any of them would give a live
 * or retired slot a fresh count and generation, so a stale value could
 * name a new object (K1).
 */
static bool
cap_page_in_use(const erx_cap_table_t *table, const void *page)
{
	uint32_t i;

	if (cap_overlaps(page, CAP_PAGE_BYTES, table, sizeof(*table)) ||
	    cap_overlaps(page, CAP_PAGE_BYTES, table->pages,
	    table->npages_max * sizeof(table->pages[0])))
		return (true);
	for (i = 0; i < table->npages_max; i++) {
		const erx_cap_slot_t *held = atomic_load_explicit(&table->pages[i],
		    memory_order_relaxed);

		if (held == NULL)
			break;
		if (cap_overlaps(page, CAP_PAGE_BYTES, held, CAP_PAGE_BYTES))
			return (true);
	}
	return (false);
}

static erx_cap_t
cap_value(uint32_t slot, uint64_t generation)
{
	erx_cap_t cap = { .raw = generation << ERX_CAP_SLOT_BITS | slot };

	return (cap);
}

/* The slot at index, which the caller has checked lies below capacity. */
static erx_cap_slot_t *
cap_slot_at(const erx_cap_table_t *table, uint32_t index)
{
	erx_cap_slot_t *page;

	page = atomic_load_explicit(&table->pages[index / ERX_CAP_PAGE_SLOTS],
	    memory_order_acquire);
	return (&page[index % ERX_CAP_PAGE_SLOTS]);
}

/* The accessors fail only on a null slot, which no caller passes. */
static uint64_t
cap_seq(const erx_cap_slot_t *slot)
{
	uint64_t seq = 0;

	(void)erx_cap_slot_seq_load(slot, &seq);
	return (seq);
}

static uint32_t
cap_next(const erx_cap_slot_t *slot)
{
	uint32_t next = 0;

	(void)erx_cap_slot_next_load(slot, &next);
	return (next);
}

static uint64_t
cap_generation(const erx_cap_slot_t *slot)
{
	uint64_t generation = 0;

	(void)erx_cap_slot_generation_load(slot, &generation);
	return (generation);
}

static uint32_t
cap_state(const erx_cap_slot_t *slot)
{
	uint32_t state = 0;

	(void)erx_cap_slot_state_load(slot, &state);
	return (state);
}

/* Each field once; a lookup brackets this with two loads of the count. */
static void
cap_load(const erx_cap_slot_t *slot, cap_fields_t *fields)
{
	*fields = (cap_fields_t){ 0 };
	(void)erx_cap_slot_object_load(slot, &fields->object);
	(void)erx_cap_slot_generation_load(slot, &fields->generation);
	(void)erx_cap_slot_rights_load(slot, &fields->rights);
	(void)erx_cap_slot_type_load(slot, &fields->type);
	(void)erx_cap_slot_state_load(slot, &fields->state);
}

static void
cap_store_fields(erx_cap_slot_t *slot, const cap_fields_t *fields)
{
	(void)erx_cap_slot_object_store(slot, fields->object);
	(void)erx_cap_slot_generation_store(slot, fields->generation);
	(void)erx_cap_slot_rights_store(slot, fields->rights);
	(void)erx_cap_slot_type_store(slot, fields->type);
	(void)erx_cap_slot_state_store(slot, fields->state);
}

/* A write within a slot's life: a reserve, a fill or an install. */
static void
cap_slot_write(erx_cap_slot_t *slot, const cap_fields_t *fields)
{
	uint64_t seq = cap_seq(slot);

	(void)erx_cap_slot_seq_store(slot, seq + 1);
	cap_store_fields(slot, fields);
	(void)erx_cap_slot_seq_store(slot, seq + 2);
}

/*
 * The closing write of a slot's life, a clear or a release: empty the
 * slot at generation, and return true when it may be freed, false when it
 * retired, its generation or its count leaving no room for another life.
 */
static bool
cap_slot_close(erx_cap_slot_t *slot, uint64_t generation)
{
	uint64_t seq = cap_seq(slot);
	/* The count it leaves, seq + 2, written so that it cannot wrap. */
	bool retire = generation >= CAP_GENERATION_LIMIT ||
	    seq > CAP_SEQ_FREE_MAX - 2;
	cap_fields_t empty = {
		.object = 0,
		.generation = generation,
		.rights = 0,
		.type = 0,
		.state = retire ? ERX_CAP_SLOT_STATE_RETIRED : ERX_CAP_SLOT_STATE_FREE,
	};

	(void)erx_cap_slot_seq_store(slot, seq + 1);
	cap_store_fields(slot, &empty);
	(void)erx_cap_slot_seq_store(slot,
	    retire ? ERX_CAP_SLOT_SEQ_TERMINAL : seq + 2);
	return (!retire);
}

/*
 * The free list's link is the writer's alone: no lookup reads it, so it
 * changes outside the sequence count.
 */
static void
cap_free_append(erx_cap_table_t *table, uint32_t index)
{
	(void)erx_cap_slot_next_store(cap_slot_at(table, index), 0);
	if (table->free_tail == 0)
		table->free_head = index;
	else
		(void)erx_cap_slot_next_store(cap_slot_at(table,
		    table->free_tail), index);
	table->free_tail = index;
	table->nfree++;
}

/* The oldest free slot, which the caller has checked exists. */
static uint32_t
cap_free_take(erx_cap_table_t *table)
{
	uint32_t index = table->free_head;

	table->free_head = cap_next(cap_slot_at(table, index));
	if (table->free_head == 0)
		table->free_tail = 0;
	table->nfree--;
	return (index);
}

/* Whether slot index of table is live at generation and names object. */
static bool
cap_slot_names(const erx_cap_table_t *table, uint32_t index,
    uint64_t generation, uint64_t object)
{
	cap_fields_t fields;

	if (index == 0 || index >= atomic_load_explicit(&table->capacity,
	    memory_order_acquire))
		return (false);
	cap_load(cap_slot_at(table, index), &fields);
	return (fields.state == ERX_CAP_SLOT_STATE_LIVE &&
	    fields.generation == generation && object != 0 &&
	    fields.object == object);
}

/* Object slot lists. */

/* A slot's neighbours on its object's list, which the links name by address. */
static erx_cap_slot_t *
cap_obj_prev(const erx_cap_slot_t *slot)
{
	uint64_t address = 0;

	(void)erx_cap_slot_obj_prev_load(slot, &address);
	return ((erx_cap_slot_t *)(uintptr_t)address);
}

static erx_cap_slot_t *
cap_obj_next(const erx_cap_slot_t *slot)
{
	uint64_t address = 0;

	(void)erx_cap_slot_obj_next_load(slot, &address);
	return ((erx_cap_slot_t *)(uintptr_t)address);
}

static void
cap_set_obj_prev(erx_cap_slot_t *slot, const erx_cap_slot_t *prev)
{
	(void)erx_cap_slot_obj_prev_store(slot, (uint64_t)(uintptr_t)prev);
}

static void
cap_set_obj_next(erx_cap_slot_t *slot, const erx_cap_slot_t *next)
{
	(void)erx_cap_slot_obj_next_store(slot, (uint64_t)(uintptr_t)next);
}

/*
 * Put slot at the head of object's list through the list's insert in
 * kernel/core/attach.c; under its capability lock. Its callers counted
 * the slot on the object under the same lock, which needs the object
 * LIVE, so a refusal here is a kernel bug.
 */
static void
cap_list_insert(erx_object_t *object, erx_cap_slot_t *slot)
{
	erx_cap_slot_t *head;

	if (erx_attach_object_slots(object, slot, &head) != ERX_OK)
		__builtin_trap();
	cap_set_obj_prev(slot, NULL);
	cap_set_obj_next(slot, head);
	if (head != NULL)
		cap_set_obj_prev(head, slot);
}

/*
 * Whether a call may reach object through a capability: it is LIVE, so
 * neither released nor closed by a destroy, and the budget that pays for
 * it is not dead (K1, K3). Read without a lock; both only advance.
 */
static bool
cap_object_reachable(const erx_object_t *object)
{
	const struct erx_budget *budget = erx_object_budget(object);

	return (erx_object_state(object) == ERX_OBJ_LIVE &&
	    (budget == NULL || !erx_budget_dead(budget)));
}

/* Tables. */

size_t
erx_cap_table_size(void)
{
	return (sizeof(erx_cap_table_t));
}

size_t
erx_cap_table_align(void)
{
	return (alignof(erx_cap_table_t));
}

size_t
erx_cap_directory_size(uint32_t limit)
{
	if (limit < 2 || limit > ERX_CAPS_MAX)
		return (0);
	return (cap_npages(limit) * sizeof(_Atomic(erx_cap_slot_t *)));
}

size_t
erx_cap_directory_align(void)
{
	return (alignof(_Atomic(erx_cap_slot_t *)));
}

erx_status_t
erx_cap_table_init(erx_cap_table_t *table, void *directory, size_t size,
    uint32_t limit)
{
	_Atomic(erx_cap_slot_t *) *pages = directory;
	size_t needed = erx_cap_directory_size(limit);
	uint32_t i;

	if (limit < 2 || limit > ERX_CAPS_MAX)
		return (ERX_EINVAL);
	if (table == NULL || (uintptr_t)table % erx_cap_table_align() != 0 ||
	    directory == NULL || size < needed ||
	    (uintptr_t)directory % erx_cap_directory_align() != 0 ||
	    cap_overlaps(directory, needed, table, sizeof(*table)))
		return (ERX_EINVAL);
	table->npages_max = cap_npages(limit);
	for (i = 0; i < table->npages_max; i++)
		atomic_store_explicit(&pages[i], NULL, memory_order_relaxed);
	table->pages = pages;
	atomic_store_explicit(&table->capacity, 0, memory_order_relaxed);
	table->limit = limit;
	table->free_head = 0;
	table->free_tail = 0;
	table->nfree = 0;
	table->emptied = false;
	return (ERX_OK);
}

erx_status_t
erx_cap_table_pages_needed(const erx_cap_table_t *table, uint32_t nfree,
    uint32_t *npagesp)
{
	uint32_t capacity = atomic_load_explicit(&table->capacity,
	    memory_order_relaxed);
	uint32_t have = table->nfree;
	uint32_t npages = 0;
	uint32_t end;

	/* Each page adds at least one slot, so this ends within nfree pages. */
	while (have < nfree) {
		if (capacity >= table->limit)
			return (ERX_ELIMIT);
		end = table->limit - capacity < ERX_CAP_PAGE_SLOTS ?
		    table->limit : capacity + ERX_CAP_PAGE_SLOTS;
		have += end - capacity - (capacity == 0 ? 1 : 0);
		capacity = end;
		npages++;
	}
	*npagesp = npages;
	return (ERX_OK);
}

erx_status_t
erx_cap_table_add_page(erx_cap_table_t *table, void *storage, size_t size)
{
	erx_cap_slot_t *page = storage;
	uint32_t capacity = atomic_load_explicit(&table->capacity,
	    memory_order_relaxed);
	uint32_t index = capacity / ERX_CAP_PAGE_SLOTS;
	uint32_t end;
	uint32_t i;
	cap_fields_t fresh = {
		.object = 0,
		.generation = 0,
		.rights = 0,
		.type = 0,
		.state = ERX_CAP_SLOT_STATE_FREE,
	};

	if (page == NULL || size < CAP_PAGE_BYTES ||
	    (uintptr_t)page % ERX_CAP_SLOT_ALIGN != 0 ||
	    cap_page_in_use(table, page))
		return (ERX_EINVAL);
	if (capacity >= table->limit || index >= table->npages_max)
		return (ERX_ELIMIT);
	end = table->limit - capacity < ERX_CAP_PAGE_SLOTS ?
	    table->limit : capacity + ERX_CAP_PAGE_SLOTS;
	/* No lookup reaches these slots until capacity covers them. */
	for (i = 0; i < ERX_CAP_PAGE_SLOTS; i++) {
		(void)erx_cap_slot_seq_store(&page[i], 0);
		cap_store_fields(&page[i], &fresh);
		(void)erx_cap_slot_next_store(&page[i], 0);
		(void)erx_cap_slot_table_store(&page[i],
		    (uint64_t)(uintptr_t)table);
		cap_set_obj_prev(&page[i], NULL);
		cap_set_obj_next(&page[i], NULL);
	}
	if (capacity == 0) {
		/* Slot 0 is never issued: value 0 names nothing. */
		(void)erx_cap_slot_state_store(&page[0],
		    ERX_CAP_SLOT_STATE_RETIRED);
		(void)erx_cap_slot_seq_store(&page[0],
		    ERX_CAP_SLOT_SEQ_TERMINAL);
	}
	atomic_store_explicit(&table->pages[index], page, memory_order_release);
	for (i = capacity == 0 ? 1 : capacity; i < end; i++)
		cap_free_append(table, i);
	atomic_store_explicit(&table->capacity, end, memory_order_release);
	return (ERX_OK);
}

void
erx_cap_table_set_emptied(erx_cap_table_t *table)
{
	table->emptied = true;
}

/* The lookup. */

/*
 * Whether cap is a reserved value that self resolves, and the state of a live
 * slot it reads as: generation 0, which is what a reserved value holds.
 */
static bool
cap_self_fields(const erx_cap_self_t *self, erx_cap_t cap, cap_fields_t *fields)
{
	erx_create_kind_t kind;
	uint64_t object;

	if (self == NULL)
		return (false);
	if (cap.raw == ERX_CAP_SELF) {
		kind = ERX_KIND_RESERVED_SPACE;
		object = self->space;
	} else if (cap.raw == ERX_CAP_SELF_THREAD) {
		kind = ERX_KIND_RESERVED_THREAD;
		object = self->thread;
	} else
		return (false);
	if (object == 0)
		return (false);
	*fields = (cap_fields_t){
		.object = object,
		.generation = 0,
		.rights = erx_kind_default_mask(kind),
		.type = erx_kind_ktype(kind),
		.state = ERX_CAP_SLOT_STATE_LIVE,
	};
	return (true);
}

/*
 * One consistent state of slot index. A writer holds its count odd only
 * between two stores under the table's lock, so each attempt below waits at
 * most for one write to finish; the attempts repeat for as long as writers
 * keep writing that one slot, so the loop has no fixed bound.
 */
static erx_status_t
cap_read_slot(const erx_cap_table_t *table, uint32_t index, cap_fields_t *copy)
{
	const erx_cap_slot_t *slot;
	uint64_t before, after;

	if (index == 0 || index >= atomic_load_explicit(&table->capacity,
	    memory_order_acquire))
		return (ERX_ESTALE);
	slot = cap_slot_at(table, index);
	for (;;) {
		before = cap_seq(slot);
		if (erx_cap_slot_seq_status(before) != ERX_OK)
			return (ERX_ESTALE);
		if ((before & 1) != 0)
			continue;
		cap_load(slot, copy);
		after = cap_seq(slot);
		if (after == before)
			return (ERX_OK);
	}
}

/*
 * A reserved value that self resolves reads as a live slot, so it meets the
 * same checks as a real one; its index becomes 0, which names no slot.
 */
erx_status_t
erx_cap_read(const erx_cap_table_t *table, const erx_cap_self_t *self,
    erx_cap_t cap, erx_ktype_t type, uint32_t required, erx_cap_view_t *viewp)
{
	uint32_t index = (uint32_t)(cap.raw & CAP_SLOT_MASK);
	uint64_t generation = cap.raw >> ERX_CAP_SLOT_BITS;
	cap_fields_t copy;
	erx_status_t status;

	if (cap_self_fields(self, cap, &copy))
		index = 0;
	else {
		status = cap_read_slot(table, index, &copy);
		if (status != ERX_OK)
			return (status);
	}
	if (copy.state != ERX_CAP_SLOT_STATE_LIVE ||
	    copy.generation != generation)
		return (ERX_ESTALE);
	if (type != ERX_CAP_ANY_TYPE && copy.type != type)
		return (ERX_ETYPE);
	if ((copy.rights & required) != required)
		return (ERX_ERIGHTS);
	viewp->object = copy.object;
	viewp->type = copy.type;
	viewp->rights.bits = copy.rights;
	viewp->slot = index;
	viewp->generation = generation;
	return (ERX_OK);
}

/*
 * The handle of a live slot always names a record; a host handle outside
 * the test store names none, and is stale like any other.
 */
erx_status_t
erx_cap_lookup(const erx_cap_table_t *table, const erx_cap_self_t *self,
    erx_cap_t cap, erx_ktype_t type, uint32_t required, erx_uref_t *refp)
{
	erx_cap_view_t view;
	erx_object_t *object;
	erx_status_t status;

	status = erx_cap_read(table, self, cap, type, required, &view);
	if (status != ERX_OK)
		return (status);
	object = erx_object_from_handle(view.object);
	if (object == NULL || !cap_object_reachable(object))
		return (ERX_ESTALE);
	*refp = erx_uref_make(object);
	return (ERX_OK);
}

/* Writers. */

/*
 * Fill the oldest free slot with a capability to object, counted and
 * linked on its list; the callers have checked type and rights.
 */
static erx_status_t
cap_install(erx_cap_table_t *table, erx_object_t *object, erx_ktype_t type,
    erx_rights_t rights, erx_cap_t *capp)
{
	cap_fields_t live;
	erx_cap_slot_t *slot;
	erx_status_t status;
	uint32_t index;

	if (table->nfree == 0)
		return (ERX_ELIMIT);
	status = erx_object_cap_add(object);
	if (status != ERX_OK)
		return (status);
	index = cap_free_take(table);
	slot = cap_slot_at(table, index);
	live.object = erx_object_handle(object);
	live.generation = cap_generation(slot);
	live.rights = rights.bits;
	live.type = type;
	live.state = ERX_CAP_SLOT_STATE_LIVE;
	cap_slot_write(slot, &live);
	cap_list_insert(object, slot);
	*capp = cap_value(index, live.generation);
	return (ERX_OK);
}

erx_status_t
erx_cap_install_kind(erx_cap_table_t *table, erx_object_t *object,
    erx_create_kind_t kind, uint32_t mask, erx_cap_t *capp)
{
	erx_ktype_t type = erx_kind_ktype(kind);

	if (table->emptied)
		return (ERX_EDEAD);
	if (type == 0 || type != erx_object_type(object) ||
	    kind == ERX_KIND_RESERVED_SPACE || kind == ERX_KIND_RESERVED_THREAD)
		return (ERX_EINVAL);
	return (cap_install(table, object, type,
	    erx_rights_shrink(erx_rights_create(kind), mask), capp));
}

erx_status_t
erx_cap_install_copy(erx_cap_table_t *to, const erx_cap_table_t *from,
    erx_cap_t cap, erx_object_t *object, uint32_t mask, erx_cap_t *capp)
{
	uint32_t index = (uint32_t)(cap.raw & CAP_SLOT_MASK);
	uint64_t generation = cap.raw >> ERX_CAP_SLOT_BITS;
	cap_fields_t source;
	erx_rights_t rights;

	if (to->emptied)
		return (ERX_EDEAD);
	/* Under the object's lock, a slot naming it cannot change. */
	if (cap_read_slot(from, index, &source) != ERX_OK ||
	    source.state != ERX_CAP_SLOT_STATE_LIVE ||
	    source.generation != generation ||
	    source.object != erx_object_handle(object))
		return (ERX_ESTALE);
	rights.bits = source.rights;
	if (!erx_rights_contain(rights, ERX_HR_DUP))
		return (ERX_ERIGHTS);
	return (cap_install(to, object, source.type,
	    erx_rights_shrink(rights, mask), capp));
}

erx_status_t
erx_cap_slot_clear(erx_cap_table_t *table, erx_cap_t cap,
    erx_object_t *object, bool *releasedp)
{
	uint32_t index = (uint32_t)(cap.raw & CAP_SLOT_MASK);
	uint64_t generation = cap.raw >> ERX_CAP_SLOT_BITS;
	erx_cap_slot_t *slot, *prev, *next;

	*releasedp = false;
	if (!cap_slot_names(table, index, generation,
	    erx_object_handle(object)))
		return (ERX_ESTALE);
	slot = cap_slot_at(table, index);
	/*
	 * Unlink the slot here, not in a helper, so that the attachment
	 * chokepoint sees erx_cap_slot_clear itself as the one remover from
	 * the slot list, as erx_attach_object_slots is its one insert.
	 */
	prev = cap_obj_prev(slot);
	next = cap_obj_next(slot);
	if (prev == NULL)
		erx_object_set_slots(object, next);
	else
		cap_set_obj_next(prev, next);
	if (next != NULL)
		cap_set_obj_prev(next, prev);
	cap_set_obj_prev(slot, NULL);
	cap_set_obj_next(slot, NULL);
	if (cap_slot_close(slot, generation + 1))
		cap_free_append(table, index);
	*releasedp = erx_object_cap_remove(object);
	return (ERX_OK);
}

void
erx_cap_slot_name(const erx_cap_slot_t *slot, erx_cap_table_t **tablep,
    erx_cap_t *capp)
{
	uintptr_t at = (uintptr_t)slot, base;
	erx_cap_table_t *table;
	uint64_t address = 0;
	uint32_t i;

	(void)erx_cap_slot_table_load(slot, &address);
	if (address == 0)
		__builtin_trap();
	table = (erx_cap_table_t *)(uintptr_t)address;
	/*
	 * A listed slot's page is in its table's directory, which never
	 * moves; the bound is the directory's, fixed for the table's life.
	 */
	for (i = 0; i < table->npages_max; i++) {
		base = (uintptr_t)atomic_load_explicit(&table->pages[i],
		    memory_order_relaxed);
		if (base == 0)
			break;
		if (at >= base && at - base < CAP_PAGE_BYTES) {
			*tablep = table;
			*capp = cap_value(i * ERX_CAP_PAGE_SLOTS +
			    (uint32_t)((at - base) / ERX_CAP_SLOT_SIZE),
			    cap_generation(slot));
			return;
		}
	}
	__builtin_trap();
}

erx_status_t
erx_cap_reserve(erx_cap_table_t *table, uint32_t count,
    erx_cap_reservation_t *reservation)
{
	cap_fields_t held = {
		.object = 0,
		.rights = 0,
		.type = 0,
		.state = ERX_CAP_SLOT_STATE_RESERVED,
	};
	uint32_t index;
	uint32_t i;

	if (count > ERX_MSG_CAPS)
		return (ERX_EINVAL);
	/* Overwriting held slots would strand them off the free list. */
	if (reservation->count != 0)
		return (ERX_EBUSY);
	if (table->emptied)
		return (ERX_EDEAD);
	if (table->nfree < count)
		return (ERX_ELIMIT);
	for (i = 0; i < count; i++) {
		index = cap_free_take(table);
		held.generation = cap_generation(cap_slot_at(table, index));
		cap_slot_write(cap_slot_at(table, index), &held);
		reservation->slots[i] = index;
	}
	reservation->count = count;
	return (ERX_OK);
}

/* A reserved slot was named by no value, so its generation stays. */
void
erx_cap_release_reservation(erx_cap_table_t *table,
    erx_cap_reservation_t *reservation)
{
	uint32_t capacity = atomic_load_explicit(&table->capacity,
	    memory_order_relaxed);
	erx_cap_slot_t *slot;
	uint32_t index;
	uint32_t i;

	for (i = 0; i < reservation->count && i < ERX_MSG_CAPS; i++) {
		index = reservation->slots[i];
		if (index == 0 || index >= capacity)
			continue;
		slot = cap_slot_at(table, index);
		if (cap_state(slot) !=
		    ERX_CAP_SLOT_STATE_RESERVED)
			continue;
		if (cap_slot_close(slot,
		    cap_generation(slot)))
			cap_free_append(table, index);
	}
	reservation->count = 0;
}

/* Passes. */

/* Whether a capability leaves the caller's own table, so it needs GIVE. */
static bool
cap_route_from_own(erx_pass_route_t route)
{
	return (route == ERX_PASS_RENDEZVOUS ||
	    route == ERX_PASS_OWN_TO_CREATED);
}

/* Whether the pass enters a space the caller created: the creator's rule. */
static bool
cap_route_to_created(erx_pass_route_t route)
{
	return (route == ERX_PASS_OWN_TO_CREATED ||
	    route == ERX_PASS_CREATED_TO_CREATED);
}

/* Plan item i of a request whose count and route have been checked. */
static erx_status_t
cap_plan_item(const erx_pass_request_t *request,
    const erx_pass_source_t *sources, uint32_t i, erx_pass_step_t *step)
{
	const erx_pass_item_t *item = &request->items[i];
	const erx_cap_view_t *view = &sources[i].view;
	erx_pass_route_t route = (erx_pass_route_t)request->route;
	erx_rights_t rights;
	uint32_t pass;
	uint32_t j;

	/* A view is valid only on ERX_OK, so nothing reads it before. */
	if (sources[i].status != ERX_OK)
		return (sources[i].status);
	/* A reserved value names no slot, so there is nothing to pass. */
	if (view->slot == 0)
		return (ERX_ESTALE);
	pass = erx_ktype_pass_mask(view->type);
	for (j = 0; j < i; j++)
		if (sources[j].view.slot == view->slot)
			return (ERX_EINVAL);
	if (item->op != ERX_PASS_COPY && item->op != ERX_PASS_MOVE)
		return (ERX_EINVAL);
	if (item->type != ERX_CAP_ANY_TYPE && item->type != view->type)
		return (ERX_ETYPE);
	if (!erx_rights_contain(view->rights, item->required))
		return (ERX_ERIGHTS);
	if (cap_route_from_own(route) && !erx_rights_contain(view->rights,
	    ERX_HR_GIVE))
		return (ERX_ERIGHTS);
	if (item->op == ERX_PASS_COPY && !erx_rights_contain(view->rights,
	    ERX_HR_DUP))
		return (ERX_ERIGHTS);
	if (!cap_route_to_created(route) && pass == 0)
		return (ERX_ETYPE);
	rights = erx_rights_shrink(view->rights, item->mask);
	if (!cap_route_to_created(route))
		rights = erx_rights_shrink(rights, pass);
	else {
		/* The creator's rule: a space's structure and CODE stay home. */
		if (view->type == ERX_K_SPACE)
			rights = erx_rights_shrink(rights, ERX_HR_INSPECT);
		rights = erx_rights_shrink(rights, ~ERX_HR_CODE);
	}
	step->op = (erx_pass_op_t)item->op;
	step->slot = view->slot;
	step->generation = view->generation;
	step->object = view->object;
	step->type = view->type;
	step->rights = rights;
	step->released = false;
	return (ERX_OK);
}

erx_status_t
erx_pass_plan(const erx_pass_request_t *request,
    const erx_pass_source_t *sources, erx_pass_plan_t *plan)
{
	erx_status_t status;
	uint32_t i;

	plan->stage = ERX_PASS_REFUSED;
	plan->route = (erx_pass_route_t)request->route;
	plan->from = request->from;
	plan->to = request->to;
	plan->count = 0;
	plan->failed = request->count;
	if (request->count > ERX_MSG_CAPS ||
	    request->route < ERX_PASS_RENDEZVOUS ||
	    request->route > ERX_PASS_CREATED_TO_CREATED)
		return (ERX_EINVAL);
	if (request->count > request->room)
		return (ERX_ELIMIT);
	for (i = 0; i < request->count; i++) {
		status = cap_plan_item(request, sources, i, &plan->steps[i]);
		if (status != ERX_OK) {
			plan->failed = i;
			return (status);
		}
	}
	plan->count = request->count;
	plan->stage = ERX_PASS_PLANNED;
	return (ERX_OK);
}

erx_status_t
erx_pass_take(erx_pass_plan_t *plan, erx_cap_table_t *from,
    const erx_cap_reservation_t *reservation)
{
	erx_object_t *objects[ERX_MSG_CAPS];
	const erx_pass_step_t *step;
	cap_fields_t source;
	bool released;
	uint32_t i, j;

	if (plan->stage != ERX_PASS_PLANNED || plan->count > ERX_MSG_CAPS ||
	    from != plan->from)
		return (ERX_EINVAL);
	/* Check the whole pass before the first change. */
	for (i = 0; i < plan->count; i++) {
		step = &plan->steps[i];
		if (!cap_slot_names(from, step->slot, step->generation,
		    step->object))
			return (ERX_ESTALE);
		/*
		 * A slot's type and rights are fixed for its life, so these
		 * hold for any plan erx_pass_plan made from this slot.
		 */
		cap_load(cap_slot_at(from, step->slot), &source);
		if (source.type != step->type ||
		    (step->rights.bits & ~source.rights) != 0 ||
		    (step->op != ERX_PASS_COPY && step->op != ERX_PASS_MOVE))
			return (ERX_EINVAL);
		for (j = 0; j < i; j++)
			if (plan->steps[j].slot == step->slot)
				return (ERX_EINVAL);
		/*
		 * The object's capability lock, held since the plan, keeps
		 * its state and its count as read here until the install.
		 */
		objects[i] = erx_object_from_handle(step->object);
		if (objects[i] == NULL)
			return (ERX_EINVAL);
		if (erx_object_state(objects[i]) != ERX_OBJ_LIVE)
			return (ERX_ESTALE);
		if (erx_object_ncaps(objects[i]) > UINT32_MAX - ERX_MSG_CAPS)
			return (ERX_ELIMIT);
	}
	if (reservation->count < plan->count)
		return (ERX_ELIMIT);
	/*
	 * Each step's count first, so a move's clear never takes the count to
	 * zero: the step's count is the one the receiver's slot will hold.
	 */
	for (i = 0; i < plan->count; i++)
		if (erx_object_cap_add(objects[i]) != ERX_OK)
			__builtin_trap();
	for (i = 0; i < plan->count; i++) {
		step = &plan->steps[i];
		if (step->op != ERX_PASS_MOVE)
			continue;
		if (erx_cap_slot_clear(from, cap_value(step->slot,
		    step->generation), objects[i], &released) != ERX_OK ||
		    released)
			__builtin_trap();
	}
	plan->stage = ERX_PASS_TAKEN;
	return (ERX_OK);
}

/*
 * Whether a taken plan can fill to's reservation: ERX_EDEAD once the table
 * is emptied, ERX_EINVAL when the reservation no longer holds the plan's
 * count of distinct reserved slots, which breaks the receiver's hold.
 */
static erx_status_t
cap_install_verdict(const erx_pass_plan_t *plan, const erx_cap_table_t *to,
    const erx_cap_reservation_t *reservation)
{
	uint32_t capacity = atomic_load_explicit(&to->capacity,
	    memory_order_relaxed);
	uint32_t index;
	uint32_t i, j;

	if (to->emptied)
		return (ERX_EDEAD);
	if (reservation->count > ERX_MSG_CAPS ||
	    reservation->count < plan->count)
		return (ERX_EINVAL);
	for (i = 0; i < plan->count; i++) {
		index = reservation->slots[i];
		if (index == 0 || index >= capacity ||
		    cap_state(cap_slot_at(to, index)) !=
		    ERX_CAP_SLOT_STATE_RESERVED)
			return (ERX_EINVAL);
		for (j = 0; j < i; j++)
			if (reservation->slots[j] == index)
				return (ERX_EINVAL);
	}
	return (ERX_OK);
}

/*
 * Fill the reservation's first slots in the plan's order, each linked on
 * its object's list with the count take made for it, and write results.
 */
static void
cap_pass_fill(const erx_pass_plan_t *plan, erx_cap_table_t *to,
    erx_cap_reservation_t *reservation, erx_pass_result_t *results)
{
	const erx_pass_step_t *step;
	erx_cap_slot_t *slot;
	cap_fields_t live;
	uint32_t i;

	for (i = 0; i < plan->count; i++) {
		step = &plan->steps[i];
		slot = cap_slot_at(to, reservation->slots[i]);
		live.object = step->object;
		live.generation = cap_generation(slot);
		live.rights = step->rights.bits;
		live.type = step->type;
		live.state = ERX_CAP_SLOT_STATE_LIVE;
		cap_slot_write(slot, &live);
		cap_list_insert(erx_object_from_handle(step->object), slot);
		results[i].cap = cap_value(reservation->slots[i],
		    live.generation);
		results[i].type = step->type;
		results[i].rights = step->rights;
	}
	/* Filled slots leave the reservation; the rest stay held. */
	for (i = plan->count; i < reservation->count; i++)
		reservation->slots[i - plan->count] = reservation->slots[i];
	reservation->count -= plan->count;
}

/*
 * The drop counts out here, not in a helper, so that the release
 * chokepoint sees erx_pass_install itself as erx_object_cap_remove's
 * caller.
 */
erx_status_t
erx_pass_install(erx_pass_plan_t *plan, erx_cap_table_t *to,
    erx_cap_reservation_t *reservation, erx_pass_result_t *results)
{
	erx_pass_step_t *step;
	erx_status_t status;
	uint32_t i;

	for (i = 0; i < ERX_MSG_CAPS; i++)
		results[i] = (erx_pass_result_t){ .cap = { 0 }, .type = 0,
		    .rights = { 0 } };
	if (plan->stage != ERX_PASS_TAKEN || plan->count > ERX_MSG_CAPS ||
	    to != plan->to)
		return (ERX_EINVAL);
	/* Past this, the pass is filled or dropped and never installed again. */
	plan->stage = ERX_PASS_INSTALLED;
	status = cap_install_verdict(plan, to, reservation);
	if (status == ERX_OK) {
		cap_pass_fill(plan, to, reservation, results);
		return (ERX_OK);
	}
	/* Dropped as a close drops it: each step's count goes. */
	for (i = 0; i < plan->count; i++) {
		step = &plan->steps[i];
		step->released = erx_object_cap_remove(
		    erx_object_from_handle(step->object));
	}
	return (status);
}
