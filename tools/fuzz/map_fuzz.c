/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the mapping-record core with the arguments a domain controls: the
 * addresses, sizes, flags, protections, offsets and base of its range calls,
 * and the allocation failures its budget can cause, decoded from the input.
 * It aborts when an invariant breaks:
 *
 *   erx_map_check holds after every command: the tree is balanced, its
 *   summaries are right, its records do not overlap and lie in the user range,
 *   and each record's fields suit its kind, its protection beneath its ceiling
 *   and never writable with executable;
 *   a part changes no page outside its range, and a page in its range keeps
 *   its ceiling and stays mapped: K4, by a shadow of every page;
 *   a refused plan, a dropped plan and a short apply leave the tree unchanged,
 *   by a shadow of every page;
 *   a page that stays memory keeps its object and offset, and a page committed
 *   takes its own number as its offset (K5);
 *   a part edits at most three records, takes at most two spares, charges at
 *   most ERX_RANGE_PART_PAGES and only for a reservation it commits, and moves
 *   forward;
 *   only private memory is trimmed (K5), and what it trims is exactly the
 *   pages, object and offsets the part's range mapped;
 *   after a release no page of its range is mapped, the pages outside it are
 *   unchanged, and the records that left hold exactly the pages it mapped;
 *   a fixed insert covers exactly its range, and a placed one lies below the
 *   base or at its free hint;
 *   a detached subtree's records are as many as it says, in address order.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/map.h"

#define SHADOW_LOW	16u
#define SHADOW_PAGES	256u
#define SHADOW_HIGH	(SHADOW_LOW + SHADOW_PAGES)
#define OBJECTS		4u

typedef struct fuzz_input fuzz_input_t;
typedef struct fuzz_page fuzz_page_t;

/* The most parts of one bounded call an input runs. */
#define PARTS_MAX	128u

struct fuzz_input {
	const uint8_t	*bytes;
	size_t		 size;
};

/* The fact a page's record states, in a form a memcmp compares. */
struct fuzz_page {
	uint64_t	 offset;
	uintptr_t	 object;
	uint32_t	 kind;
	uint32_t	 prot;
	uint32_t	 ceiling;
	uint32_t	 flags;
};

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static char objects[OBJECTS];
static erx_map_tree_t tree;
static uint64_t drained_pages;	/* what the last apply's detached records held */

static uint8_t
take_u8(fuzz_input_t *input)
{
	uint8_t value = 0;

	if (input->size > 0) {
		value = *input->bytes++;
		input->size--;
	}
	return (value);
}

static uint64_t
take_u64(fuzz_input_t *input)
{
	uint64_t value = 0;

	for (int i = 0; i < 8; i++)
		value = value << 8 | take_u8(input);
	return (value);
}

/* A protection, sometimes with a bit no record's field could hold. */
static uint32_t
take_prot(fuzz_input_t *input)
{
	uint32_t bits = take_u8(input) & 0x1f;

	return ((bits & 0x10) != 0 ? (bits & 0xf) | 0x100 : bits);
}

static erx_memobj_t *
take_object(fuzz_input_t *input)
{
	return ((erx_memobj_t *)(void *)&objects[take_u8(input) % OBJECTS]);
}

/* A page near the shadow window, or now and then any 64-bit number. */
static uint64_t
take_addr(fuzz_input_t *input)
{
	uint8_t form = take_u8(input);

	if (form >= 0xf0)
		return (take_u64(input));
	return ((SHADOW_LOW + (uint64_t)(take_u8(input)) +
	    (form & 0x3)) << 12);
}

static uint64_t
take_size(fuzz_input_t *input)
{
	uint8_t form = take_u8(input);

	if (form >= 0xf0)
		return (take_u64(input));
	return ((uint64_t)(1 + take_u8(input) % (form < 0x80 ? 8 : 128)) << 12);
}

static erx_mapping_t *
record_new(void)
{
	void *record = NULL;

	if (posix_memalign(&record, erx_map_record_align(),
	    erx_map_record_size()) != 0)
		abort();
	return (record);
}

static void
take_shadow(fuzz_page_t *shadow)
{
	const char *problem = erx_map_check(&tree);

	if (problem != NULL)
		abort();
	memset(shadow, 0, SHADOW_PAGES * sizeof(*shadow));
	for (uint32_t i = 0; i < SHADOW_PAGES; i++) {
		const erx_mapping_t *record = erx_map_lookup(&tree,
		    (erx_uvpn_t){ SHADOW_LOW + i });
		erx_mapping_view_t view;

		if (record == NULL)
			continue;
		view = erx_map_view(record);
		shadow[i].offset = view.object == NULL ? 0 : view.offset +
		    (SHADOW_LOW + i - view.start.raw);
		shadow[i].object = (uintptr_t)view.object;
		shadow[i].kind = view.kind;
		shadow[i].prot = view.prot;
		shadow[i].ceiling = view.ceiling;
		shadow[i].flags = view.flags;
	}
}

static void
drain(erx_map_detached_t *detached)
{
	erx_mapping_t *record;
	uint64_t previous = 0;
	uint32_t expected = erx_map_detached_count(detached), taken = 0;

	drained_pages = 0;
	while ((record = erx_map_detached_next(detached)) != NULL) {
		erx_mapping_view_t view = erx_map_view(record);

		if (view.start.raw < previous || view.start.raw >= view.end.raw)
			abort();
		previous = view.end.raw;
		drained_pages += view.end.raw - view.start.raw;
		free(record);
		taken++;
	}
	if (taken != expected)
		abort();
}

static void
require_same_shadow(const fuzz_page_t *before, fuzz_page_t *after)
{
	take_shadow(after);
	if (memcmp(before, after, SHADOW_PAGES * sizeof(*after)) != 0)
		abort();
}

/*
 * Applies a plan, or fails its allocation as the input says, and returns
 * whether it applied. A failure changes nothing and reports no effect. Otherwise
 * it hands back what the apply reported; a plan's report is only a report, so
 * writing it changes nothing.
 */
static bool
apply(fuzz_input_t *input, erx_map_plan_t *plan, erx_map_result_t *effects)
{
	static fuzz_page_t before[SHADOW_PAGES], after[SHADOW_PAGES];
	erx_mapping_t *spares[ERX_MAP_SPARES_MAX] = { NULL };
	erx_map_result_t result;
	uint8_t form = take_u8(input);
	uint32_t want = plan->nspares;
	int status;

	if (want > ERX_MAP_SPARES_MAX)
		abort();
	if (form >= 0xf8) {
		take_shadow(before);
		if (want == 0)
			return (false);
		want--;
		for (uint32_t i = 0; i < want; i++)
			spares[i] = record_new();
		if (erx_map_apply(&tree, plan, spares, want, &result) !=
		    ERX_ENOMEM)
			abort();
		if (result.clears || result.trim_pages != 0 ||
		    result.trim_object != NULL || result.trim_offset != 0)
			abort();
		for (uint32_t i = 0; i < want; i++)
			free(spares[i]);
		take_shadow(after);
		if (memcmp(before, after, sizeof(before)) != 0)
			abort();
		return (false);
	}
	for (uint32_t i = 0; i < want; i++)
		spares[i] = record_new();
	plan->nspares = form;
	status = erx_map_apply(&tree, plan, spares, want, &result);
	if (status != ERX_OK)
		abort();
	*effects = result;
	for (uint32_t i = 0; i < result.nfreed; i++)
		free(result.freed[i]);
	drain(&result.detached);
	if (erx_map_apply(&tree, plan, spares, want, &result) != ERX_EINVAL)
		abort();
	return (true);
}

static void
fuzz_insert(fuzz_input_t *input)
{
	static fuzz_page_t before[SHADOW_PAGES], after[SHADOW_PAGES];
	erx_map_insert_t request = { .object = NULL };
	erx_map_plan_t plan;
	erx_map_result_t effects;
	bool takes_ceiling;
	uint8_t form = take_u8(input);
	int status;

	request.addr = take_addr(input);
	request.size = take_size(input);
	request.vm_flags = take_u8(input) % 8;
	request.base.raw = form < 0xc0 ? SHADOW_LOW + take_u8(input) :
	    take_u64(input);
	request.kind = (erx_map_kind_t)(1 + take_u8(input) % 6);
	request.offset = take_u8(input) < 0xf0 ? take_u8(input) : take_u64(input);
	request.object_pages = take_u8(input) < 0xf0 ? UINT32_MAX :
	    take_u64(input);
	request.prot = take_prot(input);
	request.rights = take_u8(input) & 0xf;
	request.object_ceiling = take_u8(input) & 0xf;
	request.flags = take_u8(input) < 0x80 ? 0 : 1;
	takes_ceiling = request.kind == ERX_MAP_OBJECT ||
	    request.kind == ERX_MAP_DELETED;
	if (!takes_ceiling && form < 0xf0) {
		request.rights = 0;
		request.object_ceiling = 0;
	}
	if (request.kind == ERX_MAP_PRIVATE || request.kind == ERX_MAP_OBJECT)
		request.object = take_object(input);
	if (request.kind != ERX_MAP_OBJECT && form < 0xf0)
		request.offset = 0;
	take_shadow(before);
	status = erx_map_plan_insert(&tree, &request, &plan);
	if (status != ERX_OK) {
		take_shadow(after);
		if (memcmp(before, after, sizeof(before)) != 0)
			abort();
		return;
	}
	if (plan.range.end.raw - plan.range.start.raw !=
	    request.size >> 12)
		abort();
	if ((request.vm_flags & ERX_VM_FIXED) != 0 &&
	    plan.range.start.raw != request.addr >> 12)
		abort();
	/* A placement ends at or below the base, or takes the free range hinted. */
	if ((request.vm_flags & ERX_VM_FIXED) == 0 &&
	    plan.range.end.raw > request.base.raw &&
	    plan.range.start.raw != request.addr >> 12)
		abort();
	if ((request.prot & ~UINT32_C(0xf)) != 0)
		abort();
	if (apply(input, &plan, &effects)) {
		const erx_mapping_t *record = erx_map_lookup(&tree,
		    plan.range.start);
		erx_mapping_view_t view;

		if (record == NULL)
			abort();
		view = erx_map_view(record);
		if (view.start.raw != plan.range.start.raw ||
		    view.end.raw != plan.range.end.raw ||
		    view.kind != request.kind)
			abort();
		if (view.ceiling != (takes_ceiling ? (request.rights &
		    request.object_ceiling) : (uint32_t)ERX_PROT_RW))
			abort();
		if (view.kind == ERX_MAP_PRIVATE &&
		    view.offset != view.start.raw)
			abort();
	}
}

static void
fuzz_release(fuzz_input_t *input)
{
	static fuzz_page_t before[SHADOW_PAGES], after[SHADOW_PAGES];
	erx_map_plan_t plan;
	erx_map_range_t range;
	erx_map_result_t effects;
	uint64_t addr, mapped = 0, size;

	addr = take_addr(input);
	size = take_size(input);
	if (erx_map_range_decode(&tree, addr, size, &range) != ERX_OK)
		return;
	take_shadow(before);
	if (erx_map_plan_release(&tree, &range, &plan) != ERX_OK) {
		require_same_shadow(before, after);
		return;
	}
	drained_pages = 0;
	if (!apply(input, &plan, &effects)) {
		require_same_shadow(before, after);
		return;
	}
	/* No promise of a table survives, so every table it covers goes whole. */
	if (erx_map_span_touched(&tree, range.start, range.end))
		abort();
	take_shadow(after);
	for (uint64_t i = 0; i < SHADOW_PAGES; i++) {
		uint64_t page = SHADOW_LOW + i;

		if (page >= range.start.raw && page < range.end.raw) {
			mapped += before[i].kind != 0;
			if (after[i].kind != 0)
				abort();
		} else if (memcmp(&before[i], &after[i], sizeof(before[i])) != 0) {
			abort();
		}
	}
	if (range.end.raw <= SHADOW_HIGH && mapped != drained_pages)
		abort();
}

/* A page of a part's range, against what it was. */
static void
check_part_page(const erx_map_part_request_t *request, uint64_t page,
    const fuzz_page_t *before, const fuzz_page_t *after)
{
	if (before->ceiling != after->ceiling ||
	    (before->kind == 0) != (after->kind == 0))
		abort();
	/* Commit and decommit are private memory's calls. */
	if (request->op != ERX_MAP_PROTECT && (before->kind == ERX_MAP_OBJECT ||
	    before->kind == ERX_MAP_DELETED))
		abort();
	if (before->kind == after->kind && (before->object != after->object ||
	    before->offset != after->offset))
		abort();
	if (before->kind == ERX_MAP_RESERVED && after->kind == ERX_MAP_PRIVATE &&
	    (after->offset != page ||
	    after->object != (uintptr_t)request->object))
		abort();
}

/* What a planned part says it will charge, against the record it acts on. */
static void
check_part_plan(const erx_map_plan_t *plan, const erx_mapping_view_t *view)
{
	if (plan->nspares > 2 || plan->edits > 3 ||
	    plan->charge_pages > ERX_RANGE_PART_PAGES)
		abort();
	if (plan->charge_pages > 0 && view->kind != ERX_MAP_RESERVED)
		abort();
}

/* What an applied part says it trimmed, against the record it acted on. */
static void
check_part_effects(const erx_map_plan_t *plan, const erx_map_result_t *effects,
    const erx_mapping_view_t *view, const fuzz_page_t *before)
{
	if (effects->trim_pages == 0)
		return;
	if (view->kind != ERX_MAP_PRIVATE || !effects->clears ||
	    effects->trim_pages != plan->range.end.raw - plan->range.start.raw ||
	    effects->trim_object != view->object)
		abort();
	if (plan->range.start.raw >= SHADOW_LOW &&
	    plan->range.start.raw < SHADOW_HIGH &&
	    before[plan->range.start.raw - SHADOW_LOW].offset !=
	    effects->trim_offset)
		abort();
}

/* Runs a whole bounded call, a part at a time. */
static void
fuzz_part(fuzz_input_t *input)
{
	static fuzz_page_t before[SHADOW_PAGES], after[SHADOW_PAGES];
	erx_map_part_request_t request = { .object = NULL };
	uint64_t addr, size;

	request.op = (erx_map_op_t)(1 + take_u8(input) % 4);
	request.object = take_object(input);
	request.prot = take_prot(input);
	addr = take_addr(input);
	size = take_size(input);
	if (erx_map_range_decode(&tree, addr, size, &request.range) != ERX_OK)
		return;
	request.cursor = request.range.start;
	/* A huge commit takes 2^46 parts, and these show all that its parts do. */
	for (uint32_t parts = 0; parts < PARTS_MAX; parts++) {
		erx_map_plan_t plan;
		erx_map_result_t effects;
		const erx_mapping_t *met;
		erx_mapping_view_t view = { .kind = ERX_MAP_RESERVED };

		take_shadow(before);
		if (erx_map_plan_part(&tree, &request, &plan) != ERX_OK) {
			require_same_shadow(before, after);
			return;
		}
		met = erx_map_lookup(&tree, plan.range.start);
		if (met != NULL) {
			view = erx_map_view(met);
			check_part_plan(&plan, &view);
		}
		if (plan.next.raw <= request.cursor.raw && !plan.done)
			abort();
		if (!apply(input, &plan, &effects)) {
			require_same_shadow(before, after);
			return;
		}
		check_part_effects(&plan, &effects, &view, before);
		/* No promise of a table survives a decommit, so a covered table goes. */
		if (request.op == ERX_MAP_DECOMMIT &&
		    erx_map_span_touched(&tree, plan.range.start, plan.range.end))
			abort();
		take_shadow(after);
		for (uint64_t i = 0; i < SHADOW_PAGES; i++) {
			uint64_t page = SHADOW_LOW + i;

			if (page >= plan.range.start.raw &&
			    page < plan.range.end.raw)
				check_part_page(&request, page, &before[i],
				    &after[i]);
			else if (memcmp(&before[i], &after[i],
			    sizeof(before[i])) != 0)
				abort();
		}
		if (plan.done)
			return;
		request.cursor = plan.next;
	}
}

static void
fuzz_deleted(fuzz_input_t *input)
{
	erx_mapping_t *record = erx_map_first_from(&tree,
	    (erx_uvpn_t){ SHADOW_LOW + take_u8(input) });
	erx_mapping_view_t view;
	int status;

	if (record == NULL)
		return;
	view = erx_map_view(record);
	status = erx_map_mark_deleted(&tree, record);
	if ((status == ERX_OK) != (view.kind == ERX_MAP_OBJECT))
		abort();
}

static void
fuzz_edges(fuzz_input_t *input)
{
	erx_map_edges_t edges;
	erx_map_range_t range;
	uint64_t addr, size;
	erx_npages_t span;

	addr = take_addr(input);
	size = take_size(input);
	span = take_u8(input) < 0xf0 ? 1u << (take_u8(input) % 20) : take_u64(input);
	if (erx_map_range_decode(&tree, addr, size, &range) != ERX_OK ||
	    erx_map_edges(&tree, &range, span, &edges) != ERX_OK)
		return;
	if (edges.nedges > 2)
		abort();
	for (uint32_t i = 0; i < edges.nedges; i++)
		if (edges.edge[i].keep != erx_map_span_touched(&tree,
		    edges.edge[i].start,
		    (erx_uvpn_t){ edges.edge[i].start.raw + span }))
			abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t input = { .bytes = data, .size = size };
	erx_map_detached_t detached;
	erx_mapping_t *record;
	uint32_t limit = 256;

	/* A window the shadow covers, the end of the 52-bit space, or wild. */
	switch (take_u8(&input) & 3) {
	case 0:
		if (erx_map_tree_init(&tree, (erx_uvpn_t){ SHADOW_HIGH }) !=
		    ERX_OK)
			abort();
		break;
	case 1:
		if (erx_map_tree_init(&tree,
		    (erx_uvpn_t){ UINT64_C(1) << 52 }) != ERX_OK)
			abort();
		break;
	default:
		if (erx_map_tree_init(&tree, (erx_uvpn_t){ take_u64(&input) }) !=
		    ERX_OK && erx_map_tree_init(&tree,
		    (erx_uvpn_t){ SHADOW_HIGH }) != ERX_OK)
			abort();
		break;
	}
	while (input.size > 0 && limit-- > 0) {
		switch (take_u8(&input) % 5) {
		case 0:
			fuzz_insert(&input);
			break;
		case 1:
			fuzz_release(&input);
			break;
		case 2:
			fuzz_part(&input);
			break;
		case 3:
			fuzz_deleted(&input);
			break;
		default:
			fuzz_edges(&input);
			break;
		}
		if (erx_map_check(&tree) != NULL)
			abort();
	}
	erx_map_take_all(&tree, &detached);
	while ((record = erx_map_detached_next(&detached)) != NULL)
		free(record);
	return (0);
}
