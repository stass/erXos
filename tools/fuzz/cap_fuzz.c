/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the capability core with the values, masks, types and counts a
 * domain controls, decoded from the input as a sequence of operations on
 * two tables, and aborts when an invariant breaks:
 *
 *   K1: a lookup accepts only the current value of a live slot, and its
 *       view is what that slot was given;
 *   K2: no lookup, plan or pass yields a right its source lacked, and a
 *       peer pass stays within the type's pass set, and CODE never passes;
 *   an accepted plan is taken once, before it is installed, and
 *   installed once; its take succeeds unless a source or the
 *   reservation changed after the plan, and its install unless the
 *   destination was emptied or the reservation changed after the take;
 *   a failed install writes no result;
 *   K21: each object counts exactly the live slots that name it, in both
 *       tables, and lists each once; a clear or a dropped pass reports the
 *       release exactly when the last of them went, and a lookup returns
 *       the object a live slot names only while it is LIVE.
 *
 * A seed operation moves a free slot's generation or count near its end,
 * so slots retire within an input.
 *
 * Each operation is one byte of opcode followed by its operands.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/object.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define FUZZ_LIMIT	70
#define FUZZ_PAGES	2
/* Two objects of each type, handle h of type (h - 1) % 9 + 1. */
#define FUZZ_TYPES	9
#define FUZZ_OBJECTS	(2 * FUZZ_TYPES)
#define FUZZ_GENERATION_LIMIT ((UINT64_C(1) << ERX_CAP_GENERATION_BITS) - 1)
#define FUZZ_INDEX(cap) ((uint32_t)((cap).raw & 0xffffff))

typedef struct fuzz_slot {
	uint64_t	 value;		/* the live value, 0 when none */
	uint64_t	 object;
	uint32_t	 type;
	uint32_t	 rights;
} fuzz_slot_t;

typedef struct fuzz_table {
	erx_cap_table_t		 table;
	_Atomic(erx_cap_slot_t *) dir[FUZZ_PAGES];
	erx_cap_slot_t		 pages[FUZZ_PAGES][ERX_CAP_PAGE_SLOTS];
	uint32_t		 npages;
	erx_cap_reservation_t	 reservation;
	fuzz_slot_t		 shadow[FUZZ_LIMIT];
} fuzz_table_t;

typedef struct fuzz_input {
	const uint8_t	*bytes;
	size_t		 size;
} fuzz_input_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static fuzz_table_t tables[2];
static erx_object_store_t *store;
static erx_object_t *objects[FUZZ_OBJECTS];

/* One thread, never at a preemption point, takes no budget's lock. */
uint32_t
erx_effect_thread_epoch(void)
{
	return (0);
}

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	(void)budget;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	(void)budget;
}

static uint64_t
fuzz_take(fuzz_input_t *in, size_t width)
{
	uint64_t value = 0;
	size_t i;

	for (i = 0; i < width && in->size > 0; i++) {
		value |= (uint64_t)in->bytes[0] << (8 * i);
		in->bytes++;
		in->size--;
	}
	return (value);
}

static void
fuzz_check(bool condition)
{
	if (!condition)
		abort();
}

static erx_ktype_t
fuzz_object_type(uint64_t handle)
{
	return ((erx_ktype_t)((handle - 1) % FUZZ_TYPES + 1));
}

/* The live slots both tables' shadows hold for an object. */
static uint32_t
fuzz_shadow_count(uint64_t handle)
{
	uint32_t t, i, n = 0;

	for (t = 0; t < 2; t++)
		for (i = 0; i < FUZZ_LIMIT; i++)
			n += tables[t].shadow[i].value != 0 &&
			    tables[t].shadow[i].object == handle;
	return (n);
}

/*
 * K21: every object counts its live slots, and its list holds exactly
 * them: each listed slot is live and names it, and each back link mirrors
 * the link before it.
 */
static void
fuzz_check_counts(void)
{
	const erx_cap_slot_t *slot, *prev;
	uint64_t h, next, back, named;
	uint32_t n, state;

	for (h = 1; h <= FUZZ_OBJECTS; h++) {
		fuzz_check(erx_object_ncaps(objects[h - 1]) ==
		    fuzz_shadow_count(h));
		n = 0;
		prev = NULL;
		for (slot = erx_object_slots(objects[h - 1]); slot != NULL;
		    slot = (const erx_cap_slot_t *)(uintptr_t)next) {
			fuzz_check(++n <= FUZZ_LIMIT * 2);
			(void)erx_cap_slot_obj_prev_load(slot, &back);
			(void)erx_cap_slot_object_load(slot, &named);
			(void)erx_cap_slot_state_load(slot, &state);
			fuzz_check(back == (uint64_t)(uintptr_t)prev && named == h &&
			    state == ERX_CAP_SLOT_STATE_LIVE);
			prev = slot;
			(void)erx_cap_slot_obj_next_load(slot, &next);
		}
		fuzz_check(n == erx_object_ncaps(objects[h - 1]));
	}
}

/* A release leaves no live slot naming the object, and frees it to reuse. */
static void
fuzz_released(uint64_t handle)
{
	fuzz_check(fuzz_shadow_count(handle) == 0 &&
	    erx_object_state(objects[handle - 1]) == ERX_OBJ_RELEASED);
	fuzz_check(erx_object_init(store, objects[handle - 1],
	    fuzz_object_type(handle), NULL) == ERX_OK);
}

/* The object store's handles of the fuzzed caller's space and thread. */
static const erx_cap_self_t fuzz_self = { 0x5a, 0x7b };

/* A value the fuzzer chose, or now and then one the table issued. */
static erx_cap_t
fuzz_value(fuzz_input_t *in, fuzz_table_t *t)
{
	uint64_t raw = fuzz_take(in, 1);
	erx_cap_t cap;

	if (raw < FUZZ_LIMIT && t->shadow[raw].value != 0)
		cap.raw = t->shadow[raw].value ^ (fuzz_take(in, 1) == 0 ?
		    UINT64_C(1) << ERX_CAP_SLOT_BITS : 0);
	else if (raw == FUZZ_LIMIT)
		cap.raw = ERX_CAP_SELF;
	else if (raw == FUZZ_LIMIT + 1)
		cap.raw = ERX_CAP_SELF_THREAD;
	else
		cap.raw = raw << 56 | fuzz_take(in, 7);
	return (cap);
}

static void
fuzz_read(fuzz_table_t *t, erx_cap_t cap, erx_ktype_t type, uint32_t required)
{
	uint32_t index = (uint32_t)(cap.raw & ((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1));
	erx_cap_view_t view;
	const fuzz_slot_t *s;

	/*
	 * The reserved values name the caller's own objects with the view of
	 * self, and nothing without it; neither touches the table.
	 */
	if (cap.raw == ERX_CAP_SELF || cap.raw == ERX_CAP_SELF_THREAD) {
		const erx_cap_self_t none = { 0, 0 };
		bool space = cap.raw == ERX_CAP_SELF;
		erx_create_kind_t kind = space ? ERX_KIND_RESERVED_SPACE :
		    ERX_KIND_RESERVED_THREAD;
		uint32_t rights = erx_kind_default_mask(kind);
		erx_status_t expected = type != ERX_CAP_ANY_TYPE &&
		    type != erx_kind_ktype(kind) ? ERX_ETYPE :
		    (rights & required) != required ? ERX_ERIGHTS : ERX_OK;

		fuzz_check(erx_cap_read(&t->table, NULL, cap, type, required,
		    &view) == ERX_ESTALE);
		fuzz_check(erx_cap_read(&t->table, &none, cap, type, required,
		    &view) == ERX_ESTALE);
		fuzz_check(erx_cap_read(&t->table, &fuzz_self, cap, type, required,
		    &view) == expected);
		if (expected == ERX_OK)
			fuzz_check(view.slot == 0 && view.rights.bits == rights &&
			    view.type == erx_kind_ktype(kind) && view.object ==
			    (space ? fuzz_self.space : fuzz_self.thread));
		return;
	}
	if (erx_cap_read(&t->table, &fuzz_self, cap, type, required,
	    &view) != ERX_OK)
		return;
	fuzz_check(index < FUZZ_LIMIT);
	s = &t->shadow[index];
	fuzz_check(s->value == cap.raw && view.object == s->object &&
	    view.type == s->type && view.rights.bits == s->rights &&
	    (s->rights & required) == required);
}

static uint64_t
fuzz_object(fuzz_input_t *in)
{
	return (fuzz_take(in, 1) % FUZZ_OBJECTS + 1);
}

static void
fuzz_install(fuzz_input_t *in, fuzz_table_t *t)
{
	erx_create_kind_t kind = (erx_create_kind_t)fuzz_take(in, 1);
	uint32_t mask = (uint32_t)fuzz_take(in, 4);
	uint64_t object = fuzz_object(in);
	erx_cap_t cap;
	uint32_t index;

	if (erx_cap_install_kind(&t->table, objects[object - 1], kind, mask,
	    &cap) != ERX_OK)
		return;
	index = FUZZ_INDEX(cap);
	fuzz_check(index > 0 && index < FUZZ_LIMIT &&
	    t->shadow[index].value == 0 &&
	    erx_kind_ktype(kind) == fuzz_object_type(object));
	t->shadow[index] = (fuzz_slot_t){ cap.raw, object,
	    erx_kind_ktype(kind), erx_rights_create(kind).bits & mask };
}

/* A copy within a table or across, of a value and an object fuzzed. */
static void
fuzz_copy(fuzz_input_t *in, fuzz_table_t *to)
{
	fuzz_table_t *from = &tables[fuzz_take(in, 1) & 1];
	erx_cap_t cap = fuzz_value(in, from), copy;
	uint32_t index = FUZZ_INDEX(cap);
	uint64_t object = fuzz_take(in, 1) == 0 || index >= FUZZ_LIMIT ||
	    from->shadow[index].object == 0 ? fuzz_object(in) :
	    from->shadow[index].object;
	uint32_t mask = (uint32_t)fuzz_take(in, 4);
	const fuzz_slot_t *s;

	if (erx_cap_install_copy(&to->table, &from->table, cap,
	    objects[object - 1], mask, &copy) != ERX_OK)
		return;
	fuzz_check(index < FUZZ_LIMIT);
	s = &from->shadow[index];
	fuzz_check(s->value == cap.raw && s->object == object &&
	    (s->rights & ERX_HR_DUP) != 0);
	index = FUZZ_INDEX(copy);
	fuzz_check(index > 0 && index < FUZZ_LIMIT &&
	    to->shadow[index].value == 0);
	to->shadow[index] = (fuzz_slot_t){ copy.raw, object, s->type,
	    s->rights & mask };
}

static void
fuzz_clear(fuzz_input_t *in, fuzz_table_t *t)
{
	erx_cap_t cap = fuzz_value(in, t);
	uint32_t index = FUZZ_INDEX(cap);
	uint64_t object = index < FUZZ_LIMIT && t->shadow[index].object != 0 ?
	    t->shadow[index].object : 1;
	bool released;

	if (fuzz_take(in, 1) == 0)
		object = object % FUZZ_OBJECTS + 1;
	if (erx_cap_slot_clear(&t->table, cap, objects[object - 1],
	    &released) != ERX_OK) {
		fuzz_check(!released);
		return;
	}
	fuzz_check(index < FUZZ_LIMIT && t->shadow[index].value == cap.raw &&
	    t->shadow[index].object == object);
	t->shadow[index].value = 0;
	fuzz_check(released == (fuzz_shadow_count(object) == 0));
	if (released)
		fuzz_released(object);
}

/* The one lookup returns a live slot's object, which is always LIVE here. */
static void
fuzz_lookup(fuzz_input_t *in, fuzz_table_t *t)
{
	erx_cap_t cap = fuzz_value(in, t);
	erx_ktype_t type = (erx_ktype_t)fuzz_take(in, 1) % 11;
	uint32_t required = (uint32_t)fuzz_take(in, 4);
	erx_cap_view_t view;
	erx_uref_t ref;
	erx_status_t status;

	status = erx_cap_lookup(&t->table, NULL, cap, type, required, &ref);
	fuzz_check(status == erx_cap_read(&t->table, NULL, cap, type, required,
	    &view));
	if (status == ERX_OK)
		fuzz_check(erx_object_handle(erx_uref_get(ref)) == view.object &&
		    t->shadow[FUZZ_INDEX(cap)].object == view.object);
}

/*
 * Move a free slot's generation or count a life or two from its end; the
 * fuzzer cannot otherwise reach either within an input.
 */
static void
fuzz_seed(fuzz_input_t *in, fuzz_table_t *t)
{
	uint32_t index = (uint32_t)fuzz_take(in, 1) % FUZZ_LIMIT;
	uint32_t room = (uint32_t)fuzz_take(in, 1);
	erx_cap_slot_t *slot;
	uint32_t state;

	if (index == 0)
		return;
	slot = &t->pages[index / ERX_CAP_PAGE_SLOTS][index % ERX_CAP_PAGE_SLOTS];
	(void)erx_cap_slot_state_load(slot, &state);
	if (state != ERX_CAP_SLOT_STATE_FREE)
		return;
	if ((room & 0x80) != 0)
		(void)erx_cap_slot_generation_store(slot,
		    FUZZ_GENERATION_LIMIT - 1 - (room & 3));
	else
		(void)erx_cap_slot_seq_store(slot, ERX_CAP_SLOT_SEQ_TERMINAL -
		    5 - 2 * (room & 7));
}

static void
fuzz_pass(fuzz_input_t *in)
{
	fuzz_table_t *from = &tables[fuzz_take(in, 1) & 1];
	fuzz_table_t *to = &tables[fuzz_take(in, 1) & 1];
	uint32_t flags = (uint32_t)fuzz_take(in, 1);
	erx_pass_item_t items[ERX_MSG_CAPS + 1];
	erx_pass_source_t sources[ERX_MSG_CAPS + 1];
	erx_pass_result_t results[ERX_MSG_CAPS];
	erx_pass_request_t request;
	erx_pass_plan_t plan;
	uint32_t n = (uint32_t)fuzz_take(in, 1) % (ERX_MSG_CAPS + 2), i, idx;
	uint32_t route = flags >> 5;
	bool from_own = route == ERX_PASS_RENDEZVOUS ||
	    route == ERX_PASS_OWN_TO_CREATED;
	bool to_created = route == ERX_PASS_OWN_TO_CREATED ||
	    route == ERX_PASS_CREATED_TO_CREATED;
	erx_status_t status;
	bool released;

	for (i = 0; i < n; i++) {
		items[i].cap = fuzz_value(in, from);
		items[i].op = (uint32_t)fuzz_take(in, 1) % 4;
		items[i].mask = (uint32_t)fuzz_take(in, 4);
		items[i].type = (uint32_t)fuzz_take(in, 1) % 11;
		items[i].required = (uint32_t)fuzz_take(in, 1);
		memset(&sources[i], 0, sizeof(sources[i]));
		sources[i].status = erx_cap_read(&from->table,
		    from_own ? &fuzz_self : NULL, items[i].cap,
		    ERX_CAP_ANY_TYPE, 0, &sources[i].view);
	}
	request = (erx_pass_request_t){ items, n, to->reservation.count, route,
	    &from->table, &to->table };
	if (erx_pass_plan(&request, sources, &plan) != ERX_OK) {
		fuzz_check(plan.count == 0 && plan.stage == ERX_PASS_REFUSED);
		fuzz_check(erx_pass_take(&plan, &from->table,
		    &to->reservation) == ERX_EINVAL);
		return;
	}
	for (i = 0; i < plan.count; i++) {
		fuzz_check((plan.steps[i].rights.bits &
		    ~sources[i].view.rights.bits) == 0);
		fuzz_check((plan.steps[i].rights.bits & ~items[i].mask) == 0);
		if (!to_created)
			fuzz_check((plan.steps[i].rights.bits &
			    ~erx_ktype_pass_mask(plan.steps[i].type)) == 0);
		fuzz_check((plan.steps[i].rights.bits & ERX_HR_CODE) == 0);
	}
	/* An install before the take is refused, changing nothing. */
	fuzz_check(erx_pass_install(&plan, &to->table, &to->reservation,
	    results) == ERX_EINVAL && plan.stage == ERX_PASS_PLANNED);
	if ((flags & 4) != 0 && plan.count > 0) {
		/* The first source changes after the plan: take refuses it all. */
		fuzz_check(erx_cap_slot_clear(&from->table, items[0].cap,
		    objects[plan.steps[0].object - 1], &released) == ERX_OK);
		from->shadow[plan.steps[0].slot].value = 0;
		if (released)
			fuzz_released(plan.steps[0].object);
		fuzz_check(erx_pass_take(&plan, &from->table,
		    &to->reservation) == ERX_ESTALE);
		return;
	}
	/* A reservation released before the take no longer holds the pass. */
	if ((flags & 8) != 0)
		erx_cap_release_reservation(&to->table, &to->reservation);
	status = erx_pass_take(&plan, &from->table, &to->reservation);
	fuzz_check(status == ((flags & 8) != 0 && plan.count > 0 ?
	    ERX_ELIMIT : ERX_OK));
	if (status != ERX_OK)
		return;
	fuzz_check(erx_pass_take(&plan, &from->table, &to->reservation) ==
	    ERX_EINVAL);
	for (i = 0; i < plan.count; i++)
		if (plan.steps[i].op == ERX_PASS_MOVE)
			from->shadow[plan.steps[i].slot].value = 0;
	/* Releasing after the take breaks the receiver's hold: dropped. */
	if ((flags & 16) != 0)
		erx_cap_release_reservation(&to->table, &to->reservation);
	status = erx_pass_install(&plan, &to->table, &to->reservation, results);
	if (to->table.emptied)
		fuzz_check(status == ERX_EDEAD);
	else if ((flags & 16) != 0 && plan.count > 0)
		fuzz_check(status == ERX_EINVAL);
	else
		fuzz_check(status == ERX_OK);
	fuzz_check(plan.stage == ERX_PASS_INSTALLED);
	/* A dropped pass releases what it held the last capability to. */
	for (i = 0; status != ERX_OK && i < plan.count; i++)
		if (plan.steps[i].released)
			fuzz_released(plan.steps[i].object);
	for (i = 0; i < ERX_MSG_CAPS; i++)
		fuzz_check((status == ERX_OK && i < plan.count) ||
		    (results[i].cap.raw == 0 && results[i].rights.bits == 0));
	for (i = 0; status == ERX_OK && i < plan.count; i++) {
		idx = (uint32_t)(results[i].cap.raw & 0xffffff);
		fuzz_check(idx > 0 && idx < FUZZ_LIMIT && to->shadow[idx].value == 0);
		to->shadow[idx] = (fuzz_slot_t){ results[i].cap.raw,
		    plan.steps[i].object, results[i].type, results[i].rights.bits };
	}
	/* A second install would fill the next reserved slots: refused. */
	fuzz_check(erx_pass_install(&plan, &to->table, &to->reservation,
	    results) == ERX_EINVAL);
}

static void
fuzz_reset(void)
{
	erx_oid_key_t key = { { 1, 2, 3, 4 } };
	uint32_t t, p;

	if (store == NULL) {
		store = calloc(1, erx_object_store_size());
		fuzz_check(store != NULL);
		for (t = 0; t < FUZZ_OBJECTS; t++) {
			objects[t] = aligned_alloc(erx_object_record_align(),
			    erx_object_record_size());
			fuzz_check(objects[t] != NULL);
		}
		erx_object_test_store(objects, FUZZ_OBJECTS);
	}
	erx_object_store_init(store, &key);
	for (t = 0; t < FUZZ_OBJECTS; t++)
		fuzz_check(erx_object_init(store, objects[t],
		    fuzz_object_type(t + 1), NULL) == ERX_OK);
	memset(tables, 0, sizeof(tables));
	for (t = 0; t < 2; t++) {
		fuzz_check(erx_cap_table_init(&tables[t].table, tables[t].dir,
		    sizeof(tables[t].dir), FUZZ_LIMIT) == ERX_OK);
		for (p = 0; p < FUZZ_PAGES; p++)
			fuzz_check(erx_cap_table_add_page(&tables[t].table,
			    tables[t].pages[p],
			    sizeof(tables[t].pages[p])) == ERX_OK);
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t in = { data, size };
	fuzz_table_t *t;
	erx_cap_t cap;
	uint32_t i;

	fuzz_reset();
	while (in.size > 0) {
		t = &tables[fuzz_take(&in, 1) & 1];
		switch (fuzz_take(&in, 1) % 11) {
		case 0:
			fuzz_install(&in, t);
			break;
		case 1:
			fuzz_clear(&in, t);
			break;
		case 2:
			cap = fuzz_value(&in, t);
			fuzz_read(t, cap, (erx_ktype_t)fuzz_take(&in, 1) % 11,
			    (uint32_t)fuzz_take(&in, 4));
			break;
		case 3:
			(void)erx_cap_reserve(&t->table,
			    (uint32_t)fuzz_take(&in, 1) % 6, &t->reservation);
			break;
		case 4:
			erx_cap_release_reservation(&t->table, &t->reservation);
			break;
		case 5:
			fuzz_pass(&in);
			break;
		case 6:
			if (fuzz_take(&in, 1) == 0xee)
				erx_cap_table_set_emptied(&t->table);
			break;
		case 7:
			fuzz_copy(&in, t);
			break;
		case 8:
			fuzz_lookup(&in, t);
			break;
		case 9:
			fuzz_seed(&in, t);
			break;
		default:
			for (i = 0; i < FUZZ_LIMIT; i++)
				if (t->shadow[i].value != 0) {
					cap.raw = t->shadow[i].value;
					fuzz_read(t, cap, ERX_CAP_ANY_TYPE, 0);
				}
			break;
		}
		fuzz_check_counts();
	}
	return (0);
}
