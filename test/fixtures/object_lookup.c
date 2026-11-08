/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The one lookup's object checks (K1, K3, K21): erx_cap_lookup refuses an
 * object a destroy closed and an object whose budget is dead, while
 * erx_cap_read, the pure slot check, still accepts both slots; a closed
 * object takes no new capability. Only the capability core's tests may
 * name the slot clear, so the count-out of a closed object is the object
 * store's own tests' to check. Prints the first check that fails and
 * exits 1, or exits 0.
 */

#include <stdalign.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/object.h"

#define LOOKUP_LIMIT	(2 * ERX_CAP_PAGE_SLOTS)

static alignas(64) unsigned char table_storage[256];
static alignas(64) unsigned char directory[64];
static alignas(64) unsigned char page[ERX_CAP_PAGE_SLOTS * ERX_CAP_SLOT_SIZE];
static alignas(64) unsigned char budgets[2][512];
static int failures;

static void
expect(const char *name, long got, long want)
{
	if (got == want)
		return;
	printf("object_lookup: %s: got %ld, want %ld\n", name, got, want);
	failures++;
}

/* The status of a lookup, and the handle it returned on ERX_OK. */
static erx_status_t
lookup(const erx_cap_table_t *table, erx_cap_t cap, uint64_t *handlep)
{
	erx_uref_t ref;
	erx_status_t status;

	*handlep = 0;
	status = erx_cap_lookup(table, NULL, cap, ERX_CAP_ANY_TYPE, 0, &ref);
	if (status == ERX_OK)
		*handlep = erx_object_handle(erx_uref_get(ref));
	return (status);
}

int
main(void)
{
	erx_oid_key_t key = { { 9, 8, 7, 6 } };
	erx_cap_table_t *table = (erx_cap_table_t *)table_storage;
	erx_budget_t *root = (erx_budget_t *)budgets[0];
	erx_budget_t *child = (erx_budget_t *)budgets[1];
	erx_object_t *records[2];
	erx_budget_effects_t effects;
	erx_object_store_t *store;
	erx_cap_view_t view;
	erx_cap_t paid, closed, copy;
	uint64_t handle;

	if (erx_budget_record_size() > sizeof(budgets[0]) ||
	    erx_cap_table_size() > sizeof(table_storage) ||
	    erx_cap_directory_size(LOOKUP_LIMIT) > sizeof(directory))
		return (2);
	store = calloc(1, erx_object_store_size());
	records[0] = aligned_alloc(erx_object_record_align(),
	    erx_object_record_size());
	records[1] = aligned_alloc(erx_object_record_align(),
	    erx_object_record_size());
	if (store == NULL || records[0] == NULL || records[1] == NULL)
		return (2);
	erx_object_store_init(store, &key);
	erx_object_test_store(records, 2);
	if (erx_budget_init_root(root, 1024) != 0 ||
	    erx_budget_carve(root, child, ERX_BUDGET_WALL, 16, 16,
	    &effects) != 0 ||
	    erx_object_init(store, records[0], ERX_K_GATE, child) != ERX_OK ||
	    erx_object_init(store, records[1], ERX_K_GATE, root) != ERX_OK ||
	    erx_cap_table_init(table, directory, sizeof(directory),
	    LOOKUP_LIMIT) != ERX_OK ||
	    erx_cap_table_add_page(table, page, sizeof(page)) != ERX_OK ||
	    erx_cap_install_kind(table, records[0], ERX_KIND_NEW_GATE,
	    UINT32_MAX, &paid) != ERX_OK ||
	    erx_cap_install_kind(table, records[1], ERX_KIND_NEW_GATE,
	    UINT32_MAX, &closed) != ERX_OK)
		return (2);

	expect("lookup of a live object", lookup(table, paid, &handle), ERX_OK);
	expect("its handle", (long)handle, 1);
	expect("lookup of another", lookup(table, closed, &handle), ERX_OK);

	/* The budget's destroy closes it: what it pays for is unreachable. */
	expect("budget close", erx_budget_close(child, &effects), 0);
	expect("lookup under a dead budget", lookup(table, paid, &handle),
	    ERX_ESTALE);
	expect("its slot still reads", erx_cap_read(table, NULL, paid,
	    ERX_CAP_ANY_TYPE, 0, &view), ERX_OK);
	expect("a live budget's object", lookup(table, closed, &handle),
	    ERX_OK);

	/* A destroy closes the object: unreachable, and takes no capability. */
	expect("close", erx_object_close(records[1]), true);
	expect("lookup of a closed object", lookup(table, closed, &handle),
	    ERX_ESTALE);
	expect("its slot still reads", erx_cap_read(table, NULL, closed,
	    ERX_CAP_ANY_TYPE, 0, &view), ERX_OK);
	expect("install on a closed object", erx_cap_install_kind(table,
	    records[1], ERX_KIND_NEW_GATE, UINT32_MAX, &copy), ERX_ESTALE);
	expect("copy of a closed object", erx_cap_install_copy(table, table,
	    closed, records[1], UINT32_MAX, &copy), ERX_ESTALE);
	expect("count after the refusals", erx_object_ncaps(records[1]), 1);
	return (failures == 0 ? 0 : 1);
}
