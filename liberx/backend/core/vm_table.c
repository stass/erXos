/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/core/mem.h"
#include "liberx/backend/core/vm_table.h"

#define VM_PAGE_MASK		((uint64_t)ERX_PAGE_SIZE - 1)
#define VM_STATE_MASK		UINT64_C(7)
/* A key's page number stays below this bit: the backend's addresses stop at 2^39. */
#define VM_LABEL_SHIFT		27u
/* Rights by themselves, as ERX_PROT_* spells them only in combinations. */
#define VM_RIGHT_W		(ERX_PROT_RW & ~ERX_PROT_R)
#define VM_RIGHT_X		(ERX_PROT_RX & ~ERX_PROT_R)
#define VM_RIGHTS_ALL		(ERX_PROT_RW | ERX_PROT_RX)
/* Fibonacci hashing's multiplier: 2^64 divided by the golden ratio. */
#define VM_HASH_MULTIPLIER	UINT64_C(0x9e3779b97f4a7c15)

_Static_assert(sizeof(erx_backend_vm_page_t) == 16, "the page index's slots are 16 bytes");

static uint64_t	count_takes(const erx_backend_vm_table_t *, uint64_t, uint64_t, erx_backend_vm_state_t);
static int	find_free_range(const erx_backend_vm_table_t *, uint64_t, uint64_t *);
static size_t	page_find(const erx_backend_vm_table_t *, uint64_t);
static void	page_forget(erx_backend_vm_table_t *, size_t);
static size_t	page_home(const erx_backend_vm_table_t *, uint64_t);
static erx_backend_vm_state_t page_state(const erx_backend_vm_page_t *);
static void	page_move(erx_backend_vm_table_t *,
		    const erx_backend_vm_effects_t *, uint64_t, erx_backend_vm_state_t);
static void	pages_move(erx_backend_vm_table_t *,
		    const erx_backend_vm_effects_t *, uint64_t, uint64_t, erx_backend_vm_state_t);
static int	range_decode(const erx_backend_vm_table_t *, uint64_t, uint64_t, uint64_t *);
static bool	range_overlaps(const erx_backend_vm_table_t *, uint64_t, uint64_t);
static bool	range_reserved(const erx_backend_vm_table_t *, uint64_t, uint64_t);
static void	ranges_add(erx_backend_vm_table_t *, uint64_t, uint64_t);
static size_t	ranges_first_after(const erx_backend_vm_table_t *, uint64_t);
static void	ranges_remove(erx_backend_vm_table_t *, uint64_t, uint64_t);
static bool	ranges_split(const erx_backend_vm_table_t *, uint64_t, uint64_t);
static uint64_t	page_key(const erx_backend_vm_table_t *, uint64_t);
static void	apply_plan(erx_backend_vm_table_t *,
		    const erx_backend_vm_effects_t *, const erx_backend_vm_plan_t *);
static int	plan_reserve(const erx_backend_vm_table_t *, const erx_backend_vm_request_t *,
		    erx_backend_vm_plan_t *);

/*
 * docs/design-stopgap.md's table of protection changes, whole. Write means read
 * and write, execute means read and execute, and a map only adds rights.
 */
static const erx_backend_vm_steps_t vm_steps[ERX_BACKEND_PAGE_STATES][ERX_BACKEND_PAGE_STATES] = {
	[ERX_BACKEND_PAGE_UNCOMMITTED] = {
		[ERX_BACKEND_PAGE_UNCOMMITTED] = { .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_NONE] = { .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_R] = { .take = true, .map = ERX_PROT_R, .after = ERX_BACKEND_PAGE_R },
		[ERX_BACKEND_PAGE_RW] = { .take = true, .map = ERX_PROT_RW, .after = ERX_BACKEND_PAGE_RW },
		[ERX_BACKEND_PAGE_RX] = { .take = true, .map = ERX_PROT_RX, .after = ERX_BACKEND_PAGE_RX },
	},
	[ERX_BACKEND_PAGE_NONE] = {
		[ERX_BACKEND_PAGE_UNCOMMITTED] = { .give_back = true, .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_NONE] = { .after = ERX_BACKEND_PAGE_NONE },
		[ERX_BACKEND_PAGE_R] = { .map = ERX_PROT_R, .after = ERX_BACKEND_PAGE_R },
		[ERX_BACKEND_PAGE_RW] = { .map = ERX_PROT_RW, .after = ERX_BACKEND_PAGE_RW },
		[ERX_BACKEND_PAGE_RX] = { .map = ERX_PROT_RX, .after = ERX_BACKEND_PAGE_RX },
	},
	[ERX_BACKEND_PAGE_R] = {
		[ERX_BACKEND_PAGE_UNCOMMITTED] = { .drop = VM_RIGHTS_ALL, .give_back = true, .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_NONE] = { .drop = VM_RIGHTS_ALL, .after = ERX_BACKEND_PAGE_NONE },
		[ERX_BACKEND_PAGE_R] = { .after = ERX_BACKEND_PAGE_R },
		[ERX_BACKEND_PAGE_RW] = { .map = ERX_PROT_RW, .after = ERX_BACKEND_PAGE_RW },
		[ERX_BACKEND_PAGE_RX] = { .map = ERX_PROT_RX, .after = ERX_BACKEND_PAGE_RX },
	},
	[ERX_BACKEND_PAGE_RW] = {
		[ERX_BACKEND_PAGE_UNCOMMITTED] = { .drop = VM_RIGHTS_ALL, .give_back = true, .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_NONE] = { .drop = VM_RIGHTS_ALL, .after = ERX_BACKEND_PAGE_NONE },
		[ERX_BACKEND_PAGE_R] = { .drop = VM_RIGHT_W, .after = ERX_BACKEND_PAGE_R },
		[ERX_BACKEND_PAGE_RW] = { .after = ERX_BACKEND_PAGE_RW },
		[ERX_BACKEND_PAGE_RX] = { .drop = VM_RIGHT_W, .map = ERX_PROT_RX, .after = ERX_BACKEND_PAGE_RX },
	},
	[ERX_BACKEND_PAGE_RX] = {
		[ERX_BACKEND_PAGE_UNCOMMITTED] = { .drop = VM_RIGHTS_ALL, .give_back = true, .after = ERX_BACKEND_PAGE_UNCOMMITTED },
		[ERX_BACKEND_PAGE_NONE] = { .drop = VM_RIGHTS_ALL, .after = ERX_BACKEND_PAGE_NONE },
		[ERX_BACKEND_PAGE_R] = { .drop = VM_RIGHT_X, .after = ERX_BACKEND_PAGE_R },
		[ERX_BACKEND_PAGE_RW] = { .drop = VM_RIGHT_X, .map = ERX_PROT_RW, .after = ERX_BACKEND_PAGE_RW },
		[ERX_BACKEND_PAGE_RX] = { .after = ERX_BACKEND_PAGE_RX },
	},
};

erx_backend_vm_layout_t
erx_backend_vm_layout(uint64_t window_pages)
{
	const uint64_t slots_per_page = ERX_PAGE_SIZE / sizeof(erx_backend_vm_page_t);
	uint64_t slots = slots_per_page;

	while (slots < 2 * window_pages)
		slots *= 2;
	return ((erx_backend_vm_layout_t){ .index_pages = slots / slots_per_page, .index_slots = slots });
}

void
erx_backend_vm_index_init(erx_backend_vm_page_t *pages, size_t slots)
{
	bzero(pages, slots * sizeof(*pages));
}

void
erx_backend_vm_table_init(erx_backend_vm_table_t *table, uint32_t label, erx_backend_vm_range_t *ranges,
    size_t ranges_max, erx_backend_vm_page_t *pages, size_t slots, uint64_t area_start,
    uint64_t area_end)
{
	*table = (erx_backend_vm_table_t){ .label = label, .ranges = ranges, .ranges_max = ranges_max,
	    .pages = pages, .pages_mask = slots - 1, .area_start = area_start, .area_end = area_end };
}

erx_backend_vm_steps_t
erx_backend_vm_steps(erx_backend_vm_state_t from, erx_backend_vm_state_t to)
{
	return (vm_steps[from][to]);
}

int
erx_backend_vm_plan(const erx_backend_vm_table_t *table, const erx_backend_vm_request_t *request,
    erx_backend_vm_plan_t *plan)
{
	uint64_t end;
	int error;

	*plan = (erx_backend_vm_plan_t){ .op = request->op, .start = request->addr };
	switch (request->op) {
	case ERX_BACKEND_VM_RESERVE:
		return (plan_reserve(table, request, plan));
	case ERX_BACKEND_VM_COMMIT:
		plan->target = ERX_BACKEND_PAGE_RW;
		break;
	case ERX_BACKEND_VM_DECOMMIT:
	case ERX_BACKEND_VM_RELEASE:
		plan->target = ERX_BACKEND_PAGE_UNCOMMITTED;
		break;
	case ERX_BACKEND_VM_PROTECT:
		switch (request->prot) {
		case ERX_PROT_NONE:
			plan->target = ERX_BACKEND_PAGE_NONE;
			break;
		case ERX_PROT_R:
			plan->target = ERX_BACKEND_PAGE_R;
			break;
		case ERX_PROT_RW:
			plan->target = ERX_BACKEND_PAGE_RW;
			break;
		case ERX_PROT_RX:
			plan->target = ERX_BACKEND_PAGE_RX;
			break;
		default:
			return (ERX_EINVAL);
		}
		break;
	}

	error = range_decode(table, request->addr, request->size, &end);
	if (error != 0)
		return (error);
	plan->end = end;

	if (request->op == ERX_BACKEND_VM_PROTECT && !range_reserved(table, plan->start, end))
		return (ERX_ERANGE);
	if (request->op == ERX_BACKEND_VM_RELEASE && table->nranges == table->ranges_max &&
	    ranges_split(table, plan->start, end))
		return (ERX_ENOMEM);
	plan->pages_needed = count_takes(table, plan->start, end, plan->target);
	return (0);
}

int
erx_backend_vm_call(erx_backend_vm_table_t *table,
    const erx_backend_vm_effects_t *effects, const erx_backend_vm_request_t *request,
    uint64_t *reserved)
{
	erx_backend_vm_plan_t plan;
	int error;

	error = erx_backend_vm_plan(table, request, &plan);
	if (error != 0)
		return (error);
	if (plan.pages_needed > effects->free_pages())
		return (ERX_ENOMEM);
	apply_plan(table, effects, &plan);
	if (reserved != NULL)
		*reserved = plan.start;
	return (0);
}

static int
plan_reserve(const erx_backend_vm_table_t *table, const erx_backend_vm_request_t *request,
    erx_backend_vm_plan_t *plan)
{
	const uint32_t known = ERX_VM_FIXED | ERX_VM_NOREPLACE;
	const bool fixed = (request->flags & ERX_VM_FIXED) != 0;
	uint64_t start, end;
	int error;

	if ((request->flags & ~known) != 0 || ((request->flags & ERX_VM_NOREPLACE) != 0 && !fixed))
		return (ERX_EINVAL);

	if (fixed) {
		start = request->addr;
		error = range_decode(table, start, request->size, &end);
		if (error != 0)
			return (error);
		if ((request->flags & ERX_VM_NOREPLACE) != 0 && range_overlaps(table, start, end))
			return (ERX_EEXIST);
	} else {
		/* The address plays no part, so only the size has to decode. */
		error = range_decode(table, table->area_start, request->size, &end);
		if (error == ERX_ERANGE)
			return (ERX_ENOMEM);
		if (error != 0)
			return (error);
		error = find_free_range(table, request->size, &start);
		if (error != 0)
			return (error);
		end = start + request->size;
	}
	/* Removing what a fixed range replaces may split a run before adding one. */
	if (table->nranges + 1 > table->ranges_max)
		return (ERX_ENOMEM);
	*plan = (erx_backend_vm_plan_t){ .op = ERX_BACKEND_VM_RESERVE,
	    .target = ERX_BACKEND_PAGE_UNCOMMITTED, .start = start, .end = end };
	return (0);
}

static void
apply_plan(erx_backend_vm_table_t *table,
    const erx_backend_vm_effects_t *effects, const erx_backend_vm_plan_t *plan)
{
	pages_move(table, effects, plan->start, plan->end, plan->target);
	if (plan->op == ERX_BACKEND_VM_RESERVE || plan->op == ERX_BACKEND_VM_RELEASE)
		ranges_remove(table, plan->start, plan->end);
	if (plan->op == ERX_BACKEND_VM_RESERVE)
		ranges_add(table, plan->start, plan->end);
}

/* Each reserved page in [start, end), in ascending address order. */
static void
pages_move(erx_backend_vm_table_t *table,
    const erx_backend_vm_effects_t *effects, uint64_t start, uint64_t end,
    erx_backend_vm_state_t target)
{
	uint64_t cursor = start;

	for (size_t run = ranges_first_after(table, start);
	    run < table->nranges && table->ranges[run].start < end; run++) {
		const uint64_t run_end = table->ranges[run].end < end ? table->ranges[run].end : end;

		if (cursor < table->ranges[run].start)
			cursor = table->ranges[run].start;
		for (; cursor < run_end; cursor += ERX_PAGE_SIZE)
			page_move(table, effects, cursor, target);
	}
}

static void
page_move(erx_backend_vm_table_t *table,
    const erx_backend_vm_effects_t *effects, uint64_t addr, erx_backend_vm_state_t target)
{
	const size_t slot = page_find(table, addr);
	erx_backend_vm_page_t *page = &table->pages[slot];
	const erx_backend_vm_steps_t steps = erx_backend_vm_steps(page_state(page), target);
	uintptr_t window = (uintptr_t)(page->window_and_state & ~VM_PAGE_MASK);

	/* The plan counted this page, so the pool holds one for it. */
	if (steps.take)
		window = effects->take(addr);
	if (steps.drop != 0)
		effects->unmap(table->label, addr, steps.drop);
	if (steps.map != ERX_PROT_NONE)
		effects->map(table->label, window, addr, steps.map);
	if (steps.give_back) {
		page_forget(table, slot);
		effects->give(window, addr);
	} else if (steps.after != ERX_BACKEND_PAGE_UNCOMMITTED) {
		page->key = page_key(table, addr);
		page->window_and_state = (uint64_t)window | (uint64_t)steps.after;
	}
}

static uint64_t
page_key(const erx_backend_vm_table_t *table, uint64_t addr)
{
	return (addr | table->label);
}

/* Fibonacci hashing over page number and label: the product's upper half is the well-mixed part. */
static size_t
page_home(const erx_backend_vm_table_t *table, uint64_t key)
{
	const uint64_t mixed = (key / ERX_PAGE_SIZE) | ((key & VM_PAGE_MASK) << VM_LABEL_SHIFT);

	return ((size_t)((mixed * VM_HASH_MULTIPLIER) >> 32) & table->pages_mask);
}

static erx_backend_vm_state_t
page_state(const erx_backend_vm_page_t *page)
{
	if (page->key == 0)
		return (ERX_BACKEND_PAGE_UNCOMMITTED);
	return ((erx_backend_vm_state_t)(page->window_and_state & VM_STATE_MASK));
}

/* The slot holding the table's addr, or the empty slot where it would go. */
static size_t
page_find(const erx_backend_vm_table_t *table, uint64_t addr)
{
	const uint64_t key = page_key(table, addr);
	size_t slot = page_home(table, key);

	while (table->pages[slot].key != 0 && table->pages[slot].key != key)
		slot = (slot + 1) & table->pages_mask;
	return (slot);
}

/*
 * Empties a slot. Later entries of its probe run move back, so that no lookup
 * ever stops short at the new hole; there are no tombstones to accumulate.
 */
static void
page_forget(erx_backend_vm_table_t *table, size_t hole)
{
	const size_t mask = table->pages_mask;
	size_t next = hole;

	for (;;) {
		next = (next + 1) & mask;
		if (table->pages[next].key == 0)
			break;
		/* An entry may fill the hole unless its home lies after the hole. */
		if (((next - page_home(table, table->pages[next].key)) & mask) >= ((next - hole) & mask)) {
			table->pages[hole] = table->pages[next];
			hole = next;
		}
	}
	table->pages[hole] = (erx_backend_vm_page_t){ 0 };
}

/* How many pages moving the reserved pages of [start, end) to target takes. */
static uint64_t
count_takes(const erx_backend_vm_table_t *table, uint64_t start, uint64_t end,
    erx_backend_vm_state_t target)
{
	uint64_t cursor = start;
	uint64_t count = 0;

	for (size_t run = ranges_first_after(table, start);
	    run < table->nranges && table->ranges[run].start < end; run++) {
		const uint64_t run_end = table->ranges[run].end < end ? table->ranges[run].end : end;

		if (cursor < table->ranges[run].start)
			cursor = table->ranges[run].start;
		for (; cursor < run_end; cursor += ERX_PAGE_SIZE)
			if (erx_backend_vm_steps(page_state(&table->pages[page_find(table, cursor)]), target).take)
				count++;
	}
	return (count);
}

uintptr_t
erx_backend_vm_window(const erx_backend_vm_table_t *table, uint64_t addr)
{
	const erx_backend_vm_page_t *const page = &table->pages[page_find(table, addr)];

	if (page->key == 0)
		return (0);
	return ((uintptr_t)(page->window_and_state & ~VM_PAGE_MASK));
}

int
erx_backend_vm_map_object(const erx_backend_vm_table_t *table, const erx_backend_vm_table_t *object,
    const erx_backend_vm_effects_t *effects, uint64_t addr, uint64_t size, uint64_t offset, uint32_t prot)
{
	uint64_t end, first, object_end;
	int error;

	if ((prot != ERX_PROT_R && prot != ERX_PROT_RW && prot != ERX_PROT_RX) || (offset & VM_PAGE_MASK) != 0)
		return (ERX_EINVAL);
	error = range_decode(table, addr, size, &end);
	if (error != 0)
		return (error);
	if (!range_reserved(table, addr, end) || __builtin_add_overflow(object->area_start, offset, &first))
		return (ERX_ERANGE);
	/* Every page here would take a page to become read-write only if none is committed. */
	if (count_takes(table, addr, end, ERX_BACKEND_PAGE_RW) != size / ERX_PAGE_SIZE)
		return (ERX_EEXIST);
	error = range_decode(object, first, size, &object_end);
	if (error != 0)
		return (error);
	for (uint64_t done = 0; done < size; done += ERX_PAGE_SIZE)
		if (erx_backend_vm_window(object, first + done) == 0)
			return (ERX_ERANGE);
	/* A map only adds rights, and no record says what is mapped here: so it drops all first. */
	for (uint64_t done = 0; done < size; done += ERX_PAGE_SIZE) {
		effects->unmap(table->label, addr + done, VM_RIGHTS_ALL);
		effects->map(table->label, erx_backend_vm_window(object, first + done), addr + done, prot);
	}
	return (0);
}

void
erx_backend_vm_table_clear(erx_backend_vm_table_t *table, const erx_backend_vm_effects_t *effects)
{
	while (table->nranges > 0) {
		const erx_backend_vm_plan_t plan = { .op = ERX_BACKEND_VM_RELEASE, .target = ERX_BACKEND_PAGE_UNCOMMITTED,
		    .start = table->ranges[0].start, .end = table->ranges[0].end };

		apply_plan(table, effects, &plan);
	}
}

/* The area's lowest free range of this size. */
static int
find_free_range(const erx_backend_vm_table_t *table, uint64_t size, uint64_t *start)
{
	uint64_t gap = table->area_start;

	for (size_t run = 0; run < table->nranges; run++) {
		if (table->ranges[run].start - gap >= size) {
			*start = gap;
			return (0);
		}
		gap = table->ranges[run].end;
	}
	if (table->area_end - gap < size)
		return (ERX_ENOMEM);
	*start = gap;
	return (0);
}

/* The exclusive end of a range the area holds, with wrapping refused. */
static int
range_decode(const erx_backend_vm_table_t *table, uint64_t addr, uint64_t size, uint64_t *end)
{
	if ((addr & VM_PAGE_MASK) != 0 || (size & VM_PAGE_MASK) != 0 || size == 0)
		return (ERX_EINVAL);
	if (__builtin_add_overflow(addr, size, end) || addr < table->area_start ||
	    *end > table->area_end)
		return (ERX_ERANGE);
	return (0);
}

/* The first run that ends after addr, or nranges. */
static size_t
ranges_first_after(const erx_backend_vm_table_t *table, uint64_t addr)
{
	size_t low = 0;
	size_t high = table->nranges;

	while (low < high) {
		const size_t middle = low + (high - low) / 2;

		if (table->ranges[middle].end > addr)
			high = middle;
		else
			low = middle + 1;
	}
	return (low);
}

static bool
range_overlaps(const erx_backend_vm_table_t *table, uint64_t start, uint64_t end)
{
	const size_t run = ranges_first_after(table, start);

	return (run < table->nranges && table->ranges[run].start < end);
}

/* Adjacent runs merge, so a wholly reserved range lies within one run. */
static bool
range_reserved(const erx_backend_vm_table_t *table, uint64_t start, uint64_t end)
{
	const size_t run = ranges_first_after(table, start);

	return (run < table->nranges && table->ranges[run].start <= start &&
	    table->ranges[run].end >= end);
}

/* Whether removing [start, end) would leave a run on both its sides. */
static bool
ranges_split(const erx_backend_vm_table_t *table, uint64_t start, uint64_t end)
{
	const size_t run = ranges_first_after(table, start);

	return (run < table->nranges && table->ranges[run].start < start &&
	    table->ranges[run].end > end);
}

/* Adds a run that overlaps none, merging it with those it touches. */
static void
ranges_add(erx_backend_vm_table_t *table, uint64_t start, uint64_t end)
{
	const size_t after = ranges_first_after(table, start);
	const bool joins_before = after > 0 && table->ranges[after - 1].end == start;
	const bool joins_after = after < table->nranges && table->ranges[after].start == end;
	erx_backend_vm_range_t *ranges = table->ranges;

	if (joins_before && joins_after) {
		ranges[after - 1].end = ranges[after].end;
		bcopy(&ranges[after + 1], &ranges[after],
		    (table->nranges - after - 1) * sizeof(*ranges));
		table->nranges--;
	} else if (joins_before) {
		ranges[after - 1].end = end;
	} else if (joins_after) {
		ranges[after].start = start;
	} else {
		bcopy(&ranges[after], &ranges[after + 1],
		    (table->nranges - after) * sizeof(*ranges));
		ranges[after] = (erx_backend_vm_range_t){ .start = start, .end = end };
		table->nranges++;
	}
}

/* Removes every reserved address in [start, end). */
static void
ranges_remove(erx_backend_vm_table_t *table, uint64_t start, uint64_t end)
{
	erx_backend_vm_range_t *ranges = table->ranges;
	size_t first = ranges_first_after(table, start);
	size_t past;

	if (ranges_split(table, start, end)) {
		bcopy(&ranges[first], &ranges[first + 1],
		    (table->nranges - first) * sizeof(*ranges));
		ranges[first].end = start;
		ranges[first + 1].start = end;
		table->nranges++;
		return;
	}
	if (first < table->nranges && ranges[first].start < start) {
		ranges[first].end = start;
		first++;
	}
	past = first;
	while (past < table->nranges && ranges[past].end <= end)
		past++;
	if (past < table->nranges && ranges[past].start < end)
		ranges[past].start = end;
	bcopy(&ranges[past], &ranges[first], (table->nranges - past) * sizeof(*ranges));
	table->nranges -= past - first;
}
