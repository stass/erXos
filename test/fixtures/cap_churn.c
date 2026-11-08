/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * One writer churns a table while readers look up values it published,
 * fresh and stale, without a lock. The writer installs and clears
 * capabilities, fills reserved slots by passes from a second table, adds
 * pages while the readers run, and drives the first page's slots, seeded
 * near the end of their generations and counts, to retirement. Each slot's
 * object and rights are functions of its index and generation, whichever
 * way it was filled, so a reader that accepts a copy, from erx_cap_read or
 * from erx_cap_lookup, can tell whether the copy is one state of the slot.
 * Built with ThreadSanitizer, which also fails the run on any plain access
 * that races. Exits 0 when every accepted copy was consistent, readers saw
 * fresh and stale values, the table grew to its limit and every seeded
 * slot retired.
 */

#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/cap.h"
#include "erx/object.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define CHURN_WRITES	100000
#define CHURN_LIVE	32
#define CHURN_READERS	3
#define CHURN_PAGES	4
#define CHURN_LIMIT	(CHURN_PAGES * ERX_CAP_PAGE_SLOTS)
#define CHURN_OBJECTS	16
/* Writes between pages added, so readers see the table grow. */
#define CHURN_GROW_EVERY (CHURN_WRITES / CHURN_PAGES)
/* Every so many writes is a reserve and a fill instead of an install. */
#define CHURN_FILL_EVERY 4
/* The first page's seeded slots, and the lives left to each. */
#define CHURN_SEEDED	8
#define CHURN_SEED_LIVES 40
/* The first generation never issued, as the core defines it. */
#define CHURN_GENERATION_LIMIT ((UINT64_C(1) << ERX_CAP_GENERATION_BITS) - 1)
#define CHURN_INDEX(cap) ((uint32_t)((cap).raw & \
	((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1)))

typedef struct churn_table {
	erx_cap_table_t	 table;
	_Atomic(erx_cap_slot_t *) dir[CHURN_PAGES];
	erx_cap_slot_t	 pages[CHURN_PAGES][ERX_CAP_PAGE_SLOTS];
	uint32_t	 npages;
} churn_table_t;

/* The table the readers read, and the source of the writer's passes. */
static churn_table_t		 shared, source;
static erx_cap_t		 sources[CHURN_OBJECTS];
static erx_object_store_t	*store;
static erx_object_t		*objects[CHURN_OBJECTS];
static _Atomic uint64_t		 published[CHURN_LIMIT];
static _Atomic bool		 done;
static _Atomic uint64_t		 accepted, refused, wrong;

/* The handle of the object a slot holds at a generation. */
static uint64_t
churn_object(uint32_t slot, uint64_t generation)
{
	return ((generation * 31 + slot) % CHURN_OBJECTS + 1);
}

/*
 * Its rights: within both the shared memory kind's row and the memory
 * type's pass set, so an install and a pass give a slot the same rights.
 */
static uint32_t
churn_rights(uint64_t generation)
{
	return ((uint32_t)(generation * UINT64_C(2654435761)) &
	    erx_kind_default_mask(ERX_KIND_SHARED_MEMORY) &
	    erx_ktype_pass_mask(ERX_K_MEMORY));
}

static void
churn_grow(churn_table_t *t)
{
	if (t->npages == CHURN_PAGES ||
	    erx_cap_table_add_page(&t->table, t->pages[t->npages],
	    sizeof(t->pages[t->npages])) != ERX_OK)
		abort();
	t->npages++;
}

static uint64_t
churn_generation(uint32_t slot)
{
	uint64_t generation = 0;

	(void)erx_cap_slot_generation_load(
	    &shared.pages[slot / ERX_CAP_PAGE_SLOTS][slot % ERX_CAP_PAGE_SLOTS],
	    &generation);
	return (generation);
}

/* Fill the oldest free slot of the shared table by a pass from source. */
static erx_cap_t
churn_fill(void)
{
	erx_cap_reservation_t reservation = { 0 };
	erx_pass_result_t results[ERX_MSG_CAPS];
	erx_pass_source_t from;
	erx_pass_request_t request;
	erx_pass_item_t item;
	erx_pass_plan_t plan;
	uint64_t generation;
	uint32_t slot;

	if (erx_cap_reserve(&shared.table, 1, &reservation) != ERX_OK)
		abort();
	slot = reservation.slots[0];
	generation = churn_generation(slot);
	item = (erx_pass_item_t){
		.cap = sources[churn_object(slot, generation) - 1],
		.op = ERX_PASS_COPY,
		.mask = churn_rights(generation),
	};
	from.status = erx_cap_read(&source.table, NULL, item.cap,
	    ERX_CAP_ANY_TYPE, 0, &from.view);
	request = (erx_pass_request_t){
		.items = &item,
		.count = 1,
		.room = 1,
		.route = ERX_PASS_RENDEZVOUS,
		.from = &source.table,
		.to = &shared.table,
	};
	if (erx_pass_plan(&request, &from, &plan) != ERX_OK ||
	    erx_pass_take(&plan, &source.table, &reservation) != ERX_OK ||
	    erx_pass_install(&plan, &shared.table, &reservation, results) !=
	    ERX_OK)
		abort();
	return (results[0].cap);
}

static erx_cap_t
churn_install(void)
{
	uint32_t slot = shared.table.free_head;
	uint64_t generation = churn_generation(slot);
	erx_cap_t cap;

	if (erx_cap_install_kind(&shared.table,
	    objects[churn_object(slot, generation) - 1],
	    ERX_KIND_SHARED_MEMORY, churn_rights(generation), &cap) != ERX_OK)
		abort();
	return (cap);
}

/* Every object keeps its capability in source, so no clear releases it. */
static void
churn_clear(erx_cap_t cap)
{
	bool released;

	if (erx_cap_slot_clear(&shared.table, cap,
	    objects[churn_object(CHURN_INDEX(cap),
	    cap.raw >> ERX_CAP_SLOT_BITS) - 1], &released) != ERX_OK ||
	    released)
		abort();
}

static void *
churn_write(void *arg)
{
	erx_cap_t live[CHURN_LIVE];
	uint32_t n = 0, i, k;

	(void)arg;
	for (i = 0; i < CHURN_WRITES; i++) {
		if (i % CHURN_GROW_EVERY == CHURN_GROW_EVERY - 1 &&
		    shared.npages < CHURN_PAGES)
			churn_grow(&shared);
		if (n == CHURN_LIVE) {
			churn_clear(live[0]);
			for (k = 1; k < CHURN_LIVE; k++)
				live[k - 1] = live[k];
			n--;
		}
		live[n] = i % CHURN_FILL_EVERY == 0 ? churn_fill() :
		    churn_install();
		atomic_store(&published[CHURN_INDEX(live[n])], live[n].raw);
		n++;
	}
	atomic_store(&done, true);
	return (NULL);
}

static bool
churn_consistent(uint32_t slot, erx_cap_t cap, const erx_cap_view_t *view)
{
	return (view->slot == slot &&
	    view->generation == cap.raw >> ERX_CAP_SLOT_BITS &&
	    view->object == churn_object(slot, view->generation) &&
	    view->rights.bits == churn_rights(view->generation) &&
	    view->type == ERX_K_MEMORY);
}

/* Half the reads are the slot check alone, half the whole lookup. */
static void *
churn_read(void *arg)
{
	uint64_t state = (uint64_t)(uintptr_t)arg * UINT64_C(6364136223846793005) + 1;
	erx_cap_view_t view;
	erx_status_t status;
	erx_uref_t ref;
	erx_cap_t cap;
	uint32_t slot;
	bool consistent;

	while (!atomic_load(&done)) {
		state = state * UINT64_C(6364136223846793005) +
		    UINT64_C(1442695040888963407);
		slot = 1 + (uint32_t)(state >> 33) % (CHURN_LIMIT - 1);
		cap.raw = atomic_load(&published[slot]);
		if ((state & 1) == 0) {
			status = erx_cap_read(&shared.table, NULL, cap,
			    ERX_K_MEMORY, 0, &view);
			consistent = status != ERX_OK ||
			    churn_consistent(slot, cap, &view);
		} else {
			status = erx_cap_lookup(&shared.table, NULL, cap,
			    ERX_K_MEMORY, 0, &ref);
			consistent = status != ERX_OK ||
			    erx_object_handle(erx_uref_get(ref)) ==
			    churn_object(slot, cap.raw >> ERX_CAP_SLOT_BITS);
		}
		if (status != ERX_OK)
			atomic_fetch_add(&refused, 1);
		else if (!consistent)
			atomic_fetch_add(&wrong, 1);
		else
			atomic_fetch_add(&accepted, 1);
	}
	return (NULL);
}

/*
 * The first page's slots 1 to CHURN_SEEDED, a few lives from the end of
 * their generations (odd slots) or their counts (even slots), before any
 * reader runs. A life costs at most three writes of two counts each.
 */
static void
churn_seed(void)
{
	erx_cap_slot_t *slot;
	uint32_t i;

	for (i = 1; i <= CHURN_SEEDED; i++) {
		slot = &shared.pages[0][i];
		if (i % 2 == 1)
			(void)erx_cap_slot_generation_store(slot,
			    CHURN_GENERATION_LIMIT - CHURN_SEED_LIVES);
		else
			(void)erx_cap_slot_seq_store(slot,
			    ERX_CAP_SLOT_SEQ_TERMINAL - 1 - 6 * CHURN_SEED_LIVES);
	}
}

static uint32_t
churn_retired(void)
{
	uint32_t i, n = 0, state;

	for (i = 1; i <= CHURN_SEEDED; i++) {
		(void)erx_cap_slot_state_load(&shared.pages[0][i], &state);
		n += state == ERX_CAP_SLOT_STATE_RETIRED;
	}
	return (n);
}

static void
churn_setup(void)
{
	erx_oid_key_t key = { { 5, 6, 7, 8 } };
	uint32_t i;

	store = calloc(1, erx_object_store_size());
	if (store == NULL)
		abort();
	erx_object_store_init(store, &key);
	for (i = 0; i < CHURN_OBJECTS; i++) {
		objects[i] = aligned_alloc(erx_object_record_align(),
		    erx_object_record_size());
		if (objects[i] == NULL || erx_object_init(store, objects[i],
		    ERX_K_MEMORY, NULL) != ERX_OK)
			abort();
	}
	erx_object_test_store(objects, CHURN_OBJECTS);
	if (erx_cap_table_init(&shared.table, shared.dir, sizeof(shared.dir),
	    CHURN_LIMIT) != ERX_OK ||
	    erx_cap_table_init(&source.table, source.dir, sizeof(source.dir),
	    CHURN_LIMIT) != ERX_OK)
		abort();
	churn_grow(&shared);
	churn_grow(&source);
	churn_seed();
	for (i = 0; i < CHURN_OBJECTS; i++)
		if (erx_cap_install_kind(&source.table, objects[i],
		    ERX_KIND_SHARED_MEMORY, UINT32_MAX, &sources[i]) != ERX_OK)
			abort();
}

int
main(void)
{
	pthread_t writer, readers[CHURN_READERS];
	uintptr_t i;

	churn_setup();
	for (i = 0; i < CHURN_READERS; i++)
		if (pthread_create(&readers[i], NULL, churn_read,
		    (void *)(i + 1)) != 0)
			return (1);
	if (pthread_create(&writer, NULL, churn_write, NULL) != 0)
		return (1);
	(void)pthread_join(writer, NULL);
	for (i = 0; i < CHURN_READERS; i++)
		(void)pthread_join(readers[i], NULL);
	printf("cap_churn: %" PRIu64 " accepted, %" PRIu64 " refused, %"
	    PRIu64 " inconsistent, %" PRIu32 " pages, %" PRIu32 " retired\n",
	    atomic_load(&accepted), atomic_load(&refused), atomic_load(&wrong),
	    shared.npages, churn_retired());
	return (atomic_load(&wrong) == 0 && atomic_load(&accepted) > 0 &&
	    atomic_load(&refused) > 0 && shared.npages == CHURN_PAGES &&
	    churn_retired() == CHURN_SEEDED ? 0 : 1);
}
