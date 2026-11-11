/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: the slot lists of the capability table (kernel/core/cap.c),
 * and erx_cap_lookup's reference. Each object's list, through the slots'
 * obj_prev and obj_next, holds exactly the live slots that name it, and
 * its count is their number; a lookup hands out a reference only to a
 * reachable object that a live slot at the value's generation names.
 *
 * Bounds: one table of one page of PAGE_SLOTS = 4 slots, at least
 * SLOT_STEPS + 2, as many as its limit, and two objects, one of them paid for by a budget dead or alive at random;
 * SLOT_STEPS = 2 calls, each an erx_cap_install_kind, an
 * erx_cap_install_copy, an erx_cap_slot_clear or a destroy's close of
 * either object, with every mask and object argument; then one
 * erx_cap_lookup. The free list is FIFO, so SLOT_STEPS installs reach only
 * slots 1 to SLOT_STEPS, and the checks walk those; within the bound a
 * slot's generation is 0 or 1. The values the calls take name slot 0 to
 * SLOT_STEPS + 1 at generation 0 or 1: every slot the steps reach, the
 * never-issued slot 0 and a free one, live and stale; cap_read's harness covers
 * every other value. Loops unwound 6 times; the table set-up's loops over
 * the page PAGE_SLOTS + 1 times.
 *
 * Why this small page checks what the ABI's full page would. Tables with
 * either page, each limited to its page, differ in the limit, the
 * capacity, the free count, the free list's tail (slot PAGE_SLOTS - 1,
 * against the full page's last slot) and slot PAGE_SLOTS - 1's next,
 * which set-up leaves 0 on the small page and pointing onward on the
 * full one. None of them is observed. Set-up puts slots 1 to
 * PAGE_SLOTS - 1 on the free list in order. A take reads the head's next
 * and removes the head; a clear zeroes its slot's next and appends it
 * after the tail, writing the old tail's next. With at most SLOT_STEPS
 * takes and PAGE_SLOTS - 1 > SLOT_STEPS, the takes hand out slots 1 to
 * SLOT_STEPS on either page and read only their next fields; a clear
 * needs a live slot, so no take follows it and no tail's next is read.
 * The list never runs dry, so no install sees ERX_ELIMIT on either page,
 * and only set-up reads the limit. Every value names a slot below
 * SLOT_STEPS + 2, inside the capacity of either page, so no lookup, copy
 * or clear reads a slot past it, and the full page's other slots stay as
 * set-up left them. With one page, a slot's index divided by the page's
 * length is 0 and the remainder is the index itself on both.
 *
 * Not reached at this bound: a clear of a slot with a neighbour on its
 * list. The one clear two calls allow follows one install, so the
 * neighbour branches of erx_cap_slot_clear never run; the host model and
 * cap_fuzz.c cover them.
 *
 * Assumptions: the object store and the attach insert are stubs that keep
 * erx/object.h's and erx/attach.h's contracts: a slot is counted only on a
 * LIVE object, the last uncount of a LIVE object releases it, a close
 * makes it DELETED, and the insert refuses an object that is not LIVE.
 * The runner checks one core per harness; the object store's own
 * contract is its host model's and fuzz target's. The callers hold the
 * locks the writers name (the object's capability lock and the table's),
 * which a single thread gives; each
 * _Atomic access is indivisible and sequentially consistent
 * (test/cbmc/include/stdatomic.h). The budget's death is a stub
 * returning a value chosen at random and fixed for the run.
 *
 * Checked, after every call: for each object, its list ends within its
 * count, every slot on it is live and names the object, each slot's
 * obj_prev is the slot before it, and the count of live slots naming the
 * object, over the reachable slots, equals the list's length and the
 * object's count; a slot that is not live is on no list. A writer reports
 * only its statuses, and no kernel trap is reached. After the lookup: a
 * reference names a live, unpaid-or-living object that the value's slot
 * names at its generation.
 */

#include "cbmc_harness.h"

#ifndef SLOT_STEPS
#define SLOT_STEPS	2
#endif
#define NOBJECTS	2

/*
 * The table's page, cut from the ABI's ERX_CAP_PAGE_SLOTS to PAGE_SLOTS
 * slots, at least slot 0, every slot the steps install and one free.
 * cap.c reads ERX_CAP_PAGE_SLOTS only as the page's length, and nothing
 * the calls do reaches past slot SLOT_STEPS + 1 (see Bounds above), so
 * the cut changes no result the checks see. It is what keeps the harness
 * cheap: every store through a slot pointer the steps compute is encoded
 * over the whole page, so the formula grows with the page's bytes. The
 * macro is redefined before cap.c, so cap.c builds with the small page,
 * which must divide ERX_CAPS_MAX as a real page does (cap.c's whole-pages
 * assert). The asserts here check that the small page is large enough
 * for the steps and no larger than the ABI's, and that the redefinition
 * is still the one in effect after cap.c.
 */
#define PAGE_SLOTS	4
_Static_assert(SLOT_STEPS + 2 <= PAGE_SLOTS,
    "the page holds slot 0, every slot the steps install and one free");
#include "erx/abi.h"
enum { ABI_PAGE_SLOTS = ERX_CAP_PAGE_SLOTS };
_Static_assert(PAGE_SLOTS <= ABI_PAGE_SLOTS, "the cut page fits in a real one");
#undef ERX_CAP_PAGE_SLOTS
#define ERX_CAP_PAGE_SLOTS	((uint32_t)PAGE_SLOTS)
#include "cap.c"
_Static_assert(ERX_CAP_PAGE_SLOTS == PAGE_SLOTS, "cap.c builds with the cut page");

/* The object store's records, as far as the capability table sees them. */
struct erx_object {
	erx_ktype_t	 type;
	uint32_t	 state;		/* an erx_obj_state_t; only advances */
	uint32_t	 ncaps;
	erx_cap_slot_t	*slots;
	struct erx_budget *budget;
};

static erx_cap_table_t table;
static _Atomic(erx_cap_slot_t *) directory[1];
static erx_cap_slot_t page[PAGE_SLOTS];
static erx_object_t objects[NOBJECTS];
static uint64_t budget_storage;
static bool budget_is_dead;

bool
erx_budget_dead(const struct erx_budget *budget)
{
	__CPROVER_assert(budget == (const struct erx_budget *)&budget_storage,
	    "only the objects' budget is asked about");
	return (budget_is_dead);
}

erx_obj_state_t
erx_object_state(const erx_object_t *object)
{
	return ((erx_obj_state_t)object->state);
}

erx_ktype_t
erx_object_type(const erx_object_t *object)
{
	return (object->type);
}

struct erx_budget *
erx_object_budget(const erx_object_t *object)
{
	return (object->budget);
}

uint32_t
erx_object_ncaps(const erx_object_t *object)
{
	return (object->ncaps);
}

erx_status_t
erx_object_cap_add(erx_object_t *object)
{
	if (object->state != ERX_OBJ_LIVE)
		return (ERX_ESTALE);
	object->ncaps++;
	return (ERX_OK);
}

bool
erx_object_cap_remove(erx_object_t *object)
{
	__CPROVER_assert(object->ncaps > 0,
	    "a slot is uncounted only from an object that counts it");
	object->ncaps--;
	if (object->ncaps != 0)
		return (false);
	if (object->state == ERX_OBJ_LIVE)
		object->state = ERX_OBJ_RELEASED;
	return (true);
}

bool
erx_object_close(erx_object_t *object)
{
	bool first = object->state != ERX_OBJ_DELETED;

	object->state = ERX_OBJ_DELETED;
	return (first);
}

erx_cap_slot_t *
erx_object_slots(const erx_object_t *object)
{
	return (object->slots);
}

void
erx_object_set_slots(erx_object_t *object, erx_cap_slot_t *head)
{
	object->slots = head;
}

uint64_t
erx_object_handle(const erx_object_t *object)
{
	return ((uint64_t)(uintptr_t)object);
}

erx_object_t *
erx_object_from_handle(uint64_t handle)
{
	return ((erx_object_t *)(uintptr_t)handle);
}

erx_uref_t
erx_uref_make(erx_object_t *object)
{
	return ((erx_uref_t){ .object = object, .epoch = 1 });
}

erx_status_t
erx_attach_object_slots(erx_object_t *object, erx_cap_slot_t *slot,
    erx_cap_slot_t **nextp)
{
	if (object->state != ERX_OBJ_LIVE)
		return (ERX_ESTALE);
	*nextp = object->slots;
	object->slots = slot;
	return (ERX_OK);
}

/*
 * A capability value naming slot 0 to SLOT_STEPS + 1 at generation 0 or
 * 1, the generations a slot can have within the bound.
 */
static erx_cap_t
reachable_value(void)
{
	uint64_t index = nondet_u64(), generation = nondet_u64();

	__CPROVER_assume(index <= SLOT_STEPS + 1 && generation <= 1);
	return ((erx_cap_t){ .raw = generation << ERX_CAP_SLOT_BITS | index });
}

static bool
names(const erx_cap_slot_t *slot, const erx_object_t *object)
{
	cap_fields_t fields;

	cap_load(slot, &fields);
	return (fields.state == ERX_CAP_SLOT_STATE_LIVE &&
	    fields.object == erx_object_handle(object));
}

static void
check_lists(void)
{
	const erx_cap_slot_t *at, *before;
	uint32_t i, o, walked, counted;
	cap_fields_t fields;

	for (o = 0; o < NOBJECTS; o++) {
		before = NULL;
		walked = 0;
		for (at = objects[o].slots; at != NULL && walked <= SLOT_STEPS;
		    at = cap_obj_next(at)) {
			__CPROVER_assert(names(at, &objects[o]),
			    "every slot on an object's list is live and names it");
			__CPROVER_assert(cap_obj_prev(at) == before,
			    "each slot's obj_prev is the slot before it");
			before = at;
			walked++;
		}
		__CPROVER_assert(at == NULL && walked == objects[o].ncaps,
		    "an object's list ends at its count");
		counted = 0;
		for (i = 1; i <= SLOT_STEPS; i++)
			counted += names(&page[i], &objects[o]);
		__CPROVER_assert(counted == objects[o].ncaps,
		    "an object's count is the number of live slots naming it");
	}
	for (i = 1; i <= SLOT_STEPS; i++) {
		cap_load(&page[i], &fields);
		if (fields.state != ERX_CAP_SLOT_STATE_LIVE)
			__CPROVER_assert(cap_obj_prev(&page[i]) == NULL &&
			    cap_obj_next(&page[i]) == NULL,
			    "a slot that is not live is on no list");
	}
}

void
harness(void)
{
	erx_cap_t cap, made;
	erx_status_t status;
	erx_uref_t ref = { 0 };
	erx_object_t *object;
	uint32_t step, op, which;
	bool released;

	__CPROVER_assume(erx_cap_table_init(&table, directory,
	    sizeof(directory), PAGE_SLOTS) == ERX_OK);
	__CPROVER_assume(erx_cap_table_add_page(&table, page,
	    sizeof(page)) == ERX_OK);
	for (which = 0; which < NOBJECTS; which++) {
		objects[which].type = ERX_K_MEMORY;
		objects[which].state = ERX_OBJ_LIVE;
	}
	objects[1].budget = (struct erx_budget *)&budget_storage;
	budget_is_dead = nondet_bool();

	for (step = 0; step < SLOT_STEPS; step++) {
		op = nondet_u32();
		which = nondet_u32();
		__CPROVER_assume(which < NOBJECTS);
		object = &objects[which];
		cap = reachable_value();
		switch (op) {
		case 0:
			status = erx_cap_install_kind(&table, object,
			    ERX_KIND_BOOT_IMAGE, nondet_u32(), &made);
			__CPROVER_assert(status == ERX_OK || status == ERX_ESTALE,
			    "an install of a kind succeeds or finds the object closed");
			break;
		case 1:
			status = erx_cap_install_copy(&table, &table, cap, object,
			    nondet_u32(), &made);
			__CPROVER_assert(status == ERX_OK || status == ERX_ESTALE ||
			    status == ERX_ERIGHTS,
			    "a copy succeeds, finds its source stale or lacks the right");
			break;
		case 2:
			status = erx_cap_slot_clear(&table, cap, object, &released);
			__CPROVER_assert(status == ERX_OK || status == ERX_ESTALE,
			    "a clear succeeds or finds its value stale");
			break;
		default:
			(void)erx_object_close(object);
			break;
		}
		check_lists();
	}

	cap = reachable_value();
	status = erx_cap_lookup(&table, NULL, cap, ERX_CAP_ANY_TYPE, 0, &ref);
	if (status != ERX_OK)
		return;
	object = ref.object;
	__CPROVER_assert(object == &objects[0] || object == &objects[1],
	    "a reference names an object of the table");
	__CPROVER_assert(erx_object_state(object) == ERX_OBJ_LIVE &&
	    (object->budget == NULL || !budget_is_dead),
	    "a lookup refers only to a live object whose budget lives");
	__CPROVER_assert(names(&page[cap.raw & CAP_SLOT_MASK], object) &&
	    cap_generation(&page[cap.raw & CAP_SLOT_MASK]) ==
	    cap.raw >> ERX_CAP_SLOT_BITS,
	    "a reference is to the object its slot names at its generation");
}
