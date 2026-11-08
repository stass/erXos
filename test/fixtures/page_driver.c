/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the grace tracker (kernel/core/grace.c) and the page
 * funnel (kernel/core/page.c), built with the budget core
 * (kernel/core/budget.c). It plays their host: the CPUs and their reports,
 * the page allocator's free list, the locks, and a root budget with up to
 * RESERVES_MAX reserves on it. It reads one command per line from the file
 * named by its argument and prints one line per command, "= ...", which
 * test/host/page_test.rb judges.
 *
 * After every command it checks the funnel's identity: every page is in
 * exactly one place (free, released, a backing's hand, in use, or a pool,
 * which the reserves' pooled counts must account for exactly), and the
 * released list's stamps never decrease. Inside the budget core's lock
 * effect it checks that every page a release is handing back is on the
 * released list already, and at every backing step that each page that
 * left the hand for the pool had a mature stamp. It checks the locks' order: an owner's lock is
 * never taken under the list's lock, and the list's lock never under the
 * tracker's. A broken check prints "! WHAT" and exits with status 3; a
 * broken contract traps in the cores, and the test expects the signal.
 *
 *   cpus MASK        join and leave CPUs until MASK is online: "= MASK"
 *   join CPU         erx_grace_cpu_join:            "= CPU"
 *   leave CPU        erx_grace_cpu_leave:           "= COMPLETED"
 *   retire           erx_grace_retire:              "= STAMP"
 *   report CPU       erx_grace_report:              "= COMPLETED"
 *   mature STAMP     erx_grace_mature:              "= 0|1"
 *   grace            the tracker:
 *                    "= CURRENT COMPLETED AWAITED ONLINE PENDING"
 *   pages N          N page records, all free, and a root budget of N
 *   reserve R        reserve R starts empty at the root
 *   charge R N       erx_reserve_charge into R's backing: "= STATUS"
 *   step R CLOSED    erx_backing_step of R's backing:     "= NEXT"
 *   take R           erx_reserve_take under R's lock:     "= PAGE"
 *   release R P U    erx_page_release of U of R's pages in use (the lowest
 *                    numbered) and P pooled ones:         "= STATUS"
 *   reap N           erx_released_free of up to N pages:  "= MOVED"
 *   state R          "= CHARGED BACKED POOLED USED HAND"
 *   list             the released list: "= COUNT PAGE:STAMP ..."
 *   free             "= FREE"
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "page_impl.h"

#define PAGES_MAX	512
#define RESERVES_MAX	4

typedef enum place {
	PLACE_UNSEEN = 0,
	PLACE_FREE,
	PLACE_RELEASED,
	PLACE_HAND,
	PLACE_USED
} place_t;

static erx_page_t records[PAGES_MAX];
static long npages;
static erx_plist_t free_pages;
/* The reserve that holds each page in use, or -1. */
static int used_by[PAGES_MAX];
static bool zeroed[PAGES_MAX];

static erx_grace_t *tracker;
static erx_released_t released;
static erx_budget_t *root;
static erx_reserve_t *reserves[RESERVES_MAX];
static erx_backing_t backings[RESERVES_MAX];
static bool reserve_exists[RESERVES_MAX];

static bool grace_locked, released_locked;
static bool reserve_locked[RESERVES_MAX];
/* The pages a release in progress hands back; NULL outside a release. */
static const long *releasing;
static long nreleasing;
/* The released list's length once the release has appended. */
static erx_npages_t releasing_list;

static void
broken(const char *what)
{
	printf("! %s\n", what);
	fflush(stdout);
	exit(3);
}

static long
page_id(const erx_page_t *page)
{
	return (page - records);
}

static void *
record(size_t size, size_t align)
{
	void *memory;

	memory = aligned_alloc(align, (size + align - 1) / align * align);
	if (memory == NULL)
		broken("out of memory");
	memset(memory, 0, size);
	return (memory);
}

static int
reserve_index(const erx_reserve_t *reserve)
{
	for (int i = 0; i < RESERVES_MAX; i++)
		if (reserves[i] == reserve)
			return (i);
	broken("an unknown reserve");
	return (-1);
}

/* The effects. */

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	(void)budget;
	if (releasing != NULL && released.list.count != releasing_list)
		broken("a refund before its pages are on the list");
	for (long i = 0; releasing != NULL && i < nreleasing; i++) {
		const erx_page_t *page;

		for (page = released.list.head; page != NULL;
		    page = page->next)
			if (page_id(page) == releasing[i])
				break;
		if (page == NULL)
			broken("a refund before its pages are on the list");
	}
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
		broken("the tracker's lock taken twice");
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
		broken("the list's lock out of order");
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
	int i;

	i = reserve_index(reserve);
	if (reserve_locked[i] || released_locked || grace_locked)
		broken("an owner's lock out of order");
	reserve_locked[i] = true;
}

void
erx_effect_reserve_unlock(erx_reserve_t *reserve)
{
	reserve_locked[reserve_index(reserve)] = false;
}

erx_npages_t
erx_effect_page_alloc(erx_npages_t n, erx_plist_t *out)
{
	erx_npages_t taken;

	if (!released_locked)
		broken("the allocator taken outside the list's lock");
	for (taken = 0; taken < n && free_pages.count > 0; taken++)
		erx_plist_push(out, erx_plist_pop(&free_pages));
	return (taken);
}

void
erx_effect_page_zero(erx_page_t *page)
{
	zeroed[page_id(page)] = true;
}

void
erx_effect_page_free(erx_plist_t *pages)
{
	erx_page_t *page;

	if (!released_locked)
		broken("the allocator's put outside the list's lock");
	while ((page = erx_plist_pop(pages)) != NULL) {
		if (!erx_grace_mature(tracker, page->stamp))
			broken("an immature page freed");
		erx_plist_push(&free_pages, page);
	}
}

/* The identity, after every command. */

static void
mark(place_t *places, const erx_plist_t *list, place_t place)
{
	erx_npages_t count = 0;

	for (const erx_page_t *page = list->head; page != NULL;
	    page = page->next, count++) {
		if (places[page_id(page)] != PLACE_UNSEEN)
			broken("a page in two places");
		places[page_id(page)] = place;
	}
	if (count != list->count)
		broken("a chain's count is not its length");
}

static void
check_identity(void)
{
	place_t places[PAGES_MAX] = { 0 };
	erx_reserve_counts_t counts;
	erx_npages_t pooled = 0, unseen = 0;
	uint64_t stamp = 0;

	mark(places, &free_pages, PLACE_FREE);
	mark(places, &released.list, PLACE_RELEASED);
	for (int i = 0; i < RESERVES_MAX; i++) {
		if (!reserve_exists[i])
			continue;
		mark(places, &backings[i].hand, PLACE_HAND);
		erx_reserve_read(reserves[i], &counts);
		pooled += counts.pooled;
	}
	for (long p = 0; p < npages; p++) {
		if (used_by[p] < 0)
			continue;
		if (places[p] != PLACE_UNSEEN)
			broken("a page in use and elsewhere");
		places[p] = PLACE_USED;
	}
	for (long p = 0; p < npages; p++)
		unseen += places[p] == PLACE_UNSEEN;
	if (unseen != pooled)
		broken("the pools do not hold the pages no one else does");
	for (const erx_page_t *page = released.list.head; page != NULL;
	    page = page->next) {
		if (page->stamp < stamp)
			broken("a stamp decreases along the released list");
		stamp = page->stamp;
	}
	if (grace_locked || released_locked)
		broken("a lock held between calls");
}

/* The commands. */

static void
init_pages(long n)
{
	if (n < 1 || n > PAGES_MAX)
		broken("pages out of range");
	npages = n;
	free_pages = (erx_plist_t){ 0 };
	for (long p = 0; p < n; p++) {
		used_by[p] = -1;
		records[p].stamp = 0;
		erx_plist_push(&free_pages, &records[p]);
	}
	root = record(erx_budget_record_size(), erx_budget_record_align());
	if (erx_budget_init_root(root, (erx_npages_t)n) != 0)
		broken("root refused");
}

static int
valid_reserve(long r)
{
	return (r >= 0 && r < RESERVES_MAX && reserve_exists[r]);
}

static void
release(long r, long pooled, long used)
{
	erx_budget_effects_t effects;
	erx_plist_t in_use = { 0 };
	long ids[PAGES_MAX];
	long n = 0;
	int error;

	for (long p = 0; p < npages && n < used; p++)
		if (used_by[p] == r)
			ids[n++] = p;
	if (n != used)
		broken("release of more pages than R uses");
	for (long i = 0; i < n; i++)
		erx_plist_push(&in_use, &records[ids[i]]);
	releasing = ids;
	nreleasing = n;
	releasing_list = released.list.count + (erx_npages_t)n +
	    (erx_npages_t)pooled;
	error = erx_page_release(&released, reserves[r], &in_use,
	    (erx_npages_t)pooled, &effects);
	releasing = NULL;
	if (error == 0)
		for (long i = 0; i < n; i++)
			used_by[ids[i]] = -1;
	printf("= %d\n", error);
}

/* Joins and leaves CPUs until exactly mask is online. */
static void
set_online(uint64_t mask)
{
	erx_grace_counts_t c;

	erx_grace_read(tracker, &c);
	for (uint32_t cpu = 0; cpu < 64; cpu++) {
		uint64_t bit = UINT64_C(1) << cpu;

		if ((mask & bit) != 0 && (c.online & bit) == 0)
			erx_grace_cpu_join(tracker, cpu);
		else if ((mask & bit) == 0 && (c.online & bit) != 0)
			(void)erx_grace_cpu_leave(tracker, cpu);
	}
}

/*
 * One backing step, checking that every page that left the hand for the
 * pool had a mature stamp.
 */
static void
step(long r, bool closed)
{
	erx_budget_effects_t effects;
	const erx_page_t *hand[ERX_PAGE_PART];
	size_t n = 0;
	int next;

	for (const erx_page_t *page = backings[r].hand.head; page != NULL &&
	    n < ERX_PAGE_PART; page = page->next)
		hand[n++] = page;
	next = erx_backing_step(&released, &backings[r], closed, &effects);
	if (backings[r].hand.count == 0)
		for (size_t i = 0; i < n; i++)
			if (!erx_grace_mature(tracker, hand[i]->stamp))
				broken("an immature page joined a pool");
	printf("= %d\n", next);
}

static void
command(char *line)
{
	char name[16];
	long a = 0, b = 0, c = 0;

	if (sscanf(line, "%15s %ld %ld %ld", name, &a, &b, &c) < 1)
		return;
	if (strcmp(name, "cpus") == 0) {
		set_online((uint64_t)a);
		printf("= %ld\n", a);
	} else if (strcmp(name, "join") == 0) {
		erx_grace_cpu_join(tracker, (uint32_t)a);
		printf("= %ld\n", a);
	} else if (strcmp(name, "leave") == 0) {
		printf("= %d\n", erx_grace_cpu_leave(tracker, (uint32_t)a));
	} else if (strcmp(name, "retire") == 0) {
		printf("= %" PRIu64 "\n", erx_grace_retire(tracker));
	} else if (strcmp(name, "report") == 0) {
		printf("= %d\n", erx_grace_report(tracker, (uint32_t)a));
	} else if (strcmp(name, "mature") == 0) {
		printf("= %d\n", erx_grace_mature(tracker,
		    (uint64_t)strtoull(line + 7, NULL, 10)));
	} else if (strcmp(name, "grace") == 0) {
		erx_grace_counts_t c;

		erx_grace_read(tracker, &c);
		printf("= %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %d\n",
		    c.current, c.completed, c.awaited, c.online, c.pending);
	} else if (strcmp(name, "pages") == 0) {
		init_pages(a);
		printf("= %ld\n", a);
	} else if (strcmp(name, "reserve") == 0) {
		if (a < 0 || a >= RESERVES_MAX || root == NULL)
			broken("reserve out of range");
		if (reserves[a] == NULL)
			reserves[a] = record(erx_reserve_record_size(),
			    erx_reserve_record_align());
		erx_reserve_init(reserves[a], root);
		backings[a] = (erx_backing_t){ 0 };
		reserve_exists[a] = true;
		printf("= %ld\n", a);
	} else if (!valid_reserve(a) && strcmp(name, "reap") != 0 &&
	    strcmp(name, "list") != 0 && strcmp(name, "free") != 0) {
		broken("no such reserve");
	} else if (strcmp(name, "charge") == 0) {
		erx_budget_effects_t effects;

		printf("= %d\n", erx_reserve_charge(&backings[a], reserves[a],
		    (erx_npages_t)b, &effects));
	} else if (strcmp(name, "step") == 0) {
		step(a, b != 0);
	} else if (strcmp(name, "take") == 0) {
		erx_page_t *page;

		erx_effect_reserve_lock(reserves[a]);
		page = erx_reserve_take(reserves[a]);
		erx_effect_reserve_unlock(reserves[a]);
		if (used_by[page_id(page)] >= 0 || !zeroed[page_id(page)])
			broken("a take handed out a page in use or unzeroed");
		zeroed[page_id(page)] = false;
		used_by[page_id(page)] = (int)a;
		printf("= %ld\n", page_id(page));
	} else if (strcmp(name, "release") == 0) {
		release(a, b, c);
	} else if (strcmp(name, "reap") == 0) {
		printf("= %" PRIu64 "\n", erx_released_free(&released,
		    (erx_npages_t)a));
	} else if (strcmp(name, "state") == 0) {
		erx_reserve_counts_t c;
		long in_use = 0;

		erx_reserve_read(reserves[a], &c);
		for (long p = 0; p < npages; p++)
			in_use += used_by[p] == a;
		printf("= %" PRIu64 " %" PRIu64 " %" PRIu64 " %ld %" PRIu64
		    "\n", c.charged, c.backed, c.pooled, in_use,
		    backings[a].hand.count);
	} else if (strcmp(name, "list") == 0) {
		printf("= %" PRIu64, released.list.count);
		for (const erx_page_t *page = released.list.head; page != NULL;
		    page = page->next)
			printf(" %ld:%" PRIu64, page_id(page), page->stamp);
		printf("\n");
	} else if (strcmp(name, "free") == 0) {
		printf("= %" PRIu64 "\n", free_pages.count);
	} else {
		broken("unknown command");
	}
	fflush(stdout);
	check_identity();
}

int
main(int argc, char **argv)
{
	char line[4096];
	FILE *input;

	if (argc != 2 || (input = fopen(argv[1], "r")) == NULL) {
		fprintf(stderr, "usage: page_driver SCRIPT\n");
		return (2);
	}
	tracker = record(erx_grace_record_size(), erx_grace_record_align());
	erx_grace_init(tracker);
	erx_released_init(&released, tracker);
	while (fgets(line, sizeof(line), input) != NULL)
		command(line);
	fclose(input);
	return (0);
}
