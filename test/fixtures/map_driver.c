/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs a command script through the mapping-record core's public interface
 * and prints every plan, every apply's result and the whole tree, for
 * test/fixtures/map_model.rb to predict. Records are real allocations, freed
 * as soon as the core gives them up, so AddressSanitizer sees any later use.
 *
 * After every command the driver stops the run if the core's own invariants
 * fail, if the records it holds are not the records in the tree plus none
 * left over, or if a stand-in for each object's reverse map, kept from the
 * apply results alone, disagrees with the object records in the tree.
 *
 * It stops too if a refused plan reports anything, if a refused apply reports
 * an effect, or if a decommit or a release leaves a promise of a table in its
 * range: that is what lets the caller detach every table such a range covers
 * whole.
 *
 * Numbers are decimal or 0x hex. An object is an index, 0 for none. MODE says
 * how the caller's allocation goes: ok; short hands over one record too few,
 * so the core refuses; drop gives up without an apply.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "erx/map.h"

#define OBJECTS_MAX	8

static erx_map_tree_t tree;
static char objects[OBJECTS_MAX];	/* each one's address is its handle */
static int64_t reverse_map[OBJECTS_MAX];
static size_t live;			/* records allocated and not yet freed */
static int quiet;

static void
fail(const char *what)
{
	fprintf(stderr, "map-driver: %s\n", what);
	exit(2);
}

static uint64_t
number(const char *text)
{
	return (strtoull(text, NULL, 0));
}

static erx_memobj_t *
object_of(uint64_t index)
{
	return (index == 0 ? NULL : (erx_memobj_t *)(void *)&objects[index]);
}

static int
index_of(const erx_memobj_t *object)
{
	return (object == NULL ? 0 : (int)((const char *)(const void *)object -
	    objects));
}

static erx_mapping_t *
record_new(void)
{
	void *record = NULL;

	if (posix_memalign(&record, erx_map_record_align(),
	    erx_map_record_size()) != 0)
		fail("out of host memory");
	live++;
	return (record);
}

static void
record_free(erx_mapping_t *record)
{
	free(record);
	live--;
}

static void
print_record(const erx_mapping_view_t *view)
{
	printf(" %" PRIu64 ",%" PRIu64 ",%d,%d,%" PRIu64 ",%d,%d,%d",
	    view->start.raw, view->end.raw, (int)view->kind,
	    index_of(view->object), view->offset, view->prot, view->ceiling,
	    view->flags);
}

/* Every object record in the tree must be on the stand-in reverse map. */
static void
check_tree(void)
{
	const erx_mapping_t *record;
	erx_uvpn_t cursor = { 0 };
	int64_t found[OBJECTS_MAX] = { 0 };
	size_t count = 0;
	const char *problem = erx_map_check(&tree);

	if (problem != NULL)
		fail(problem);
	while ((record = erx_map_first_from(&tree, cursor)) != NULL) {
		erx_mapping_view_t view = erx_map_view(record);

		if (view.kind == ERX_MAP_OBJECT)
			found[index_of(view.object)]++;
		cursor = view.end;
		count++;
	}
	if (count != erx_map_count(&tree))
		fail("the tree's count is not its records");
	if (count != live)
		fail("a record was lost or kept");
	if (memcmp(found, reverse_map, sizeof(found)) != 0)
		fail("an apply's result disagrees with the object records");
}

static void
print_tree(void)
{
	const erx_mapping_t *record;
	erx_uvpn_t cursor = { 0 };

	check_tree();
	printf("T %" PRIu32, erx_map_count(&tree));
	if (!quiet) {
		while ((record = erx_map_first_from(&tree, cursor)) != NULL) {
			erx_mapping_view_t view = erx_map_view(record);

			print_record(&view);
			cursor = view.end;
		}
	}
	printf("\n");
}

/* A refused plan must give its caller nothing to act on. */
static void
check_refused_plan(const erx_map_plan_t *plan)
{
	if (plan->nspares != 0 || plan->edits != 0 || plan->done ||
	    plan->range.start.raw != 0 || plan->range.end.raw != 0 ||
	    plan->next.raw != 0 || plan->charge_pages != 0)
		fail("a refused plan reports something");
}

static void
print_plan(const char *name, int status, const erx_map_plan_t *plan)
{
	if (status != ERX_OK) {
		check_refused_plan(plan);
		printf("= %s %d\n", name, status);
		return;
	}
	printf("= %s 0 %" PRIu32 " %" PRIu64 " %" PRIu64 " %" PRIu64
	    " %d %" PRIu64 "\n", name, plan->nspares, plan->range.start.raw,
	    plan->range.end.raw, plan->next.raw, plan->done ? 1 : 0,
	    plan->charge_pages);
}

/*
 * After a decommit's part, a release or a reservation's insert, nothing that
 * holds a promise of a table
 * touches the range, so every table it covers completely can be detached whole.
 */
static void
check_no_promise(const erx_map_plan_t *plan)
{
	if (erx_map_span_touched(&tree, plan->range.start, plan->range.end))
		fail("a promise survives in a decommitted or released range");
}

/* Takes a detached subtree's records, in order, printing and freeing each. */
static void
drain(erx_map_detached_t *detached)
{
	erx_mapping_t *record;
	uint32_t expected = erx_map_detached_count(detached), taken = 0;

	printf("D %" PRIu32, expected);
	while ((record = erx_map_detached_next(detached)) != NULL) {
		erx_mapping_view_t view = erx_map_view(record);

		print_record(&view);
		if (view.kind == ERX_MAP_OBJECT)
			reverse_map[index_of(view.object)]--;
		record_free(record);
		taken++;
	}
	printf("\n");
	if (taken != expected || erx_map_detached_count(detached) != 0)
		fail("a detached subtree's count is not its records");
}

/*
 * Runs one planned edit under MODE. Returns whether it applied. "A status
 * added freed inserted", "X clears trim_pages trim_object trim_offset" and the
 * detached records follow it.
 */
static bool
apply(erx_map_plan_t *plan, const char *mode)
{
	erx_mapping_t *spares[ERX_MAP_SPARES_MAX + 1];
	erx_map_result_t result;
	uint32_t want = plan->nspares;
	int status;

	if (want > ERX_MAP_SPARES_MAX)
		fail("a plan asks for too many spares");
	if (strcmp(mode, "drop") == 0) {
		printf("A dropped\n");
		return (false);
	}
	if (strcmp(mode, "short") == 0 && want > 0)
		want--;
	for (uint32_t i = 0; i < want; i++)
		spares[i] = record_new();
	status = erx_map_apply(&tree, plan, spares, want, &result);
	if (status != ERX_OK) {
		for (uint32_t i = 0; i < want; i++)
			record_free(spares[i]);
		if (result.clears || result.trim_pages != 0 ||
		    result.trim_object != NULL || result.trim_offset != 0)
			fail("a refused apply reports an effect");
		printf("A %d\n", status);
		return (false);
	}
	if (result.nadded > ERX_MAP_SPARES_MAX ||
	    result.nfreed > ERX_MAP_FREED_MAX)
		fail("an apply reports too many records");
	for (uint32_t i = 0; i < result.nadded; i++) {
		erx_mapping_view_t view = erx_map_view(result.added[i]);

		if (view.kind != ERX_MAP_OBJECT)
			fail("an added record is not an object's");
		reverse_map[index_of(view.object)]++;
	}
	for (uint32_t i = 0; i < result.nfreed; i++) {
		erx_mapping_view_t view = erx_map_view(result.freed[i]);

		if (view.kind == ERX_MAP_OBJECT)
			reverse_map[index_of(view.object)]--;
		record_free(result.freed[i]);
	}
	printf("A 0 %" PRIu32 " %" PRIu32 " %" PRIu64 "\n", result.nadded,
	    result.nfreed, result.inserted == NULL ? 0 :
	    erx_map_view(result.inserted).start.raw);
	printf("X %d %" PRIu64 " %d %" PRIu64 "\n", result.clears ? 1 : 0,
	    result.trim_pages, index_of(result.trim_object), result.trim_offset);
	if (erx_map_detached_count(&result.detached) > 0)
		drain(&result.detached);
	return (true);
}

static void
tree_empty(void)
{
	erx_map_detached_t detached;
	erx_mapping_t *record;

	erx_map_take_all(&tree, &detached);
	while ((record = erx_map_detached_next(&detached)) != NULL)
		record_free(record);
	bzero(reverse_map, sizeof(reverse_map));
}

static void
command_init(uint64_t end)
{
	tree_empty();
	if (erx_map_tree_init(&tree, (erx_uvpn_t){ end }) != ERX_OK) {
		printf("= init %d\n", ERX_EINVAL);
		if (erx_map_tree_init(&tree, (erx_uvpn_t){ 1024 }) != ERX_OK)
			fail("no tree");
		return;
	}
	printf("= init 0\n");
}

/*
 * insert ADDR SIZE VMFLAGS BASE KIND OBJECT OFFSET PAGES PROT RIGHTS OBJCEILING
 * FLAGS MODE
 */
static void
command_insert(char **argv)
{
	erx_map_plan_t plan;
	erx_map_insert_t request = {
		.addr = number(argv[1]), .size = number(argv[2]),
		.vm_flags = (uint32_t)number(argv[3]),
		.base.raw = number(argv[4]),
		.kind = (erx_map_kind_t)number(argv[5]),
		.object = object_of(number(argv[6])),
		.offset = number(argv[7]), .object_pages = number(argv[8]),
		.prot = (uint32_t)number(argv[9]),
		.rights = (uint32_t)number(argv[10]),
		.object_ceiling = (uint32_t)number(argv[11]),
		.flags = (uint32_t)number(argv[12]) };
	int status = erx_map_plan_insert(&tree, &request, &plan);

	print_plan("insert", status, &plan);
	if (status == ERX_OK && apply(&plan, argv[13]) &&
	    request.kind == ERX_MAP_RESERVED)
		check_no_promise(&plan);
	print_tree();
}

/* release ADDR SIZE MODE */
static void
command_release(char **argv)
{
	erx_map_plan_t plan = { .nspares = 0 };
	erx_map_range_t range;
	int status = erx_map_range_decode(&tree, number(argv[1]),
	    number(argv[2]), &range);

	if (status == ERX_OK)
		status = erx_map_plan_release(&tree, &range, &plan);
	print_plan("release", status, &plan);
	if (status == ERX_OK && apply(&plan, argv[3]))
		check_no_promise(&plan);
	print_tree();
}

/*
 * part OP ADDR SIZE OBJECT PROT MODE WHEN: the whole bounded call, a part at a
 * time. MODE applies to the part numbered WHEN, and every other part is ok, so
 * a failure at any part leaves those before it applied. A part edits at most
 * three records and takes at most two spares.
 */
static void
command_part(char **argv)
{
	erx_map_part_request_t request = {
		.op = (erx_map_op_t)number(argv[1]),
		.object = object_of(number(argv[4])),
		.prot = (uint32_t)number(argv[5]) };
	uint64_t when = number(argv[7]);
	int status = erx_map_range_decode(&tree, number(argv[2]),
	    number(argv[3]), &request.range);
	uint64_t part = 0;

	if (status != ERX_OK) {
		printf("= part %d\n", status);
		print_tree();
		return;
	}
	request.cursor = request.range.start;
	for (;;) {
		erx_map_plan_t plan;

		status = erx_map_plan_part(&tree, &request, &plan);
		print_plan("part", status, &plan);
		if (status != ERX_OK)
			break;
		if (plan.nspares > 2 || plan.edits > 3)
			fail("a part edits too much");
		if (plan.charge_pages > ERX_RANGE_PART_PAGES)
			fail("a part charges too much");
		if (!apply(&plan, part == when ? argv[6] : "ok"))
			break;
		if (request.op == ERX_MAP_DECOMMIT)
			check_no_promise(&plan);
		if (plan.done)
			break;
		request.cursor = plan.next;
		part++;
	}
	print_tree();
}

/*
 * rawrelease START END and rawpart OP START END CURSOR: requests that no decode
 * checked, to the planners that must refuse them. Each prints its status alone,
 * and neither applies.
 */
static void
command_raw_release(char **argv)
{
	erx_map_plan_t plan;
	erx_map_range_t range = { .start.raw = number(argv[1]),
	    .end.raw = number(argv[2]) };

	int status = erx_map_plan_release(&tree, &range, &plan);

	check_refused_plan(&plan);
	printf("= raw %d\n", status);
}

static void
command_raw_part(char **argv)
{
	erx_map_plan_t plan;
	erx_map_part_request_t request = {
		.op = (erx_map_op_t)number(argv[1]),
		.range.start.raw = number(argv[2]),
		.range.end.raw = number(argv[3]),
		.cursor.raw = number(argv[4]),
		.object = object_of(1) };

	int status = erx_map_plan_part(&tree, &request, &plan);

	check_refused_plan(&plan);
	printf("= raw %d\n", status);
}

/*
 * markstale ADDR SIZE PAGE: a plan of a release, then a deletion of the object
 * at PAGE, then the plan's apply. It refuses, so a plan cannot write a deleted
 * object's handle back into a record.
 */
static void
command_mark_stale(char **argv)
{
	erx_map_plan_t plan;
	erx_map_range_t range;
	erx_map_result_t result;
	erx_mapping_t *record = erx_map_lookup(&tree,
	    (erx_uvpn_t){ number(argv[3]) });
	erx_mapping_view_t view;

	if (record == NULL ||
	    erx_map_range_decode(&tree, number(argv[1]), number(argv[2]),
	    &range) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &plan) != ERX_OK)
		fail("markstale: no plan");
	view = erx_map_view(record);
	if (erx_map_mark_deleted(&tree, record) != ERX_OK)
		fail("markstale: not an object's record");
	reverse_map[index_of(view.object)]--;
	printf("= markstale %d\n", erx_map_apply(&tree, &plan, NULL, 0, &result));
	print_tree();
}

/* othertree ADDR SIZE: a plan of this tree, applied to another. */
static void
command_other_tree(char **argv)
{
	erx_map_tree_t other;
	erx_map_plan_t plan;
	erx_map_range_t range;
	erx_map_result_t result;

	if (erx_map_tree_init(&other, (erx_uvpn_t){ 1024 }) != ERX_OK ||
	    erx_map_range_decode(&tree, number(argv[1]), number(argv[2]),
	    &range) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &plan) != ERX_OK)
		fail("othertree: no plan");
	printf("= othertree %d\n", erx_map_apply(&other, &plan, NULL, 0, &result));
	print_tree();
}

/*
 * lowspares ADDR SIZE: a release that needs spares, whose report a caller
 * overwrites to say it needs none. The report is only a report, so the apply
 * still counts what it will write and refuses, reading no record it was not
 * given.
 */
static void
command_low_spares(char **argv)
{
	erx_map_plan_t plan;
	erx_map_range_t range;
	erx_map_result_t result;

	if (erx_map_range_decode(&tree, number(argv[1]), number(argv[2]),
	    &range) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &plan) != ERX_OK ||
	    plan.nspares == 0)
		fail("lowspares: no plan that needs spares");
	plan.nspares = 0;
	printf("= lowspares %d\n", erx_map_apply(&tree, &plan, NULL, 0, &result));
	print_tree();
}

/* kremove PAGE MODE */
static void
command_kremove(char **argv)
{
	erx_map_plan_t plan;
	int status = erx_map_plan_remove_kernel(&tree,
	    (erx_uvpn_t){ number(argv[1]) }, &plan);

	print_plan("kremove", status, &plan);
	if (status == ERX_OK)
		apply(&plan, argv[2]);
	print_tree();
}

/* edges ADDR SIZE SPAN */
static void
command_edges(char **argv)
{
	erx_map_edges_t edges;
	erx_map_range_t range;
	int status = erx_map_range_decode(&tree, number(argv[1]),
	    number(argv[2]), &range);

	if (status == ERX_OK)
		status = erx_map_edges(&tree, &range, number(argv[3]), &edges);
	if (status != ERX_OK) {
		printf("E %d\n", status);
		return;
	}
	printf("E 0");
	for (uint32_t i = 0; i < edges.nedges; i++)
		printf(" %" PRIu64 ":%d", edges.edge[i].start.raw,
		    edges.edge[i].keep ? 1 : 0);
	printf("\n");
}

/* deleted PAGE: the object of the record at this page is deleted. */
static void
command_deleted(uint64_t page)
{
	erx_mapping_t *record = erx_map_lookup(&tree, (erx_uvpn_t){ page });
	erx_mapping_view_t view;
	int status;

	if (record == NULL)
		fail("deleted: no record");
	view = erx_map_view(record);
	status = erx_map_mark_deleted(&tree, record);
	if (status == ERX_OK)
		reverse_map[index_of(view.object)]--;
	printf("= deleted %d\n", status);
	print_tree();
}

/*
 * deadrecord ADDR SIZE: a deletion that reaches a record after a release took
 * it out of the tree finds it gone, and marks nothing.
 */
static void
command_dead_record(char **argv)
{
	erx_map_plan_t plan;
	erx_map_range_t range;
	erx_map_result_t result;
	erx_mapping_t *record;
	erx_mapping_view_t view;
	int status;

	if (erx_map_range_decode(&tree, number(argv[1]), number(argv[2]),
	    &range) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &plan) != ERX_OK ||
	    plan.nspares != 0 ||
	    erx_map_apply(&tree, &plan, NULL, 0, &result) != ERX_OK)
		fail("deadrecord: no whole record to release");
	record = erx_map_detached_next(&result.detached);
	if (record == NULL)
		fail("deadrecord: nothing released");
	view = erx_map_view(record);
	status = erx_map_mark_deleted(&tree, record);
	printf("= deadrecord %d %d\n", status, (int)erx_map_view(record).kind);
	if (view.kind == ERX_MAP_OBJECT)
		reverse_map[index_of(view.object)]--;
	record_free(record);
	drain(&result.detached);
	print_tree();
}

/*
 * twice ADDR SIZE: two plans of one release. Applying the first spends it and
 * moves the tree; the second is then stale, and the first is spent.
 */
static void
command_twice(char **argv)
{
	erx_map_plan_t first, second;
	erx_map_range_t range;
	erx_map_result_t result;
	int status;

	if (erx_map_range_decode(&tree, number(argv[1]), number(argv[2]),
	    &range) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &first) != ERX_OK ||
	    erx_map_plan_release(&tree, &range, &second) != ERX_OK ||
	    first.nspares != 0)
		fail("twice: no whole records to release");
	status = erx_map_apply(&tree, &first, NULL, 0, &result);
	printf("= twice %d", status);
	drain(&result.detached);
	status = erx_map_apply(&tree, &second, NULL, 0, &result);
	printf("= stale %d\n", status);
	status = erx_map_apply(&tree, &first, NULL, 0, &result);
	printf("= spent %d\n", status);
	/* Too many spares refuse too, and use none. */
	if (erx_map_plan_release(&tree, &range, &first) != ERX_OK)
		fail("twice: replan");
	{
		erx_mapping_t *extra = record_new();

		status = erx_map_apply(&tree, &first, &extra, 1, &result);
		printf("= extra %d\n", status);
		record_free(extra);
	}
	print_tree();
}

/*
 * fill START COUNT PAGES: COUNT reservations of PAGES pages, each with a
 * one-page hole above it, from page START up.
 */
static void
command_fill(uint64_t start, uint64_t count, uint64_t pages)
{
	for (uint64_t i = 0; i < count; i++) {
		erx_map_insert_t request = {
			.addr = (start + (pages + 1) * i) * ERX_PAGE_SIZE,
			.size = pages * ERX_PAGE_SIZE,
			.vm_flags = ERX_VM_FIXED, .kind = ERX_MAP_RESERVED,
			.prot = ERX_PROT_NONE };
		erx_map_plan_t plan;
		erx_map_result_t result;
		erx_mapping_t *spare;

		if (erx_map_plan_insert(&tree, &request, &plan) != ERX_OK)
			fail("fill: refused");
		spare = record_new();
		if (erx_map_apply(&tree, &plan, &spare, 1, &result) != ERX_OK)
			fail("fill: not applied");
	}
	printf("= fill %" PRIu64 "\n", count);
	print_tree();
}

static void
run_command(char **argv, int argc)
{
	if (strcmp(argv[0], "init") == 0 && argc == 2) {
		command_init(number(argv[1]));
	} else if (strcmp(argv[0], "insert") == 0 && argc == 14) {
		command_insert(argv);
	} else if (strcmp(argv[0], "release") == 0 && argc == 4) {
		command_release(argv);
	} else if (strcmp(argv[0], "part") == 0 && argc == 8) {
		command_part(argv);
	} else if (strcmp(argv[0], "rawrelease") == 0 && argc == 3) {
		command_raw_release(argv);
	} else if (strcmp(argv[0], "rawpart") == 0 && argc == 5) {
		command_raw_part(argv);
	} else if (strcmp(argv[0], "markstale") == 0 && argc == 4) {
		command_mark_stale(argv);
	} else if (strcmp(argv[0], "othertree") == 0 && argc == 3) {
		command_other_tree(argv);
	} else if (strcmp(argv[0], "lowspares") == 0 && argc == 3) {
		command_low_spares(argv);
	} else if (strcmp(argv[0], "kremove") == 0 && argc == 3) {
		command_kremove(argv);
	} else if (strcmp(argv[0], "edges") == 0 && argc == 4) {
		command_edges(argv);
	} else if (strcmp(argv[0], "deleted") == 0 && argc == 2) {
		command_deleted(number(argv[1]));
	} else if (strcmp(argv[0], "deadrecord") == 0 && argc == 3) {
		command_dead_record(argv);
	} else if (strcmp(argv[0], "twice") == 0 && argc == 3) {
		command_twice(argv);
	} else if (strcmp(argv[0], "fill") == 0 && argc == 4) {
		command_fill(number(argv[1]), number(argv[2]), number(argv[3]));
	} else if (strcmp(argv[0], "quiet") == 0 && argc == 2) {
		quiet = (int)number(argv[1]);
	} else if (strcmp(argv[0], "lookup") == 0 && argc == 2) {
		const erx_mapping_t *record = erx_map_lookup(&tree,
		    (erx_uvpn_t){ number(argv[1]) });

		printf("L %" PRIu64 "\n", record == NULL ? 0 :
		    erx_map_view(record).start.raw);
	} else {
		fail("unknown command");
	}
}

int
main(int argc, char **argv)
{
	char line[512], *args[16], *word, *save;
	FILE *input;
	int nargs;

	if (argc != 2)
		fail("usage: map-driver SCRIPT");
	input = fopen(argv[1], "r");
	if (input == NULL)
		fail("cannot open script");
	if (erx_map_tree_init(&tree, (erx_uvpn_t){ 1024 }) != ERX_OK)
		fail("no tree");
	while (fgets(line, sizeof(line), input) != NULL) {
		nargs = 0;
		for (word = strtok_r(line, " \t\n", &save); word != NULL;
		    word = strtok_r(NULL, " \t\n", &save)) {
			if (nargs == 16)
				fail("too many words");
			args[nargs++] = word;
		}
		if (nargs > 0)
			run_command(args, nargs);
	}
	fclose(input);
	tree_empty();
	return (0);
}
