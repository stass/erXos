/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the grace tracker and the page funnel, with the budget core, with
 * every sequence of calls their contracts allow, decoded from the input:
 * CPUs joining and leaving the tracker's online set, retires,
 * reports, and charges, backing steps, takes, releases and free steps on
 * FUZZ_RESERVES reserves of a root of FUZZ_PAGES pages. It aborts when an
 * invariant breaks:
 *   an item is called mature only once every CPU online at its retirement
 *   has reported or left since, and once every online CPU has reported
 *   twice at the end, no period is in progress or requested;
 *   a page joins a pool from a backing's hand only with a mature stamp;
 *   every page is in exactly one place (free, released, a backing's hand,
 *   in use, or a pool, which the pooled counts account for), and the
 *   released list's stamps never decrease;
 *   a release's pages are on the released list before its refund takes
 *   the budget's lock, and the locks are taken in their order;
 *   each reserve's counts are the ones its operations predict, and a
 *   charge is refused exactly when the root cannot cover it.
 * Each operation is one byte, its low three bits the operation and the
 * rest its operands, followed by one operand byte where it needs one.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "page_impl.h"

#define FUZZ_PAGES	160
#define FUZZ_RESERVES	2
#define FUZZ_CPUS	4
#define FUZZ_ITEMS	64

typedef struct fuzz_input {
	const uint8_t	*data;
	size_t		 size;
} fuzz_input_t;

typedef struct fuzz_shadow {
	erx_npages_t	charged;
	erx_npages_t	pooled;
	erx_npages_t	used;
	erx_npages_t	backing;	/* admitted by the backing under way */
	bool		cancelled;	/* the backing under way was closed
					 * before it took anything */
} fuzz_shadow_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static erx_page_t pages[FUZZ_PAGES];
static int used_by[FUZZ_PAGES];
static erx_plist_t free_pages;
static erx_grace_t *tracker;
static erx_released_t released;
static erx_budget_t *root;
static erx_reserve_t *reserves[FUZZ_RESERVES];
static erx_backing_t backings[FUZZ_RESERVES];
static fuzz_shadow_t shadow[FUZZ_RESERVES];
static uint64_t online;
static uint64_t stamps[FUZZ_ITEMS];
static uint64_t owing[FUZZ_ITEMS];
static size_t nitems;
static bool grace_locked, released_locked, reserve_locked;
static erx_npages_t releasing_list;
static bool releasing;

static void *
record(size_t size, size_t align)
{
	void *memory;

	memory = aligned_alloc(align, (size + align - 1) / align * align);
	if (memory == NULL)
		abort();
	memset(memory, 0, size);
	return (memory);
}

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	(void)budget;
	if (releasing && released.list.count != releasing_list)
		abort();
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	(void)budget;
}

void
erx_effect_grace_lock(erx_grace_t *t)
{
	(void)t;
	if (grace_locked)
		abort();
	grace_locked = true;
}

void
erx_effect_grace_unlock(erx_grace_t *t)
{
	(void)t;
	grace_locked = false;
}

void
erx_effect_released_lock(erx_released_t *list)
{
	(void)list;
	if (released_locked || grace_locked)
		abort();
	released_locked = true;
}

void
erx_effect_released_unlock(erx_released_t *list)
{
	(void)list;
	released_locked = false;
}

void
erx_effect_reserve_lock(erx_reserve_t *reserve)
{
	(void)reserve;
	if (reserve_locked || released_locked || grace_locked)
		abort();
	reserve_locked = true;
}

void
erx_effect_reserve_unlock(erx_reserve_t *reserve)
{
	(void)reserve;
	reserve_locked = false;
}

erx_npages_t
erx_effect_page_alloc(erx_npages_t n, erx_plist_t *out)
{
	erx_npages_t taken;

	if (!released_locked)
		abort();
	for (taken = 0; taken < n && free_pages.count > 0; taken++)
		erx_plist_push(out, erx_plist_pop(&free_pages));
	return (taken);
}

void
erx_effect_page_zero(erx_page_t *page)
{
	(void)page;
}

void
erx_effect_page_free(erx_plist_t *list)
{
	erx_page_t *page;

	if (!released_locked)
		abort();
	while ((page = erx_plist_pop(list)) != NULL) {
		if (!erx_grace_mature(tracker, page->stamp))
			abort();
		erx_plist_push(&free_pages, page);
	}
}

static bool
next_byte(fuzz_input_t *in, uint8_t *byte)
{
	if (in->size == 0)
		return (false);
	*byte = *in->data++;
	in->size--;
	return (true);
}

static void
mark(uint8_t *seen, const erx_plist_t *list)
{
	erx_npages_t count = 0;

	for (const erx_page_t *page = list->head; page != NULL;
	    page = page->next, count++) {
		if (seen[page - pages]++ != 0)
			abort();
	}
	if (count != list->count)
		abort();
}

static void
check(void)
{
	uint8_t seen[FUZZ_PAGES] = { 0 };
	erx_reserve_counts_t counts;
	erx_npages_t pooled = 0, unseen = 0;
	uint64_t stamp = 0;

	mark(seen, &free_pages);
	mark(seen, &released.list);
	for (int r = 0; r < FUZZ_RESERVES; r++) {
		mark(seen, &backings[r].hand);
		erx_reserve_read(reserves[r], &counts);
		if (backings[r].unselected == 0 &&
		    backings[r].hand.count == 0 &&
		    (counts.charged != shadow[r].charged ||
		    counts.charged != counts.backed ||
		    counts.pooled != shadow[r].pooled))
			abort();
		pooled += counts.pooled;
	}
	for (int p = 0; p < FUZZ_PAGES; p++) {
		if (used_by[p] >= 0 && seen[p]++ != 0)
			abort();
		unseen += seen[p] == 0;
	}
	if (unseen != pooled)
		abort();
	for (const erx_page_t *page = released.list.head; page != NULL;
	    page = page->next) {
		if (page->stamp < stamp)
			abort();
		stamp = page->stamp;
	}
}

static void
report(uint32_t cpu)
{
	if ((online & (UINT64_C(1) << cpu)) == 0)
		return;
	(void)erx_grace_report(tracker, cpu);
	for (size_t i = 0; i < nitems; i++)
		owing[i] &= ~(UINT64_C(1) << cpu);
}

/* Joins and leaves CPUs until the set the byte names is online. */
static void
set_online(uint8_t byte)
{
	uint64_t next = byte % ((1u << FUZZ_CPUS) - 1) + 1;

	for (uint32_t cpu = 0; cpu < FUZZ_CPUS; cpu++) {
		uint64_t bit = UINT64_C(1) << cpu;

		if ((next & bit) != 0 && (online & bit) == 0)
			erx_grace_cpu_join(tracker, cpu);
		if ((next & bit) != 0 || (online & bit) == 0)
			continue;
		(void)erx_grace_cpu_leave(tracker, cpu);
		for (size_t i = 0; i < nitems; i++)
			owing[i] &= ~bit;
	}
	online = next;
}

static void
retire(void)
{
	if (nitems == FUZZ_ITEMS)
		return;
	stamps[nitems] = erx_grace_retire(tracker);
	owing[nitems++] = online;
}

/* No item is mature while a CPU online at its retirement owes a report. */
static void
check_maturity(void)
{
	for (size_t i = 0; i < nitems; i++)
		if (erx_grace_mature(tracker, stamps[i]) && owing[i] != 0)
			abort();
}

static erx_npages_t
root_charged(void)
{
	erx_npages_t sum = 0;

	for (int r = 0; r < FUZZ_RESERVES; r++)
		sum += shadow[r].charged + shadow[r].backing;
	return (sum);
}

static void
charge(int r, erx_npages_t n)
{
	erx_budget_effects_t effects;
	bool fits;
	int error;

	if (shadow[r].backing != 0)
		return;
	fits = root_charged() + n <= FUZZ_PAGES;
	error = erx_reserve_charge(&backings[r], reserves[r], n, &effects);
	if ((error == 0) != fits || (error != 0 && error != ERX_ENOMEM))
		abort();
	if (error == 0)
		shadow[r].backing = n;
}

static void
step(int r, bool closed)
{
	erx_budget_effects_t effects;
	erx_backing_next_t next;
	const erx_page_t *hand[ERX_PAGE_PART];
	size_t n = 0;

	if (shadow[r].backing == 0)
		return;
	for (const erx_page_t *page = backings[r].hand.head; page != NULL;
	    page = page->next)
		hand[n++] = page;
	next = erx_backing_step(&released, &backings[r], closed, &effects);
	for (size_t i = 0; backings[r].hand.count == 0 && i < n; i++)
		if (!erx_grace_mature(tracker, hand[i]->stamp))
			abort();
	if (next == ERX_BACKING_CANCELLED) {
		/* What it took is pooled; the rest went back. */
		erx_reserve_counts_t counts;

		erx_reserve_read(reserves[r], &counts);
		shadow[r].charged = counts.charged;
		shadow[r].pooled = counts.pooled;
		shadow[r].backing = 0;
	} else if (next == ERX_BACKING_DONE) {
		shadow[r].charged += shadow[r].backing;
		shadow[r].pooled += shadow[r].backing;
		shadow[r].backing = 0;
	} else if (next == ERX_BACKING_WAIT && backings[r].hand.count == 0) {
		abort();
	}
}

static void
take(int r)
{
	erx_page_t *page;

	if (shadow[r].pooled == 0 || shadow[r].backing != 0)
		return;
	erx_effect_reserve_lock(reserves[r]);
	page = erx_reserve_take(reserves[r]);
	erx_effect_reserve_unlock(reserves[r]);
	if (used_by[page - pages] >= 0)
		abort();
	used_by[page - pages] = r;
	shadow[r].pooled--;
	shadow[r].used++;
}

static void
release(int r, uint8_t byte)
{
	erx_budget_effects_t effects;
	erx_plist_t in_use = { 0 };
	int ids[FUZZ_PAGES];
	erx_npages_t pooled, used, n = 0;

	if (shadow[r].backing != 0)
		return;
	pooled = (byte & 0x0f) % (shadow[r].pooled + 1);
	used = (byte >> 4) % (shadow[r].used + 1);
	for (int p = 0; p < FUZZ_PAGES && n < used; p++)
		if (used_by[p] == r) {
			ids[n++] = p;
			erx_plist_push(&in_use, &pages[p]);
		}
	releasing_list = released.list.count + used + pooled;
	releasing = true;
	if (erx_page_release(&released, reserves[r], &in_use, pooled,
	    &effects) != 0)
		abort();
	releasing = false;
	for (erx_npages_t i = 0; i < n; i++)
		used_by[ids[i]] = -1;
	shadow[r].pooled -= pooled;
	shadow[r].used -= used;
	shadow[r].charged -= pooled + used;
}

static void
reap(erx_npages_t n)
{
	(void)erx_released_free(&released, n);
}

static void
reset(void)
{
	if (tracker == NULL) {
		tracker = record(erx_grace_record_size(),
		    erx_grace_record_align());
		root = record(erx_budget_record_size(),
		    erx_budget_record_align());
		for (int r = 0; r < FUZZ_RESERVES; r++)
			reserves[r] = record(erx_reserve_record_size(),
			    erx_reserve_record_align());
	}
	erx_grace_init(tracker);
	erx_released_init(&released, tracker);
	if (erx_budget_init_root(root, FUZZ_PAGES) != 0)
		abort();
	free_pages = (erx_plist_t){ 0 };
	for (int p = 0; p < FUZZ_PAGES; p++) {
		used_by[p] = -1;
		/* A fresh tracker: no stamp of an earlier run survives. */
		pages[p].stamp = 0;
		erx_plist_push(&free_pages, &pages[p]);
	}
	for (int r = 0; r < FUZZ_RESERVES; r++) {
		erx_reserve_init(reserves[r], root);
		backings[r] = (erx_backing_t){ 0 };
		shadow[r] = (fuzz_shadow_t){ 0 };
	}
	erx_grace_cpu_join(tracker, 0);
	erx_grace_cpu_join(tracker, 1);
	online = 0x3;
	nitems = 0;
}

/*
 * Once every online CPU has reported twice, the period in progress and a
 * requested one have both completed: nothing waits for a CPU that will not
 * report.
 */
static void
check_liveness(void)
{
	erx_grace_counts_t counts;

	for (int round = 0; round < 2; round++)
		for (uint32_t cpu = 0; cpu < FUZZ_CPUS; cpu++)
			report(cpu);
	erx_grace_read(tracker, &counts);
	if (counts.current != counts.completed || counts.pending)
		abort();
	check_maturity();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t in = { data, size };
	uint8_t op, arg;
	int r;

	reset();
	while (next_byte(&in, &op)) {
		r = (op >> 3) & 1;
		switch (op & 7) {
		case 0:
			if (next_byte(&in, &arg))
				set_online(arg);
			break;
		case 1:
			retire();
			break;
		case 2:
			report((op >> 3) % FUZZ_CPUS);
			break;
		case 3:
			if (next_byte(&in, &arg))
				charge(r, arg % (FUZZ_PAGES + 8));
			break;
		case 4:
			step(r, (op & 0x10) != 0);
			break;
		case 5:
			take(r);
			break;
		case 6:
			if (next_byte(&in, &arg))
				release(r, arg);
			break;
		default:
			reap((op >> 3) + 1);
			break;
		}
		check_maturity();
		check();
	}
	check_liveness();
	return (0);
}
