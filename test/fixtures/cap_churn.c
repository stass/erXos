/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * One writer installs and clears capabilities in a table of one page
 * while readers look up values it published, fresh and stale, without a
 * lock. Each install's object and rights are functions of its slot and
 * generation, so a reader that accepts a copy can tell whether the copy is
 * one state of the slot. Built with ThreadSanitizer, which also fails the
 * run on any plain access that races. Exits 0 when every accepted copy was
 * consistent and readers saw both fresh and stale values.
 */

#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/cap.h"
#include "cap_impl.h"
#include "cap_slot_impl.h"

#define CHURN_WRITES	100000
#define CHURN_LIVE	32
#define CHURN_READERS	3

static erx_cap_table_t		 table;
static _Atomic(erx_cap_slot_t *) dir[1];
static erx_cap_slot_t		 page[ERX_CAP_PAGE_SLOTS];
static _Atomic uint64_t		 published[ERX_CAP_PAGE_SLOTS];
static _Atomic bool		 done;
static _Atomic uint64_t		 accepted, refused, wrong;

static uint64_t
churn_object(uint32_t slot, uint64_t generation)
{
	return ((generation << 8 | slot) + 1);
}

static uint32_t
churn_rights(uint64_t generation)
{
	return ((uint32_t)(generation * UINT64_C(2654435761)) &
	    erx_ktype_rights_mask(ERX_K_MEMORY));
}

static void *
churn_write(void *arg)
{
	erx_cap_t live[CHURN_LIVE];
	uint64_t objects[CHURN_LIVE];
	erx_rights_t rights;
	uint32_t slot, n = 0, i;
	uint64_t generation;

	(void)arg;
	for (i = 0; i < CHURN_WRITES; i++) {
		if (n == CHURN_LIVE) {
			if (erx_cap_slot_clear(&table, live[0], objects[0]) !=
			    ERX_OK)
				abort();
			for (n = 1; n < CHURN_LIVE; n++) {
				live[n - 1] = live[n];
				objects[n - 1] = objects[n];
			}
			n = CHURN_LIVE - 1;
		}
		slot = table.free_head;
		{
			erx_cap_slot_t *s = &page[slot];

			(void)erx_cap_slot_generation_load(s, &generation);
		}
		rights.bits = churn_rights(generation);
		objects[n] = churn_object(slot, generation);
		if (erx_cap_install(&table, objects[n], ERX_K_MEMORY, rights,
		    &live[n]) != ERX_OK)
			abort();
		atomic_store(&published[slot], live[n].raw);
		n++;
	}
	atomic_store(&done, true);
	return (NULL);
}

static void *
churn_read(void *arg)
{
	uint64_t state = (uint64_t)(uintptr_t)arg * UINT64_C(6364136223846793005) + 1;
	erx_cap_view_t view;
	erx_cap_t cap;
	uint32_t slot;

	while (!atomic_load(&done)) {
		state = state * UINT64_C(6364136223846793005) +
		    UINT64_C(1442695040888963407);
		slot = 1 + (uint32_t)(state >> 33) % (ERX_CAP_PAGE_SLOTS - 1);
		cap.raw = atomic_load(&published[slot]);
		if (erx_cap_read(&table, cap, ERX_K_MEMORY, 0, &view) != ERX_OK) {
			atomic_fetch_add(&refused, 1);
			continue;
		}
		if (view.slot != slot ||
		    view.generation != cap.raw >> ERX_CAP_SLOT_BITS ||
		    view.object != churn_object(slot, view.generation) ||
		    view.rights.bits != churn_rights(view.generation) ||
		    view.type != ERX_K_MEMORY)
			atomic_fetch_add(&wrong, 1);
		else
			atomic_fetch_add(&accepted, 1);
	}
	return (NULL);
}

int
main(void)
{
	pthread_t writer, readers[CHURN_READERS];
	uintptr_t i;

	if (erx_cap_table_init(&table, dir, sizeof(dir),
	    ERX_CAP_PAGE_SLOTS) != ERX_OK ||
	    erx_cap_table_add_page(&table, page, sizeof(page)) !=
	    ERX_OK)
		return (1);
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
	    PRIu64 " inconsistent\n", atomic_load(&accepted),
	    atomic_load(&refused), atomic_load(&wrong));
	return (atomic_load(&wrong) == 0 && atomic_load(&accepted) > 0 &&
	    atomic_load(&refused) > 0 ? 0 : 1);
}
