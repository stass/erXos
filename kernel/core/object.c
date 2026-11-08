/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The object store (docs/design-kernel.md, "Objects and capabilities"):
 * an object's header, the state word that only advances, its counts, the
 * object ids and the borrowed references of lookups. Each function is one
 * decision over one header; the locks its caller holds are named in
 * include/erx/object.h, and the store takes none.
 *
 * The state word and the reference count are atomic because they are read
 * without a lock: a lookup reads the state, and references are taken and
 * dropped by threads holding no lock of the object. The slot count and the
 * slot list's head are read and written only under the object's
 * capability lock.
 */

#include "object_impl.h"

/*
 * Debug and host builds check every borrowed reference's epoch against the
 * thread's count of preemption points.
 */
#if defined(ERX_HOST) || defined(ERX_KERNEL_DEBUG)
#define OBJECT_CHECK_EPOCHS	1
#else
#define OBJECT_CHECK_EPOCHS	0
#endif

_Static_assert(sizeof(erx_object_t) <= ERX_OBJECT_HEADER_BYTES &&
    ERX_OBJECT_HEADER_BYTES % 64 == 0,
    "the header fits its fixed area, which keeps a body 64-byte aligned");

_Static_assert(ERX_OBJ_LIVE < ERX_OBJ_RELEASED &&
    ERX_OBJ_RELEASED < ERX_OBJ_DELETED,
    "the states are numbered in the order of an object's life");

/*
 * An encoding the ABI reserves, which no object id takes: zero, which the
 * records that carry an object id read as "none".
 */
static bool
oid_reserved(uint64_t oid)
{
	return (oid == 0);
}

/*
 * The Feistel network's round function: half of the block mixed with the
 * round's key by murmur3's 64-bit finalizer, a bijection with full
 * avalanche. A Feistel network is a permutation whatever its round
 * function, so ids never collide; the function only hides the counter.
 */
static uint32_t
oid_round(uint32_t half, uint64_t key)
{
	uint64_t x;

	x = (((uint64_t)half << 32) | half) ^ key;
	x ^= x >> 33;
	x *= UINT64_C(0xff51afd7ed558ccd);
	x ^= x >> 33;
	x *= UINT64_C(0xc4ceb9fe1a85ec53);
	x ^= x >> 33;
	return ((uint32_t)x);
}

/* The object id of creation counter value counter under key. */
static uint64_t
oid_permute(const erx_oid_key_t *key, uint64_t counter)
{
	uint32_t left, right, next;
	int round;

	left = (uint32_t)(counter >> 32);
	right = (uint32_t)counter;
	for (round = 0; round < ERX_OID_ROUNDS; round++) {
		next = left ^ oid_round(right, key->round[round]);
		left = right;
		right = next;
	}
	return (((uint64_t)left << 32) | right);
}

/*
 * Takes the creation counter's next value, which no other creation gets,
 * or fails once the counter is spent.
 */
static erx_status_t
oid_take_counter(erx_object_store_t *store, uint64_t *counterp)
{
	uint64_t counter;

	counter = atomic_load_explicit(&store->next, memory_order_relaxed);
	do {
		if (counter == ERX_OID_COUNTER_END)
			return (ERX_ELIMIT);
	} while (!atomic_compare_exchange_weak_explicit(&store->next,
	    &counter, counter + 1, memory_order_relaxed,
	    memory_order_relaxed));
	*counterp = counter;
	return (ERX_OK);
}

/*
 * The next object id: the image of the next counter value, skipping the
 * values whose image is reserved, which are spent and never reused.
 */
static erx_status_t
oid_next(erx_object_store_t *store, uint64_t *oidp)
{
	uint64_t counter, oid;
	erx_status_t status;

	do {
		status = oid_take_counter(store, &counter);
		if (status != ERX_OK)
			return (status);
		oid = oid_permute(&store->key, counter);
	} while (oid_reserved(oid));
	*oidp = oid;
	return (ERX_OK);
}

size_t
erx_object_record_size(void)
{
	return (sizeof(erx_object_t));
}

size_t
erx_object_record_align(void)
{
	return (_Alignof(erx_object_t));
}

size_t
erx_object_store_size(void)
{
	return (sizeof(erx_object_store_t));
}

void
erx_object_store_init(erx_object_store_t *store, const erx_oid_key_t *key)
{
	store->key = *key;
	atomic_init(&store->next, 0);
}

erx_status_t
erx_object_init(erx_object_store_t *store, erx_object_t *object,
    erx_ktype_t type, struct erx_budget *budget)
{
	uint64_t oid;
	erx_status_t status;

	status = oid_next(store, &oid);
	if (status != ERX_OK)
		return (status);
	object->type = type;
	atomic_init(&object->state, ERX_OBJ_LIVE);
	atomic_init(&object->refs, 1);
	object->ncaps = 0;
	object->att_slots = NULL;
	object->budget = budget;
	object->in_budget.prev = NULL;
	object->in_budget.next = NULL;
	object->oid = oid;
	__builtin_memset(object->name, 0, sizeof(object->name));
	return (ERX_OK);
}

erx_obj_state_t
erx_object_state(const erx_object_t *object)
{
	return ((erx_obj_state_t)atomic_load_explicit(&object->state,
	    memory_order_acquire));
}

erx_ktype_t
erx_object_type(const erx_object_t *object)
{
	return (object->type);
}

uint64_t
erx_object_oid(const erx_object_t *object)
{
	return (object->oid);
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
	if (erx_object_state(object) != ERX_OBJ_LIVE)
		return (ERX_ESTALE);
	if (object->ncaps == UINT32_MAX)
		return (ERX_ELIMIT);
	object->ncaps++;
	return (ERX_OK);
}

bool
erx_object_cap_remove(erx_object_t *object)
{
	uint32_t live;

	if (object->ncaps == 0)
		__builtin_trap();
	object->ncaps--;
	if (object->ncaps != 0)
		return (false);
	/*
	 * A failed exchange leaves DELETED: a destroy closed the object
	 * first, and it stays closed.
	 */
	live = ERX_OBJ_LIVE;
	(void)atomic_compare_exchange_strong_explicit(&object->state, &live,
	    ERX_OBJ_RELEASED, memory_order_release, memory_order_relaxed);
	return (true);
}

bool
erx_object_close(erx_object_t *object)
{
	uint32_t before;

	before = atomic_exchange_explicit(&object->state, ERX_OBJ_DELETED,
	    memory_order_acq_rel);
	return (before != ERX_OBJ_DELETED);
}

erx_cap_slot_t *
erx_object_slots(const erx_object_t *object)
{
	return (object->att_slots);
}

void
erx_object_set_slots(erx_object_t *object, erx_cap_slot_t *head)
{
	object->att_slots = head;
}

void
erx_object_charged_append(erx_charged_list_t *list, erx_object_t *object)
{
	object->in_budget.prev = list->tail;
	object->in_budget.next = NULL;
	if (list->tail != NULL)
		list->tail->in_budget.next = object;
	else
		list->head = object;
	list->tail = object;
}

/*
 * An object is on its budget's list exactly when it heads it or has a
 * predecessor: the unlink clears both links, so a second unlink finds
 * neither and changes nothing.
 */
bool
erx_object_charged_unlink(erx_charged_list_t *list, erx_object_t *object)
{
	if (list->head != object && object->in_budget.prev == NULL)
		return (false);
	if (object->in_budget.prev != NULL)
		object->in_budget.prev->in_budget.next = object->in_budget.next;
	else
		list->head = object->in_budget.next;
	if (object->in_budget.next != NULL)
		object->in_budget.next->in_budget.prev = object->in_budget.prev;
	else
		list->tail = object->in_budget.prev;
	object->in_budget.prev = NULL;
	object->in_budget.next = NULL;
	return (true);
}

erx_object_t *
erx_object_charged_head(const erx_charged_list_t *list)
{
	return (list->head);
}

erx_uref_t
erx_uref_make(erx_object_t *object)
{
	erx_uref_t ref = {
		.object = object,
		.epoch = erx_effect_thread_epoch(),
	};

	return (ref);
}

erx_object_t *
erx_uref_get(erx_uref_t ref)
{
	if (OBJECT_CHECK_EPOCHS && ref.epoch != erx_effect_thread_epoch())
		__builtin_trap();
	return (ref.object);
}

erx_object_t *
erx_object_ref(erx_uref_t ref)
{
	erx_object_t *object;
	uint32_t before;

	object = erx_uref_get(ref);
	before = atomic_fetch_add_explicit(&object->refs, 1,
	    memory_order_relaxed);
	if (before == 0 || before == UINT32_MAX)
		__builtin_trap();
	return (object);
}

bool
erx_object_put(erx_object_t *object)
{
	uint32_t before;

	before = atomic_fetch_sub_explicit(&object->refs, 1,
	    memory_order_release);
	if (before == 0)
		__builtin_trap();
	if (before != 1)
		return (false);
	/* Every earlier holder's writes happen before the record's free. */
	atomic_thread_fence(memory_order_acquire);
	return (true);
}

#ifdef ERX_HOST

static erx_object_t *const *test_records;
static uint64_t test_nrecords;

void
erx_object_test_store(erx_object_t *const *records, uint64_t nrecords)
{
	test_records = records;
	test_nrecords = nrecords;
}

uint64_t
erx_object_handle(const erx_object_t *object)
{
	uint64_t i;

	for (i = 0; i < test_nrecords; i++)
		if (test_records[i] == object)
			return (i + 1);
	return (0);
}

erx_object_t *
erx_object_from_handle(uint64_t handle)
{
	if (handle == 0 || handle > test_nrecords)
		return (NULL);
	return (test_records[handle - 1]);
}

#else

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

#endif /* ERX_HOST */
