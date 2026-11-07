/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host checks of the Fiasco backend's page pool and range table, judged against
 * two models written here and not in the core: a fake memory unit, which behaves
 * as Fiasco was measured to (a map adds rights to what is there, an unmap of the
 * read right removes the mapping), and a table of what each page should be.
 *
 *   exhaustive  Every state of four neighbouring pages, every range over them,
 *               every call, with a pool that can cover the call and one that
 *               cannot. The refused call must leave every byte as it was.
 *   random      Long random call sequences over a wide area and a small index,
 *               so probe runs collide and shrink.
 *
 * Prints what it covered and exits 0, or names the first disagreement and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/core/vm_table.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define AREA_START	(UINT64_C(0x4000000000))
#define FEW_PAGES	4u
#define RANDOM_AREA_PAGES 256u
#define POOL_PAGES	96u
#define RANGES_MAX	64u
#define SLOTS		256u
#define FULL_RANGES	8u
/* Rights by themselves: read is ERX_PROT_R. */
#define RIGHT_W		2u
#define RIGHT_X		4u
#define RIGHTS_ALL	7u

/* What a page should be: the core's states, plus lying in a hole. */
#define PAGE_HOLE	(ERX_BACKEND_PAGE_RX + 1)
#define PAGE_KINDS	(PAGE_HOLE + 1)

typedef struct model_page {
	int	 kind;
	uint64_t contents;		/* the page's first word, while committed */
} model_page_t;

/* The fake memory unit: each page's mapping, by page index in the area. */
typedef struct mmu_page {
	uintptr_t window;	/* 0: nothing mapped */
	uint32_t  rights;
} mmu_page_t;

static mmu_page_t	mmu[RANDOM_AREA_PAGES];
static uint8_t		*window_memory;
static erx_fiasco_pool_t pool;
static erx_backend_vm_table_t table;
static erx_backend_vm_range_t ranges[RANGES_MAX];
static erx_backend_vm_page_t index_slots[SLOTS];
static const char	*current_case = "setup";
static unsigned long	 checks;

static _Noreturn void
fail(const char *what, uint64_t detail)
{
	fprintf(stderr, "%s: %s (0x%llx)\n", current_case, what, (unsigned long long)detail);
	exit(1);
}

static size_t
mmu_index(uint64_t addr)
{
	const uint64_t index = (addr - AREA_START) / PAGE;

	if (addr < AREA_START || index >= RANDOM_AREA_PAGES)
		fail("an effect outside the area", addr);
	return ((size_t)index);
}

static void
fake_map(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot)
{
	(void)label;
	mmu_page_t *page = &mmu[mmu_index(addr)];

	/* Fiasco keeps the mapping there and adds rights: a different page is a bug. */
	if (page->window != 0 && page->window != window)
		fail("a map over a mapping of a different page", addr);
	page->window = window;
	page->rights |= prot;
	if ((page->rights & RIGHT_W) != 0 && (page->rights & RIGHT_X) != 0)
		fail("a page writable and executable at once", addr);
}

static void
fake_unmap(uint32_t label, uint64_t addr, uint32_t rights)
{
	mmu_page_t *page = &mmu[mmu_index(addr)];

	(void)label;

	if (page->window == 0)
		fail("an unmap of nothing", addr);
	page->rights &= ~rights;
	if ((rights & ERX_PROT_R) != 0)
		*page = (mmu_page_t){ 0 };
}

static uintptr_t
fake_take(uint64_t addr)
{
	(void)addr;
	return (erx_fiasco_pool_take(&pool));
}

static void
fake_give(uintptr_t window, uint64_t addr)
{
	(void)addr;
	erx_fiasco_pool_put(&pool, window);
}

static uint64_t
fake_free_pages(void)
{
	return (pool.free_pages);
}

static const erx_backend_vm_effects_t effects = { .map = fake_map, .unmap = fake_unmap, .take = fake_take,
    .give = fake_give, .free_pages = fake_free_pages };

static void
world_reset(unsigned pool_pages)
{
	memset(mmu, 0, sizeof(mmu));
	memset(&pool, 0, sizeof(pool));
	memset(ranges, 0xa5, sizeof(ranges));
	erx_backend_vm_index_init(index_slots, SLOTS);
	erx_backend_vm_table_init(&table, 0, ranges, RANGES_MAX, index_slots, SLOTS, AREA_START,
	    AREA_START + RANDOM_AREA_PAGES * PAGE);
	for (unsigned page = 0; page < pool_pages; page++)
		erx_fiasco_pool_add(&pool, (uintptr_t)(window_memory + page * PAGE));
}

static uint32_t
prot_of(int kind)
{
	switch (kind) {
	case ERX_BACKEND_PAGE_R:
		return (ERX_PROT_R);
	case ERX_BACKEND_PAGE_RW:
		return (ERX_PROT_RW);
	case ERX_BACKEND_PAGE_RX:
		return (ERX_PROT_RX);
	default:
		return (ERX_PROT_NONE);
	}
}

static bool
kind_committed(int kind)
{
	return (kind == ERX_BACKEND_PAGE_NONE || kind == ERX_BACKEND_PAGE_R ||
	    kind == ERX_BACKEND_PAGE_RW || kind == ERX_BACKEND_PAGE_RX);
}

static int
call(erx_backend_vm_op_t op, uint64_t addr, uint64_t size, uint32_t flags, uint32_t prot, uint64_t *out)
{
	const erx_backend_vm_request_t request = { .op = op, .addr = addr, .size = size, .flags = flags, .prot = prot };

	return (erx_backend_vm_call(&table, &effects, &request, out));
}

/* Every fact the core and the fake memory unit hold agrees with the model. */
static void
world_check(const model_page_t *model, size_t npages, uint64_t pool_total)
{
	uint64_t committed = 0;

	for (size_t index = 0; index < npages; index++) {
		const mmu_page_t *page = &mmu[index];
		const int kind = model[index].kind;

		if (kind_committed(kind))
			committed++;
		if (page->rights != prot_of(kind))
			fail("a page has the wrong rights", index);
		if (prot_of(kind) != ERX_PROT_NONE) {
			if (page->window == 0)
				fail("an accessible page has no window page", index);
			if (*(uint64_t *)page->window != model[index].contents)
				fail("a page lost its contents", index);
		} else if (page->window != 0) {
			fail("an inaccessible page is still mapped", index);
		}
		checks++;
	}
	if (pool.free_pages + committed != pool_total)
		fail("the pool's count does not add up", pool.free_pages);
	if (pool.held_pages != committed)
		fail("the pool's held count is not the committed pages", pool.held_pages);
}

static void
model_set_reserved(model_page_t *model, size_t npages, int kind)
{
	for (size_t index = 0; index < npages; index++)
		model[index] = (model_page_t){ .kind = kind };
}

/* Brings a fresh world to this state of each page, through the calls themselves. */
static void
world_build(model_page_t *model, const int *kinds, size_t npages, uint64_t *next_word)
{
	for (size_t index = 0; index < npages; index++) {
		const uint64_t addr = AREA_START + index * PAGE;

		model[index] = (model_page_t){ .kind = kinds[index] };
		if (kinds[index] == PAGE_HOLE)
			continue;
		if (call(ERX_BACKEND_VM_RESERVE, addr, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, 0, NULL) != 0)
			fail("a fixed reserve failed", addr);
		if (kinds[index] == ERX_BACKEND_PAGE_UNCOMMITTED)
			continue;
		if (call(ERX_BACKEND_VM_COMMIT, addr, PAGE, 0, 0, NULL) != 0)
			fail("a commit failed", addr);
		if (mmu[index].window == 0)
			fail("a commit mapped nothing", addr);
		model[index].contents = ++(*next_word);
		*(uint64_t *)mmu[index].window = model[index].contents;
		if (call(ERX_BACKEND_VM_PROTECT, addr, PAGE, 0, prot_of(kinds[index]), NULL) != 0)
			fail("a protect failed", addr);
	}
}

/* What one page becomes: the model of the design's table. */
static void
model_page_move(model_page_t *page, int target)
{
	if (page->kind == PAGE_HOLE)
		return;
	if (target == ERX_BACKEND_PAGE_UNCOMMITTED) {
		*page = (model_page_t){ .kind = ERX_BACKEND_PAGE_UNCOMMITTED };
	} else if (page->kind == ERX_BACKEND_PAGE_UNCOMMITTED) {
		if (target != ERX_BACKEND_PAGE_NONE)
			*page = (model_page_t){ .kind = target };
	} else {
		page->kind = target;
	}
}

static uint64_t
model_pages_needed(const model_page_t *model, size_t first, size_t count, int target)
{
	uint64_t needed = 0;

	if (target == ERX_BACKEND_PAGE_UNCOMMITTED || target == ERX_BACKEND_PAGE_NONE)
		return (0);
	for (size_t index = first; index < first + count; index++)
		if (model[index].kind == ERX_BACKEND_PAGE_UNCOMMITTED)
			needed++;
	return (needed);
}

/* One call, its model and the bytes of a refusal, then the whole world's check. */
static void
call_and_check(model_page_t *model, size_t npages, erx_backend_vm_op_t op, size_t first, size_t count,
    uint32_t flags, int target, uint64_t pool_total)
{
	static erx_backend_vm_range_t ranges_before[RANGES_MAX];
	static erx_backend_vm_page_t index_before[SLOTS];
	static mmu_page_t mmu_before[RANDOM_AREA_PAGES];
	const uint64_t addr = AREA_START + first * PAGE;
	const uint64_t size = count * PAGE;
	const erx_fiasco_pool_t pool_before = pool;
	const size_t nranges_before = table.nranges;
	bool any_hole = false, any_range = false;
	int expected = 0;
	int error;

	for (size_t index = first; index < first + count; index++) {
		any_hole = any_hole || model[index].kind == PAGE_HOLE;
		any_range = any_range || model[index].kind != PAGE_HOLE;
	}
	if (op == ERX_BACKEND_VM_PROTECT && any_hole)
		expected = ERX_ERANGE;
	else if (op == ERX_BACKEND_VM_RESERVE && (flags & ERX_VM_NOREPLACE) != 0 && any_range)
		expected = ERX_EEXIST;
	else if (model_pages_needed(model, first, count, target) > pool.free_pages)
		expected = ERX_ENOMEM;

	memcpy(ranges_before, ranges, sizeof(ranges));
	memcpy(index_before, index_slots, sizeof(index_slots));
	memcpy(mmu_before, mmu, sizeof(mmu));
	error = call(op, addr, size, flags, prot_of(target), NULL);
	if (error != expected)
		fail("the call's result differs", (uint64_t)(int64_t)error);
	if (error != 0) {
		/* A refused call changes nothing at all. */
		if (memcmp(ranges_before, ranges, sizeof(ranges)) != 0 ||
		    memcmp(index_before, index_slots, sizeof(index_slots)) != 0 ||
		    memcmp(mmu_before, mmu, sizeof(mmu)) != 0 || nranges_before != table.nranges ||
		    pool_before.head != pool.head || pool_before.free_pages != pool.free_pages)
			fail("a refused call changed something", (uint64_t)(int64_t)error);
	} else if (op == ERX_BACKEND_VM_RESERVE) {
		for (size_t index = first; index < first + count; index++)
			model[index] = (model_page_t){ .kind = ERX_BACKEND_PAGE_UNCOMMITTED };
	} else if (op == ERX_BACKEND_VM_RELEASE) {
		for (size_t index = first; index < first + count; index++)
			model[index] = (model_page_t){ .kind = PAGE_HOLE };
	} else {
		for (size_t index = first; index < first + count; index++)
			model_page_move(&model[index], target);
	}
	world_check(model, npages, pool_total);
}

static void
check_every_state_range_and_call(void)
{
	static const int prot_targets[] = { ERX_BACKEND_PAGE_NONE, ERX_BACKEND_PAGE_R, ERX_BACKEND_PAGE_RW, ERX_BACKEND_PAGE_RX };
	unsigned long combinations = 1, runs = 0;
	model_page_t model[FEW_PAGES];
	int kinds[FEW_PAGES];

	current_case = "exhaustive";
	for (unsigned page = 0; page < FEW_PAGES; page++)
		combinations *= PAGE_KINDS;
	for (unsigned long combination = 0; combination < combinations; combination++) {
		unsigned long rest = combination;
		unsigned committed = 0;

		for (unsigned page = 0; page < FEW_PAGES; page++) {
			kinds[page] = (int)(rest % PAGE_KINDS);
			rest /= PAGE_KINDS;
			committed += kind_committed(kinds[page]) ? 1u : 0u;
		}
		for (size_t first = 0; first < FEW_PAGES; first++) {
			for (size_t count = 1; first + count <= FEW_PAGES; count++) {
				/* Each variant is a pool with room, and one with none left. */
				for (int shortage = 0; shortage < 2; shortage++) {
					const unsigned pool_total = shortage != 0 ? committed : committed + FEW_PAGES;
					uint64_t next_word = 0;

#define ONE_CALL(op, flags, target) do {					\
		world_reset(pool_total);					\
		world_build(model, kinds, FEW_PAGES, &next_word);		\
		call_and_check(model, FEW_PAGES, (op), first, count, (flags),	\
		    (target), pool_total);					\
		runs++;								\
	} while (0)
					ONE_CALL(ERX_BACKEND_VM_COMMIT, 0, ERX_BACKEND_PAGE_RW);
					ONE_CALL(ERX_BACKEND_VM_DECOMMIT, 0, ERX_BACKEND_PAGE_UNCOMMITTED);
					ONE_CALL(ERX_BACKEND_VM_RELEASE, 0, ERX_BACKEND_PAGE_UNCOMMITTED);
					ONE_CALL(ERX_BACKEND_VM_RESERVE, ERX_VM_FIXED, ERX_BACKEND_PAGE_UNCOMMITTED);
					ONE_CALL(ERX_BACKEND_VM_RESERVE, ERX_VM_FIXED | ERX_VM_NOREPLACE, ERX_BACKEND_PAGE_UNCOMMITTED);
					for (size_t index = 0; index < sizeof(prot_targets) / sizeof(prot_targets[0]); index++)
						ONE_CALL(ERX_BACKEND_VM_PROTECT, 0, prot_targets[index]);
#undef ONE_CALL
				}
			}
		}
	}
	printf("exhaustive: %lu calls\n", runs);
}

/* The design's table of protection changes, cell by cell, from one page's view. */
static void
check_steps_table(void)
{
	current_case = "steps";
	for (int from = 0; from < (int)ERX_BACKEND_PAGE_STATES; from++) {
		for (int to = 0; to < (int)ERX_BACKEND_PAGE_STATES; to++) {
			const erx_backend_vm_steps_t steps = erx_backend_vm_steps((erx_backend_vm_state_t)from, (erx_backend_vm_state_t)to);
			const bool from_committed = kind_committed(from);
			const uint32_t from_prot = prot_of(from);
			uint32_t rights = from_prot;
			const int after = from == ERX_BACKEND_PAGE_UNCOMMITTED && to == ERX_BACKEND_PAGE_NONE ?
			    ERX_BACKEND_PAGE_UNCOMMITTED : to;

			/* Only an uncommitted page given access takes one; only leaving commitment gives one back. */
			if (steps.take != (!from_committed && kind_committed(to) && to != ERX_BACKEND_PAGE_NONE))
				fail("steps take a page they should not", (uint64_t)from * 16 + (uint64_t)to);
			if (steps.give_back != (from_committed && to == ERX_BACKEND_PAGE_UNCOMMITTED))
				fail("steps give back a page they should not", (uint64_t)from * 16 + (uint64_t)to);
			if ((int)steps.after != after)
				fail("steps end in the wrong state", (uint64_t)from * 16 + (uint64_t)to);
			if ((steps.drop & ~from_prot) != 0 && (steps.drop & RIGHTS_ALL) != RIGHTS_ALL)
				fail("steps drop a right the page does not have", (uint64_t)from * 16 + (uint64_t)to);
			rights &= ~(uint32_t)steps.drop;
			if ((rights & ERX_PROT_R) == 0)
				rights = 0;
			if (((rights | steps.map) & (RIGHT_W | RIGHT_X)) == (RIGHT_W | RIGHT_X))
				fail("a step leaves write with execute", (uint64_t)from * 16 + (uint64_t)to);
			rights |= steps.map;
			if (rights != prot_of(after))
				fail("steps reach the wrong rights", (uint64_t)from * 16 + (uint64_t)to);
			checks++;
		}
	}
}

static void
check_refusals(void)
{
	static const uint32_t bad_prots[] = { 2, 4, 6, 7, 8, UINT32_MAX };
	const uint64_t area_end = AREA_START + RANDOM_AREA_PAGES * PAGE;
	uint64_t reserved;

	current_case = "refusals";
	world_reset(POOL_PAGES);
	if (call(ERX_BACKEND_VM_RESERVE, 0, PAGE, 0, 0, &reserved) != 0 || reserved != AREA_START)
		fail("the first free range is not the area's start", reserved);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START + 1, PAGE, ERX_VM_FIXED, 0, NULL) != ERX_EINVAL)
		fail("a misaligned reserve passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START, 1, ERX_VM_FIXED, 0, NULL) != ERX_EINVAL)
		fail("a misaligned size passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, 0, 0, 0, 0, NULL) != ERX_EINVAL)
		fail("an empty reserve passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START, PAGE, ERX_VM_NOREPLACE, 0, NULL) != ERX_EINVAL)
		fail("noreplace without fixed passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START, PAGE, 4, 0, NULL) != ERX_EINVAL)
		fail("unknown flags passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, 0, RANDOM_AREA_PAGES * PAGE, 0, 0, NULL) != ERX_ENOMEM)
		fail("a reserve too large for the free space passed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, 0, UINT64_MAX - PAGE + 1, 0, 0, NULL) != ERX_ENOMEM)
		fail("a wrapping reserve passed", 0);
	if (call(ERX_BACKEND_VM_COMMIT, area_end, PAGE, 0, 0, NULL) != ERX_ERANGE ||
	    call(ERX_BACKEND_VM_COMMIT, AREA_START - PAGE, PAGE, 0, 0, NULL) != ERX_ERANGE ||
	    call(ERX_BACKEND_VM_COMMIT, UINT64_MAX - PAGE + 1, PAGE, 0, 0, NULL) != ERX_ERANGE)
		fail("a range outside the area passed", 0);
	for (size_t index = 0; index < sizeof(bad_prots) / sizeof(bad_prots[0]); index++)
		if (call(ERX_BACKEND_VM_PROTECT, AREA_START, PAGE, 0, bad_prots[index], NULL) != ERX_EINVAL)
			fail("a protection that is not one passed", bad_prots[index]);

	/* A full table, of runs with gaps too wide for a page to touch either side. */
	world_reset(POOL_PAGES);
	table.ranges_max = FULL_RANGES;
	for (unsigned run = 0; run < FULL_RANGES; run++)
		if (call(ERX_BACKEND_VM_RESERVE, AREA_START + 6 * run * PAGE, 3 * PAGE, ERX_VM_FIXED, 0, NULL) != 0)
			fail("filling the table failed", run);
	if (call(ERX_BACKEND_VM_RESERVE, 0, PAGE, 0, 0, NULL) != ERX_ENOMEM)
		fail("a reserve passed with the table full", 0);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START + 4 * PAGE, PAGE, ERX_VM_FIXED, 0, NULL) != ERX_ENOMEM)
		fail("a reserve needing a run passed with the table full", 0);
	if (call(ERX_BACKEND_VM_RELEASE, AREA_START + PAGE, PAGE, 0, 0, NULL) != ERX_ENOMEM)
		fail("a splitting release passed with the table full", 0);
	if (table.nranges != FULL_RANGES)
		fail("a refusal changed the table", table.nranges);
	if (call(ERX_BACKEND_VM_RELEASE, AREA_START, PAGE, 0, 0, NULL) != 0 || table.nranges != FULL_RANGES)
		fail("a release that adds no run failed", 0);

	/* One below full: a fixed reserve inside a run splits it, then merges back. */
	if (call(ERX_BACKEND_VM_RELEASE, AREA_START + 6 * (FULL_RANGES - 1) * PAGE, 3 * PAGE, 0, 0, NULL) != 0 ||
	    table.nranges != FULL_RANGES - 1)
		fail("a release of a whole run failed", 0);
	if (call(ERX_BACKEND_VM_RESERVE, AREA_START + 7 * PAGE, PAGE, ERX_VM_FIXED, 0, NULL) != 0 ||
	    table.nranges != FULL_RANGES - 1)
		fail("a fixed reserve inside a run changed the count", table.nranges);
}

/* A reserve without an address takes the lowest hole that fits, or there is none. */
static void
call_lowest_fit(model_page_t *model, size_t count)
{
	size_t run = 0;
	size_t found = RANDOM_AREA_PAGES;
	uint64_t reserved = 0;
	int error;

	for (size_t index = 0; index < RANDOM_AREA_PAGES && found == RANDOM_AREA_PAGES; index++) {
		run = model[index].kind == PAGE_HOLE ? run + 1 : 0;
		if (run == count)
			found = index + 1 - count;
	}
	error = call(ERX_BACKEND_VM_RESERVE, 0, count * PAGE, 0, 0, &reserved);
	if (error != (found == RANDOM_AREA_PAGES ? ERX_ENOMEM : 0) ||
	    (error == 0 && reserved != AREA_START + found * PAGE))
		fail("a non-fixed reserve landed wrong", reserved);
	if (error == 0)
		model_set_reserved(&model[found], count, ERX_BACKEND_PAGE_UNCOMMITTED);
	world_check(model, RANDOM_AREA_PAGES, POOL_PAGES);
}

/* Random calls against the model: runs merge and split, probe runs collide and close. */
static void
check_random_calls(unsigned seed, unsigned calls)
{
	static model_page_t model[RANDOM_AREA_PAGES];
	static const int targets[] = { ERX_BACKEND_PAGE_NONE, ERX_BACKEND_PAGE_R, ERX_BACKEND_PAGE_RW, ERX_BACKEND_PAGE_RX };

	current_case = "random";
	world_reset(POOL_PAGES);
	model_set_reserved(model, RANDOM_AREA_PAGES, PAGE_HOLE);
	srand(seed);
	for (unsigned call_number = 0; call_number < calls; call_number++) {
		const size_t first = (size_t)rand() % RANDOM_AREA_PAGES;
		const size_t room = RANDOM_AREA_PAGES - first;
		const size_t count = 1 + (size_t)rand() % (rand() % 8 == 0 || room < 16 ? room : 16);
		const int target = targets[rand() % 4];

		switch (rand() % 6) {
		case 5:
			if (table.nranges + 2 < RANGES_MAX)
				call_lowest_fit(model, count);
			break;
		case 0:
			/* Too many separate runs refuses for its own reason: keep clear of it. */
			if (table.nranges + 2 < RANGES_MAX)
				call_and_check(model, RANDOM_AREA_PAGES, ERX_BACKEND_VM_RESERVE, first, count, ERX_VM_FIXED, ERX_BACKEND_PAGE_UNCOMMITTED, POOL_PAGES);
			break;
		case 1:
			call_and_check(model, RANDOM_AREA_PAGES, ERX_BACKEND_VM_COMMIT, first, count, 0, ERX_BACKEND_PAGE_RW, POOL_PAGES);
			break;
		case 2:
			call_and_check(model, RANDOM_AREA_PAGES, ERX_BACKEND_VM_DECOMMIT, first, count, 0, ERX_BACKEND_PAGE_UNCOMMITTED, POOL_PAGES);
			break;
		case 3:
			if (table.nranges + 2 < RANGES_MAX)
				call_and_check(model, RANDOM_AREA_PAGES, ERX_BACKEND_VM_RELEASE, first, count, 0, ERX_BACKEND_PAGE_UNCOMMITTED, POOL_PAGES);
			break;
		default:
			call_and_check(model, RANDOM_AREA_PAGES, ERX_BACKEND_VM_PROTECT, first, count, 0, target, POOL_PAGES);
			break;
		}
		/* New contents through a writable page, so a mix-up of window pages shows. */
		for (size_t index = 0; index < RANDOM_AREA_PAGES; index++) {
			if (mmu[index].window != 0 && (mmu[index].rights & RIGHT_W) != 0) {
				model[index].contents = (uint64_t)rand() + 1;
				*(uint64_t *)mmu[index].window = model[index].contents;
			}
		}
	}
	printf("random: seed %u, %u calls\n", seed, calls);
}

/* Taken pages are zero, whatever they last held, and the pool counts true. */
static void
check_pool(void)
{
	erx_fiasco_pool_t small = { 0 };
	uintptr_t first, second;

	current_case = "pool";
	if (erx_fiasco_pool_take(&small) != 0)
		fail("an empty pool gave a page", 0);
	memset(window_memory, 0x5a, 2 * (size_t)PAGE);
	erx_fiasco_pool_add(&small, (uintptr_t)window_memory);
	erx_fiasco_pool_add(&small, (uintptr_t)(window_memory + PAGE));
	if (small.held_pages != 0)
		fail("building the pool counted a page as held", small.held_pages);
	first = erx_fiasco_pool_take(&small);
	second = erx_fiasco_pool_take(&small);
	if (first == 0 || second == 0 || first == second || small.free_pages != 0 ||
	    erx_fiasco_pool_take(&small) != 0)
		fail("the pool lost count", small.free_pages);
	if (small.held_pages != 2)
		fail("a take did not count the page as held", small.held_pages);
	for (size_t offset = 0; offset < PAGE; offset++)
		if (((uint8_t *)first)[offset] != 0 || ((uint8_t *)second)[offset] != 0)
			fail("a taken page is not zero", offset);
	erx_fiasco_pool_put(&small, first);
	if (small.held_pages != 1 || small.free_pages != 1)
		fail("a put did not take the page off the held count", small.held_pages);
	erx_fiasco_pool_put(&small, second);
	/* A page that was never taken: the count stays at 0 rather than wrap. */
	erx_fiasco_pool_put(&small, first + PAGE * 2);
	if (small.held_pages != 0 || small.free_pages != 3)
		fail("the held count wrapped", small.held_pages);
}

/* Where a table's effects landed, for the cases over more than one table. */
typedef struct label_map {
	uint32_t	label;
	uintptr_t	window;
	uint64_t	addr;
	uint32_t	prot;
} label_map_t;

static label_map_t label_maps[64];
static size_t label_nmaps;
/* Table 1's rights, by page: a map adds, as Fiasco's does. */
static uint32_t label_rights[16];

static void
label_map(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot)
{
	if (label_nmaps == sizeof(label_maps) / sizeof(label_maps[0]))
		fail("too many maps", addr);
	label_maps[label_nmaps++] = (label_map_t){ .label = label, .window = window, .addr = addr, .prot = prot };
	if (label == 1) {
		label_rights[(addr - AREA_START) / PAGE] |= prot;
		if ((label_rights[(addr - AREA_START) / PAGE] & (RIGHT_W | RIGHT_X)) == (RIGHT_W | RIGHT_X))
			fail("an alias writable and executable at once", addr);
	}
}

static void
label_unmap(uint32_t label, uint64_t addr, uint32_t rights)
{
	if (label == 1)
		label_rights[(addr - AREA_START) / PAGE] &= ~rights;
}

static const erx_backend_vm_effects_t label_effects = { .map = label_map, .unmap = label_unmap, .take = fake_take,
    .give = fake_give, .free_pages = fake_free_pages };

static int
table_call(erx_backend_vm_table_t *which, erx_backend_vm_op_t op, uint64_t addr, uint64_t size, uint32_t flags, uint32_t prot)
{
	const erx_backend_vm_request_t request = { .op = op, .addr = addr, .size = size, .flags = flags, .prot = prot };

	return (erx_backend_vm_call(which, &label_effects, &request, NULL));
}

/* Two tables and an object share one index: the same address names a page per label, and each clears alone. */
static void
check_labels(void)
{
	static erx_backend_vm_range_t ranges_a[4], ranges_b[4], ranges_object[2];
	erx_backend_vm_table_t a, b, object;
	uintptr_t window_a, window_b, window_object;
	uint64_t full;

	current_case = "labels";
	world_reset(POOL_PAGES);
	memset(label_rights, 0, sizeof(label_rights));
	full = pool.free_pages;
	erx_backend_vm_table_init(&a, 1, ranges_a, 4, index_slots, SLOTS, AREA_START, AREA_START + 16 * PAGE);
	erx_backend_vm_table_init(&b, 2, ranges_b, 4, index_slots, SLOTS, AREA_START, AREA_START + 16 * PAGE);
	erx_backend_vm_table_init(&object, 3, ranges_object, 2, index_slots, SLOTS, PAGE, PAGE + 16 * PAGE);
	if (table_call(&a, ERX_BACKEND_VM_RESERVE, AREA_START, 4 * PAGE, ERX_VM_FIXED, 0) != 0 ||
	    table_call(&b, ERX_BACKEND_VM_RESERVE, AREA_START, 4 * PAGE, ERX_VM_FIXED, 0) != 0 ||
	    table_call(&a, ERX_BACKEND_VM_COMMIT, AREA_START, PAGE, 0, 0) != 0 ||
	    table_call(&b, ERX_BACKEND_VM_COMMIT, AREA_START, PAGE, 0, 0) != 0)
		fail("two tables' calls were refused", 0);
	window_a = erx_backend_vm_window(&a, AREA_START);
	window_b = erx_backend_vm_window(&b, AREA_START);
	if (window_a == 0 || window_b == 0 || window_a == window_b)
		fail("two tables share a page", window_a);
	if (erx_backend_vm_window(&a, AREA_START + PAGE) != 0 || erx_backend_vm_window(&object, AREA_START) != 0)
		fail("a window for an uncommitted page", 0);
	if (table_call(&a, ERX_BACKEND_VM_DECOMMIT, AREA_START, PAGE, 0, 0) != 0 ||
	    erx_backend_vm_window(&b, AREA_START) != window_b)
		fail("one table's decommit reached another's page", window_b);

	if (table_call(&object, ERX_BACKEND_VM_RESERVE, PAGE, 2 * PAGE, ERX_VM_FIXED, 0) != 0 ||
	    table_call(&object, ERX_BACKEND_VM_COMMIT, PAGE, 2 * PAGE, 0, 0) != 0)
		fail("the object's pages were refused", 0);
	window_object = erx_backend_vm_window(&object, 2 * PAGE);
	label_nmaps = 0;
	if (erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 2 * PAGE, PAGE, PAGE, ERX_PROT_RW) != 0 ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 3 * PAGE, PAGE, PAGE, ERX_PROT_RX) != 0)
		fail("two aliases of one page were refused", 0);
	if (label_nmaps != 2 || label_maps[0].window != window_object || label_maps[1].window != window_object ||
	    label_maps[0].label != 1 || label_maps[0].addr != AREA_START + 2 * PAGE || label_maps[0].prot != ERX_PROT_RW ||
	    label_maps[1].addr != AREA_START + 3 * PAGE || label_maps[1].prot != ERX_PROT_RX)
		fail("an alias landed wrong", label_nmaps);
	if (erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 2 * PAGE, PAGE, PAGE, ERX_PROT_RX) != 0)
		fail("a second map of an alias was refused", 0);
	label_nmaps = 0;
	if (erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 2 * PAGE, PAGE, 0, ERX_PROT_NONE) != ERX_EINVAL ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 2 * PAGE, PAGE, 0, ERX_PROT_RW | ERX_PROT_RX) != ERX_EINVAL ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 2 * PAGE, PAGE, 1, ERX_PROT_RW) != ERX_EINVAL ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START + 8 * PAGE, PAGE, 0, ERX_PROT_RW) != ERX_ERANGE ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START, PAGE, 2 * PAGE, ERX_PROT_RW) != ERX_ERANGE ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START, 2 * PAGE, PAGE, ERX_PROT_RW) != ERX_ERANGE)
		fail("a bad alias passed", label_nmaps);
	if (table_call(&a, ERX_BACKEND_VM_COMMIT, AREA_START, PAGE, 0, 0) != 0 ||
	    erx_backend_vm_map_object(&a, &object, &label_effects, AREA_START, PAGE, 0, ERX_PROT_RW) != ERX_EEXIST)
		fail("an alias over a committed page passed", label_nmaps);
	if (label_nmaps != 1)
		fail("a refused alias mapped", label_nmaps);

	erx_backend_vm_table_clear(&a, &label_effects);
	if (a.nranges != 0 || erx_backend_vm_window(&a, AREA_START) != 0 || erx_backend_vm_window(&b, AREA_START) != window_b ||
	    erx_backend_vm_window(&object, 2 * PAGE) != window_object)
		fail("clearing one table reached another's page", window_b);
	erx_backend_vm_table_clear(&b, &label_effects);
	erx_backend_vm_table_clear(&object, &label_effects);
	if (pool.free_pages != full)
		fail("the pool's count did not return", pool.free_pages);
	for (size_t slot = 0; slot < SLOTS; slot++)
		if (index_slots[slot].key != 0)
			fail("the index kept a cleared page", slot);
}

/* An index always has twice the slots of the pages it might hold, and fills whole pages. */
static void
check_layout(void)
{
	static const uint64_t sizes[] = { 1, 2, 128, 129, 256, 122188, UINT64_C(1) << 20 };

	current_case = "layout";
	for (size_t index = 0; index < sizeof(sizes) / sizeof(sizes[0]); index++) {
		const erx_backend_vm_layout_t layout = erx_backend_vm_layout(sizes[index]);

		if (layout.index_slots < 2 * sizes[index] ||
		    (layout.index_slots & (layout.index_slots - 1)) != 0 ||
		    layout.index_pages * PAGE != layout.index_slots * sizeof(erx_backend_vm_page_t) ||
		    layout.index_pages == 0)
			fail("the index does not suit the window", sizes[index]);
	}
}

/*
 * The contiguous pool against a table of what each page holds: every run from every
 * state that a sequence of small takes reaches, and the limit at each value around it.
 */
static void
check_contig_take(erx_fiasco_contig_t *pool, bool *held, uint32_t pages, uint32_t limit)
{
	uint32_t align = 1;
	uint32_t first, expected = ERX_FIASCO_CONTIG_NONE;

	while (align < pages)
		align *= 2;
	for (uint32_t candidate = 0; expected == ERX_FIASCO_CONTIG_NONE && candidate + pages <= limit; candidate += align) {
		bool free_run = true;

		for (uint32_t page = candidate; page < candidate + pages; page++)
			free_run = free_run && !held[page];
		if (free_run)
			expected = candidate;
	}
	first = erx_fiasco_contig_take(pool, pages, limit);
	if (!(first == expected))
		fail("contig: first fit, aligned, below the limit, over free pages", 0);
	if (first == ERX_FIASCO_CONTIG_NONE)
		return;
	for (uint32_t page = first; page < first + pages; page++)
		held[page] = true;
}

static void
check_contig(unsigned seed)
{
	erx_fiasco_contig_t pool = { { 0 } };
	bool held[ERX_FIASCO_CONTIG_PAGES] = { false };

	current_case = "contiguous pool";
	if (!(erx_fiasco_contig_take(&pool, 0, ERX_FIASCO_CONTIG_PAGES) == ERX_FIASCO_CONTIG_NONE))
		fail("contig: an empty run", 0);
	if (!(erx_fiasco_contig_take(&pool, ERX_FIASCO_CONTIG_PAGES + 1, UINT32_MAX) == ERX_FIASCO_CONTIG_NONE))
		fail("contig: a run longer than the pool", 0);
	if (!(erx_fiasco_contig_take(&pool, 1, 0) == ERX_FIASCO_CONTIG_NONE))
		fail("contig: a limit below every page", 0);
	for (uint32_t pages = 1; pages <= ERX_FIASCO_CONTIG_PAGES; pages++) {
		erx_fiasco_contig_t alone = { { 0 } };
		bool alone_held[ERX_FIASCO_CONTIG_PAGES] = { false };

		check_contig_take(&alone, alone_held, pages, ERX_FIASCO_CONTIG_PAGES);
		check_contig_take(&alone, alone_held, pages, ERX_FIASCO_CONTIG_PAGES);
	}
	srandom((unsigned)seed);
	for (uint32_t round = 0; round < 4000; round++) {
		const uint32_t pages = 1 + (uint32_t)random() % (round % 8 == 0 ? 256 : 8);
		const uint32_t limit = 1 + (uint32_t)random() % ERX_FIASCO_CONTIG_PAGES;

		check_contig_take(&pool, held, pages, limit);
	}
}

int
main(int argc, char **argv)
{
	const unsigned seed = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 20261104u;

	if (posix_memalign((void **)&window_memory, ERX_PAGE_SIZE, (size_t)(POOL_PAGES * PAGE)) != 0)
		return (1);
	check_pool();
	check_contig(seed);
	check_layout();
	check_refusals();
	check_every_state_range_and_call();
	check_random_calls(seed, 20000);
	check_random_calls(seed + 1, 20000);
	check_steps_table();
	check_labels();
	printf("ok: %lu checks\n", checks);
	free(window_memory);
	return (0);
}
