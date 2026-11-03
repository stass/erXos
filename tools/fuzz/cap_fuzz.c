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
 *   a failed install writes no result.
 *
 * Each operation is one byte of opcode followed by its operands.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/cap.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define FUZZ_LIMIT	70
#define FUZZ_PAGES	2

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

/* A value the fuzzer chose, or now and then one the table issued. */
static erx_cap_t
fuzz_value(fuzz_input_t *in, fuzz_table_t *t)
{
	uint64_t raw = fuzz_take(in, 1);
	erx_cap_t cap;

	if (raw < FUZZ_LIMIT && t->shadow[raw].value != 0)
		cap.raw = t->shadow[raw].value ^ (fuzz_take(in, 1) == 0 ?
		    UINT64_C(1) << ERX_CAP_SLOT_BITS : 0);
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

	if (erx_cap_read(&t->table, cap, type, required, &view) != ERX_OK)
		return;
	fuzz_check(index < FUZZ_LIMIT);
	s = &t->shadow[index];
	fuzz_check(s->value == cap.raw && view.object == s->object &&
	    view.type == s->type && view.rights.bits == s->rights &&
	    (s->rights & required) == required);
}

static void
fuzz_install(fuzz_input_t *in, fuzz_table_t *t)
{
	erx_create_kind_t kind = (erx_create_kind_t)fuzz_take(in, 1);
	erx_rights_t rights = erx_rights_shrink(erx_rights_create(kind),
	    (uint32_t)fuzz_take(in, 4));
	uint64_t object = fuzz_take(in, 2);
	erx_cap_t cap;
	uint32_t index;

	if (erx_cap_install(&t->table, object, erx_kind_ktype(kind), rights,
	    &cap) != ERX_OK)
		return;
	index = (uint32_t)(cap.raw & 0xffffff);
	fuzz_check(index > 0 && index < FUZZ_LIMIT &&
	    t->shadow[index].value == 0);
	t->shadow[index] = (fuzz_slot_t){ cap.raw, object,
	    erx_kind_ktype(kind), rights.bits };
}

static void
fuzz_clear(fuzz_input_t *in, fuzz_table_t *t)
{
	erx_cap_t cap = fuzz_value(in, t);
	uint32_t index = (uint32_t)(cap.raw & 0xffffff);
	uint64_t object = index < FUZZ_LIMIT ? t->shadow[index].object : 0;

	if (fuzz_take(in, 1) == 0)
		object++;
	if (erx_cap_slot_clear(&t->table, cap, object) != ERX_OK)
		return;
	fuzz_check(index < FUZZ_LIMIT && t->shadow[index].value == cap.raw &&
	    t->shadow[index].object == object);
	t->shadow[index].value = 0;
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
	erx_status_t status;

	for (i = 0; i < n; i++) {
		items[i].cap = fuzz_value(in, from);
		items[i].op = (uint32_t)fuzz_take(in, 1) % 4;
		items[i].mask = (uint32_t)fuzz_take(in, 4);
		items[i].type = (uint32_t)fuzz_take(in, 1) % 11;
		items[i].required = (uint32_t)fuzz_take(in, 1);
		memset(&sources[i], 0, sizeof(sources[i]));
		sources[i].status = erx_cap_read(&from->table, items[i].cap,
		    ERX_CAP_ANY_TYPE, 0, &sources[i].view);
	}
	request = (erx_pass_request_t){ items, n, to->reservation.count,
	    (flags & 1) != 0, (flags & 2) != 0 };
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
		if (!request.to_created)
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
		    plan.steps[0].object) == ERX_OK);
		from->shadow[plan.steps[0].slot].value = 0;
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
	uint32_t t, p;

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
		switch (fuzz_take(&in, 1) % 8) {
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
		default:
			for (i = 0; i < FUZZ_LIMIT; i++)
				if (t->shadow[i].value != 0) {
					cap.raw = t->shadow[i].value;
					fuzz_read(t, cap, ERX_CAP_ANY_TYPE, 0);
				}
			break;
		}
	}
	return (0);
}
