/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the object store with the values it takes from outside a header:
 * an id key and creation counter, operations on FUZZ_RECORDS headers in
 * any order their contracts allow, and handles of any value, decoded from
 * the input, and aborts when an invariant breaks:
 *
 *   a header's state only advances, and each result is the one a shadow
 *   header predicts: no slot is counted on an object that is not live, a
 *   release is reported once when the last slot goes, and only the first
 *   close goes on;
 *   every id issued is nonzero and distinct from every other, the counter
 *   only rises, and creation fails, writing nothing, only once the counter
 *   is spent;
 *   a handle names a record of the test store or nothing.
 *
 * The input starts with the key's four rounds and the first counter value,
 * eight bytes each; then each operation is one byte, its low three bits the
 * operation and the next two the record, followed by its operands.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "object_impl.h"

#define FUZZ_RECORDS	4
#define FUZZ_IDS	512

typedef struct fuzz_shadow {
	bool		 exists;
	uint32_t	 state;
	uint32_t	 ncaps;
	uint32_t	 refs;
} fuzz_shadow_t;

typedef struct fuzz_input {
	const uint8_t	*bytes;
	size_t		 size;
} fuzz_input_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static erx_object_store_t store;
static erx_object_t objects[FUZZ_RECORDS];
static erx_object_t *records[FUZZ_RECORDS];
static fuzz_shadow_t shadow[FUZZ_RECORDS];
static uint64_t ids[FUZZ_IDS];
static size_t nids;

uint32_t
erx_effect_thread_epoch(void)
{
	return (7);
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

/* The header agrees with its shadow, which never moved back. */
static void
fuzz_compare(int r)
{
	erx_object_t *object = &objects[r];

	fuzz_check(erx_object_state(object) == shadow[r].state);
	fuzz_check(erx_object_ncaps(object) == shadow[r].ncaps);
	fuzz_check(atomic_load(&object->refs) == shadow[r].refs);
}

static void
fuzz_new(int r)
{
	uint64_t before, after, oid;
	erx_status_t status;
	size_t i;

	before = atomic_load(&store.next);
	status = erx_object_init(&store, &objects[r], ERX_K_MEMORY, NULL);
	after = atomic_load(&store.next);
	if (status != ERX_OK) {
		fuzz_check(status == ERX_ELIMIT);
		fuzz_check(before == ERX_OID_COUNTER_END);
		fuzz_check(after == before);
		if (shadow[r].exists)
			fuzz_compare(r);
		return;
	}
	fuzz_check(after > before);
	oid = erx_object_oid(&objects[r]);
	fuzz_check(oid != 0);
	for (i = 0; i < nids; i++)
		fuzz_check(ids[i] != oid);
	if (nids < FUZZ_IDS)
		ids[nids++] = oid;
	shadow[r] = (fuzz_shadow_t){ true, ERX_OBJ_LIVE, 0, 1 };
	fuzz_compare(r);
}

static void
fuzz_operate(int op, int r)
{
	erx_object_t *object = &objects[r];
	fuzz_shadow_t *s = &shadow[r];
	uint32_t before = s->state;

	/* A record not made, or whose last reference went, is not touched. */
	if (!s->exists || s->refs == 0)
		return;
	switch (op) {
	case 1:
		if (s->state == ERX_OBJ_LIVE) {
			fuzz_check(erx_object_cap_add(object) == ERX_OK);
			s->ncaps++;
		} else {
			fuzz_check(erx_object_cap_add(object) == ERX_ESTALE);
		}
		break;
	case 2:
		if (s->ncaps == 0)
			return;
		s->ncaps--;
		fuzz_check(erx_object_cap_remove(object) == (s->ncaps == 0));
		if (s->ncaps == 0 && s->state == ERX_OBJ_LIVE)
			s->state = ERX_OBJ_RELEASED;
		break;
	case 3:
		fuzz_check(erx_object_close(object) ==
		    (s->state != ERX_OBJ_DELETED));
		s->state = ERX_OBJ_DELETED;
		break;
	case 4:
		if (s->refs == UINT32_MAX)
			return;
		fuzz_check(erx_object_ref(erx_uref_make(object)) == object);
		s->refs++;
		break;
	default:
		s->refs--;
		fuzz_check(erx_object_put(object) == (s->refs == 0));
		break;
	}
	fuzz_check(s->state >= before);
	fuzz_compare(r);
}

static void
fuzz_handle(uint64_t handle)
{
	erx_object_t *object = erx_object_from_handle(handle);

	if (handle == 0 || handle > FUZZ_RECORDS) {
		fuzz_check(object == NULL);
		return;
	}
	fuzz_check(object == &objects[handle - 1]);
	fuzz_check(erx_object_handle(object) == handle);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t in = { data, size };
	erx_oid_key_t key;
	int i, op, r;

	for (i = 0; i < ERX_OID_ROUNDS; i++)
		key.round[i] = fuzz_take(&in, 8);
	erx_object_store_init(&store, &key);
	atomic_store(&store.next, fuzz_take(&in, 8));
	for (i = 0; i < FUZZ_RECORDS; i++) {
		records[i] = &objects[i];
		shadow[i] = (fuzz_shadow_t){ 0 };
	}
	erx_object_test_store(records, FUZZ_RECORDS);
	nids = 0;
	while (in.size > 0) {
		op = (int)fuzz_take(&in, 1);
		r = (op >> 3) & (FUZZ_RECORDS - 1);
		switch (op & 7) {
		case 0:
			fuzz_new(r);
			break;
		case 6:
			atomic_store(&store.next, fuzz_take(&in, 8));
			nids = 0;
			break;
		case 7:
			fuzz_handle(fuzz_take(&in, 8));
			break;
		default:
			fuzz_operate(op & 7, r);
			break;
		}
	}
	return (0);
}
