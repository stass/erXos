/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the domain library's core after creation
 * (liberx/system/dom_life.c), run by test/host/dom_life_test.rb.
 *
 *   explore	fail a connection at every step against an independent model
 *		of budgets and undo it; then disconnect a full one
 *   cases	every refusal and result of connect, disconnect, retire and
 *		stop, and the record step over each kind of record
 *   seeded	connection plans that break the one-installer rule or the
 *		reader-pays rule, which erx_dom_link_check must refuse
 *
 * The explore and the cases and seeds whose names start with area_ cover a
 * connection with a pixel area (docs/design-display.md, "The pixel area").
 *
 * Output is one line per result; the test compares them.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/dom.h"

#define NDOMAINS	5
#define NCONNECTIONS	4

static erx_dom_t domains[NDOMAINS];
static erx_dom_connection_t connections[NCONNECTIONS];
/* The retired domains' remains, twice the rows, as the library sizes them. */
static erx_dom_remains_t remains[2 * NCONNECTIONS];
/* The one principal, which counts domain 7, the one a retire may take, and its bytes. */
static erx_dom_principal_t principals[1];
/* The system domain's space, as records name it; 77 is a domain's own. */
#define SYSTEM_SPACE	UINT64_C(4000)
static erx_dom_view_t view;
/*
 * The catalogue: 0 an unconfined virtio-mmio transport of unit 0 on line
 * 5, placed on configured row 0, which domain 5 was created from, and 1 a
 * confined device of unit 1 on lines 6 and 7, placed on row 1, domain 6's.
 * Cases that list entry 2 set it.
 */
#define NDEVICES	3
static erx_dom_device_entry_t devices[NDEVICES];
static erx_dom_device_t device_records[NDEVICES];
static unsigned long failures;

static void	device_explore(void);
static erx_status_t give(uint32_t, uint32_t, erx_dom_unit_plan_t *);
static void	link_record_cases(void);

static const char *const step_names[] = {
	"CARVE", "SPACE", "GROUP", "MEM", "BELL", "SLICE", "IMAGE_MAP", "MAP",
	"INSTALL", "BOOTINFO", "THREAD", "RESOURCE", "WINDOW", "IRQ", "DMA",
	"CONTIGUOUS", "GIVE"
};

/*
 * Five records: 5 running, 6 built, 7 ended, 8 building, one free; and
 * the system connections of 5 and 6. Caps are the record's id times 100
 * plus a field number, so a teardown's capabilities name their source.
 */
static void
reset_view(void)
{
	memset(domains, 0, sizeof(domains));
	memset(connections, 0, sizeof(connections));
	memset(remains, 0, sizeof(remains));
	domains[0] = (erx_dom_t){ .id = 5, .state = ERX_DOM_RUNNING,
	    .origin = { ERX_DOM_CONFIGURED, 0 },
	    .budget = { 501 }, .outer = { 502 }, .connections = 2,
	    .labels = ERX_DOM_SYSTEM_LABEL };
	domains[1] = (erx_dom_t){ .id = 6, .state = ERX_DOM_BUILT,
	    .origin = { ERX_DOM_CONFIGURED, 1 },
	    .budget = { 601 }, .outer = { 602 }, .connections = 1, .labels = 3 };
	principals[0] = (erx_dom_principal_t){ .number = 1, .domains = 1, .carved = 12288 };
	domains[2] = (erx_dom_t){ .id = 7, .principal = 1, .state = ERX_DOM_ENDED,
	    .budget = { 701 }, .outer = { 702 }, .crash = { 703 }, .connections = 1,
	    .labels = 1, .own_bytes = 4096, .outer_bytes = 8192 };
	domains[3] = (erx_dom_t){ .id = 8, .state = ERX_DOM_BUILDING,
	    .budget = { 801 }, .outer = { 802 }, .connections = 1, .labels = 1 };
	connections[0] = (erx_dom_connection_t){ .number = 1,
	    .a = ERX_DOM_SYSTEM_ID, .b = 5, .budget_b = { 511 } };
	connections[1] = (erx_dom_connection_t){ .number = 2,
	    .a = ERX_DOM_SYSTEM_ID, .b = 6, .budget_b = { 611 } };
	view = (erx_dom_view_t){ .domains = domains, .max_domains = NDOMAINS,
	    .connections = connections, .max_connections = NCONNECTIONS,
	    .remains = remains, .max_remains = 2 * NCONNECTIONS,
	    .principals = principals, .nprincipals = 1, .next_connection = 20, .system_space = SYSTEM_SPACE,
	    .devices = devices, .device_records = device_records,
	    .ndevices = 2 };
	memset(devices, 0, sizeof(devices));
	memset(device_records, 0, sizeof(device_records));
	devices[0] = (erx_dom_device_entry_t){ .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a003000, 0x1000 } }, .lines = { 5 },
	    .memory = 0x100000, .role_word = "block",
	    .peripheral = "virtio_mmio" };
	devices[1] = (erx_dom_device_entry_t){ .nranges = 2, .nlines = 2,
	    .ranges = { { 0x10000000, 0x4000 }, { 0x10010000, 0x1000 } },
	    .lines = { 6, 7 }, .confined = true, .unit = 1, .row = 1,
	    .role_word = "network", .peripheral = "virtio_mmio" };
	for (uint32_t index = 0; index < NDEVICES; index++)
		device_records[index].index = index;
}

/*
 * The model: each object the plan makes, with the budget it is charged
 * to or carved from. Destroying a budget removes it and, transitively,
 * everything charged to it. The reader of each object is the model's own
 * table, not the core's, so a plan that charges a writer fails here too.
 */
typedef struct model {
	bool		alive[ERX_DOM_OBJ_COUNT];
	bool		installed[ERX_DOM_OBJ_COUNT];
	erx_dom_obj_t	parent[ERX_DOM_OBJ_COUNT];
} model_t;

static erx_dom_obj_t
reader_budget(erx_dom_obj_t obj)
{
	if (obj == ERX_DOM_OBJ_LINK_BUDGET_A)
		return (ERX_DOM_OBJ_OUTER_A);
	if (obj == ERX_DOM_OBJ_LINK_BUDGET_B)
		return (ERX_DOM_OBJ_OUTER_B);
	/* a reads b's side and waits on its own bell. */
	if (obj == ERX_DOM_OBJ_SIDE_B || obj == ERX_DOM_OBJ_BELL_A ||
	    obj == ERX_DOM_OBJ_AREA_B)
		return (ERX_DOM_OBJ_LINK_BUDGET_A);
	if (obj == ERX_DOM_OBJ_SIDE_A || obj == ERX_DOM_OBJ_BELL_B ||
	    obj == ERX_DOM_OBJ_AREA_A)
		return (ERX_DOM_OBJ_LINK_BUDGET_B);
	return (ERX_DOM_OBJ_NONE);
}

static void
fail(const char *what, unsigned at)
{
	printf("FAIL at=%u %s\n", at, what);
	failures++;
}

static void
model_apply(model_t *m, const erx_dom_step_t *step, unsigned at)
{
	if (step->kind == ERX_DOM_STEP_INSTALL) {
		if (!m->alive[step->obj])
			fail("install of an object not made", at);
		m->installed[step->obj] = true;
		return;
	}
	if (reader_budget(step->obj) != step->budget)
		fail("charged to a party that does not read it", at);
	m->alive[step->obj] = true;
	m->parent[step->obj] = step->budget;
}

static void
model_destroy(model_t *m, erx_dom_obj_t budget)
{
	bool changed = true;

	m->alive[budget] = false;
	while (changed) {
		changed = false;
		for (int obj = 0; obj < ERX_DOM_OBJ_COUNT; obj++)
			if (m->alive[obj] && !m->alive[m->parent[obj]] &&
			    m->parent[obj] < ERX_DOM_OBJ_MADE_COUNT) {
				m->alive[obj] = false;
				changed = true;
			}
	}
}

/*
 * The capabilities left in the parties' tables: a deletion clears every
 * capability to its object from every table (docs/design-kernel.md, K25),
 * so an install stays only while its object lives.
 */
static unsigned
model_in_tables(const model_t *m)
{
	unsigned left = 0;

	for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
		left += m->installed[obj] && m->alive[obj];
	return (left);
}

static unsigned
model_left(const model_t *m)
{
	unsigned left = 0;

	for (int obj = 0; obj < ERX_DOM_OBJ_MADE_COUNT; obj++)
		left += m->alive[obj];
	return (left);
}

/*
 * Fails a connection carrying an area of `area` bytes read by `reader` at
 * every step and checks the undo, then disconnects it whole. Prints its
 * steps after `tag` and returns their number, 0 when it was refused.
 */
static uint32_t
explore_link(uint64_t area, uint32_t reader, const char *tag)
{
	erx_dom_link_plan_t plan;
	erx_dom_teardown_t teardown;
	erx_dom_obj_t undo[ERX_DOM_LINK_STEPS];
	uint32_t count;
	model_t m;

	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, area, reader, &plan) != ERX_OK) {
		printf("FAIL the valid connection was refused\n");
		failures++;
		return (0);
	}
	printf("%s", tag);
	for (uint32_t index = 0; index < plan.nsteps; index++)
		printf(" %s", step_names[plan.steps[index].kind]);
	printf("\n");
	for (unsigned at = 0; at < plan.nsteps; at++) {
		memset(&m, 0, sizeof(m));
		for (unsigned index = 0; index < at; index++)
			model_apply(&m, &plan.steps[index], index);
		count = erx_dom_link_undo(&plan, at, undo);
		for (uint32_t index = 0; index < count; index++)
			model_destroy(&m, undo[index]);
		if (model_left(&m) != 0)
			fail("undo left an object", at);
		if (model_in_tables(&m) != 0)
			fail("undo left a capability in a party's table", at);
	}

	/* Applied whole, the connection's row then goes at its disconnect. */
	memset(&m, 0, sizeof(m));
	for (unsigned index = 0; index < plan.nsteps; index++)
		model_apply(&m, &plan.steps[index], index);
	/* The row's capabilities are the model's object names. */
	connections[plan.row] = (erx_dom_connection_t){ .number = plan.number,
	    .a = 5, .b = 6, .budget_a = { ERX_DOM_OBJ_LINK_BUDGET_A },
	    .budget_b = { ERX_DOM_OBJ_LINK_BUDGET_B } };
	if (erx_dom_plan_disconnect(&view, plan.number, &teardown) != ERX_OK)
		fail("the connection's disconnect was refused", plan.nsteps);
	for (uint32_t index = 0; index < teardown.ndestroy; index++)
		model_destroy(&m, (erx_dom_obj_t)teardown.destroy[index].raw);
	if (model_left(&m) != 0 || model_in_tables(&m) != 0 ||
	    teardown.index != plan.row)
		fail("disconnect left an object or freed another row", plan.nsteps);
	return (plan.nsteps);
}

static int
explore(void)
{
	uint32_t nsteps = explore_link(0, 0, "steps");

	(void)explore_link(2 * ERX_PAGE_SIZE, 5, "area-steps");
	(void)explore_link(2 * ERX_PAGE_SIZE, 6, "area-b-steps");
	device_explore();
	printf("explore steps=%u failures=%lu\n", nsteps, failures);
	return (failures == 0 ? 0 : 1);
}

static void
connect_case(const char *name, uint32_t a, uint32_t b, uint32_t a_reads,
    uint32_t b_reads)
{
	erx_dom_link_plan_t plan;
	erx_status_t status;

	status = erx_dom_plan_connect(&view, a, b, a_reads, b_reads, 0, 0, &plan);
	if (status != ERX_OK) {
		printf("case %s %d\n", name, status);
		return;
	}
	printf("case %s %d number=%u row=%u slots=%u,%u labels=%u,%u "
	    "children=%llu,%llu\n", name, status, plan.number, plan.row,
	    plan.a_slot, plan.b_slot, plan.steps[4].label, plan.steps[5].label,
	    (unsigned long long)plan.steps[0].size,
	    (unsigned long long)plan.steps[1].size);
}

/*
 * erx_dom_link_record of a plan of connect(5, 6), shown by row 2, the row
 * that plan takes, the parties' labels and the next number.
 */
static void
link_record_case(const char *name, const erx_dom_link_plan_t *plan)
{
	erx_status_t status = erx_dom_link_record(&view, plan);

	printf("case %s %d row=%u,%u,%u labels=%u,%u next=%u\n", name, status,
	    connections[2].number, connections[2].a, connections[2].b,
	    domains[0].labels, domains[1].labels, view.next_connection);
}

static void
link_record_cases(void)
{
	erx_dom_link_plan_t plan;

	/* The record is what the next plan sees: 6's one connection is taken. */
	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, 0, 0, &plan) != ERX_OK)
		failures++;
	link_record_case("record_ok", &plan);
	connect_case("record_then_quota", 5, 6, 65536, 16384);
	link_record_case("record_twice", &plan);

	/* A plan that no longer fits the view leaves it as it was. */
	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, 0, 0, &plan) != ERX_OK)
		failures++;
	domains[0].id = 9;
	link_record_case("record_stale_slot", &plan);
	domains[0].id = 5;
	view.next_connection = 21;
	link_record_case("record_not_next", &plan);
	plan.row = NCONNECTIONS;
	view.next_connection = 20;
	link_record_case("record_row_out", &plan);

	/* The last number spends them. */
	reset_view();
	view.next_connection = UINT32_MAX;
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, 0, 0, &plan) != ERX_OK)
		failures++;
	link_record_case("record_last_number", &plan);
}

/*
 * A connection with a pixel area: the children, the area's object and the
 * child it is charged to, each install of it with its rights, and the
 * reader the record keeps.
 */
static void
area_case(const char *name, uint64_t area, uint32_t reader)
{
	erx_dom_link_plan_t plan;
	const erx_dom_step_t *step;
	erx_status_t status;

	reset_view();
	status = erx_dom_plan_connect(&view, 5, 6, 65536, 16384, area, reader, &plan);
	if (status != ERX_OK) {
		printf("case %s %d\n", name, status);
		return;
	}
	printf("case %s %d reader=%u children=%llu,%llu", name, status,
	    plan.area_reader, (unsigned long long)plan.steps[0].size,
	    (unsigned long long)plan.steps[1].size);
	for (uint32_t index = 0; index < plan.nsteps; index++) {
		step = &plan.steps[index];
		if (step->obj != ERX_DOM_OBJ_AREA_A && step->obj != ERX_DOM_OBJ_AREA_B)
			continue;
		if (step->kind == ERX_DOM_STEP_MEM)
			printf(" mem=%s,%s,%llu",
			    step->obj == ERX_DOM_OBJ_AREA_A ? "A" : "B",
			    step->budget == ERX_DOM_OBJ_LINK_BUDGET_A ? "a" : "b",
			    (unsigned long long)step->size);
		else
			printf(" install=%s,%s", step->target == ERX_DOM_OBJ_SPACE_A ? "a" : "b",
			    (step->rights & ERX_HR_WRITE) != 0 ? "rw" : "r");
	}
	if (erx_dom_link_record(&view, &plan) == ERX_OK)
		printf(" recorded=%u", connections[plan.row].area_reader);
	printf("\n");
}

static void
area_cases(void)
{
	area_case("area_a_reads", 8192, 5);
	area_case("area_b_reads", 8192, 6);
	area_case("area_one_page", ERX_PAGE_SIZE, 5);
	area_case("area_unaligned", ERX_PAGE_SIZE + 1, 5);
	area_case("area_half_page", ERX_PAGE_SIZE / 2, 6);
	area_case("area_no_reader", 8192, 0);
	area_case("area_third_reader", 8192, 7);
	area_case("area_reader_alone", 0, 5);
	area_case("area_child_wraps", UINT64_MAX - ERX_PAGE_SIZE + 1, 5);
}

static void
teardown_case(const char *name, erx_status_t status,
    const erx_dom_teardown_t *teardown)
{
	if (status != ERX_OK) {
		printf("case %s %d\n", name, status);
		return;
	}
	printf("case %s 0 kind=%d index=%u destroy=", name, teardown->kind,
	    teardown->index);
	for (uint32_t index = 0; index < teardown->ndestroy; index++)
		printf("%s%llu", index == 0 ? "" : ",",
		    (unsigned long long)teardown->destroy[index].raw);
	for (uint32_t index = 0; index < teardown->nremains; index++)
		printf("%s%u", index == 0 ? " remains=" : ",", teardown->remains[index]);
	printf("\n");
}

/* The principal's counts and the first two remains rows, after a record step. */
static void
remains_line(const char *name)
{
	printf("case %s principal=%u,%llu remains=%u,%llu,%llu;%u,%llu,%llu record7=%u row9=%u\n", name,
	    principals[0].domains, (unsigned long long)principals[0].carved,
	    remains[0].id, (unsigned long long)remains[0].outer.raw,
	    (unsigned long long)remains[0].bytes, remains[1].id,
	    (unsigned long long)remains[1].outer.raw, (unsigned long long)remains[1].bytes,
	    domains[2].id, connections[2].number);
}

/*
 * A retire while a survivor, 5, holds connection 9 with domain 7, then the
 * disconnects that end the remains: the last row naming 7 destroys them,
 * an earlier one does not, and one whose two parties are both retired
 * destroys both.
 */
static void
remains_cases(void)
{
	erx_dom_teardown_t teardown;
	erx_status_t status;

	reset_view();
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 5, .b = 7,
	    .budget_a = { 521 }, .budget_b = { 721 }, .closing = true };
	status = erx_dom_plan_retire(&view, 7, &teardown);
	teardown_case("retire_held", status, &teardown);
	if (status == ERX_OK)
		erx_dom_retire_record(&view, &teardown);
	remains_line("retire_held_record");
	status = erx_dom_plan_disconnect(&view, 9, &teardown);
	teardown_case("disconnect_last", status, &teardown);
	if (status == ERX_OK)
		erx_dom_disconnect_record(&view, &teardown);
	remains_line("disconnect_last_record");

	reset_view();
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 5, .b = 7,
	    .budget_a = { 521 }, .budget_b = { 721 }, .closing = true };
	connections[3] = (erx_dom_connection_t){ .number = 10, .a = 7, .b = 6,
	    .budget_a = { 722 }, .budget_b = { 621 }, .closing = true };
	if (erx_dom_plan_retire(&view, 7, &teardown) == ERX_OK)
		erx_dom_retire_record(&view, &teardown);
	teardown_case("disconnect_named", erx_dom_plan_disconnect(&view, 9, &teardown), &teardown);
	/* With row 9 gone, row 10 is the last naming 7, whose bytes the principal no longer holds. */
	connections[2] = (erx_dom_connection_t){ .number = 0 };
	principals[0].carved = 4096;
	teardown_case("disconnect_unheld", erx_dom_plan_disconnect(&view, 10, &teardown), &teardown);

	reset_view();
	principals[0].carved = 16384;
	remains[0] = (erx_dom_remains_t){ .id = 7, .principal = 1, .outer = { 702 }, .bytes = 8192 };
	remains[3] = (erx_dom_remains_t){ .id = 11, .principal = 1, .outer = { 1102 }, .bytes = 8192 };
	domains[2] = (erx_dom_t){ .id = 0 };
	connections[2] = (erx_dom_connection_t){ .number = 14, .a = 7, .b = 11,
	    .budget_a = { 721 }, .budget_b = { 1121 }, .closing = true };
	status = erx_dom_plan_disconnect(&view, 14, &teardown);
	teardown_case("disconnect_both", status, &teardown);
	if (status == ERX_OK)
		erx_dom_disconnect_record(&view, &teardown);
	remains_line("disconnect_both_record");

	reset_view();
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 5, .b = 7 };
	for (uint32_t index = 0; index < 2 * NCONNECTIONS; index++)
		remains[index].id = 100 + index;
	teardown_case("retire_remains_full", erx_dom_plan_retire(&view, 7, &teardown), &teardown);
}

static void
action_case(const char *name, erx_status_t status,
    const erx_dom_action_t *action)
{
	if (status != ERX_OK) {
		printf("act %s %d\n", name, status);
		return;
	}
	printf("act %s 0 kind=%d", name, action->kind);
	if (action->kind != ERX_DOM_ACT_DROP)
		printf(" slot=%u status=%lld end=%d,%lld", action->slot,
		    (long long)action->status, action->end.kind,
		    (long long)action->end.status);
	if (action->kind == ERX_DOM_ACT_END)
		printf(" teardown=%d,%u,%llu", action->teardown.kind,
		    action->teardown.index,
		    (unsigned long long)action->teardown.destroy[0].raw);
	printf("\n");
}

static void
record_case(const char *name, uint64_t label, uint32_t kind, uint64_t space,
    int64_t status)
{
	/* The stopper's thread is 0, as the stopgap reports it. */
	erx_fault_t record = { .kind = kind, .space = space,
	    .status = status };
	erx_dom_action_t action;

	erx_dom_record_step(&view, label, &record, &action);
	action_case(name, ERX_OK, &action);
}

static void
stop_case(const char *name, uint32_t id, int64_t status)
{
	erx_dom_action_t action;

	action_case(name, erx_dom_plan_stop(&view, id, status, &action),
	    &action);
}

static void
connect_cases(void)
{
	reset_view();
	connect_case("connect_ok", 5, 6, 65536, 16384);
	connect_case("connect_same", 5, 5, 65536, 65536);
	connect_case("connect_unknown", 5, 9, 65536, 65536);
	connect_case("connect_system", ERX_DOM_SYSTEM_ID, 5, 65536, 65536);
	connect_case("connect_ended", 5, 7, 65536, 65536);
	connect_case("connect_building", 8, 5, 65536, 65536);
	connect_case("connect_lane_odd", 5, 6, 65537, 65536);
	connect_case("connect_lane_zero", 5, 6, 65536, 0);
	connect_case("connect_lane_large", 5, 6, ERX_LANE_MAX * 2u, 65536);
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 5, .b = 6 };
	connect_case("connect_quota", 5, 6, 65536, 65536);
	connections[2].closing = true;
	connect_case("connect_quota_closing", 6, 5, 65536, 65536);
	reset_view();
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 4, .b = 7 };
	connections[3] = (erx_dom_connection_t){ .number = 10, .a = 4, .b = 8 };
	connect_case("connect_table_full", 5, 6, 65536, 65536);
	reset_view();
	view.next_connection = 0;
	connect_case("connect_numbers_spent", 5, 6, 65536, 65536);
	reset_view();
	domains[0].labels = ERX_LABEL_SPLIT - 1;
	connect_case("connect_labels_spent", 5, 6, 65536, 65536);
	domains[0].labels = ERX_LABEL_SPLIT - 2;
	connect_case("connect_labels_last", 5, 6, 65536, 65536);
	domains[0].labels = 0;
	connect_case("connect_labels_unset", 5, 6, 65536, 65536);
	link_record_cases();
}

static void
teardown_cases(void)
{
	erx_dom_teardown_t teardown;

	reset_view();
	teardown_case("disconnect_system",
	    erx_dom_plan_disconnect(&view, 1, &teardown), &teardown);
	connections[3] = (erx_dom_connection_t){ .number = 12, .a = 5, .b = 6,
	    .budget_a = { 521 }, .budget_b = { 621 } };
	teardown_case("disconnect_pair",
	    erx_dom_plan_disconnect(&view, 12, &teardown), &teardown);
	teardown_case("disconnect_zero",
	    erx_dom_plan_disconnect(&view, 0, &teardown), &teardown);
	teardown_case("disconnect_unknown",
	    erx_dom_plan_disconnect(&view, 77, &teardown), &teardown);
	reset_view();
	teardown_case("retire_ok", erx_dom_plan_retire(&view, 7, &teardown),
	    &teardown);
	teardown_case("retire_running",
	    erx_dom_plan_retire(&view, 5, &teardown), &teardown);
	teardown_case("retire_unknown",
	    erx_dom_plan_retire(&view, 9, &teardown), &teardown);
	teardown_case("retire_zero", erx_dom_plan_retire(&view, 0, &teardown),
	    &teardown);
	connections[2] = (erx_dom_connection_t){ .number = 9,
	    .a = ERX_DOM_SYSTEM_ID, .b = 7 };
	teardown_case("retire_busy_system",
	    erx_dom_plan_retire(&view, 7, &teardown), &teardown);
	remains_cases();
}

static void
end_cases(void)
{
	reset_view();
	stop_case("stop_ok", 5, 3);
	stop_case("stop_crash_status", 6, ERX_EXIT_CRASH);
	stop_case("stop_ended", 7, 0);
	stop_case("stop_building", 8, 0);
	stop_case("stop_unknown", 9, 0);
	stop_case("stop_parent_status", 5, ERX_EXIT_PARENT);
	stop_case("stop_released_status", 5, ERX_EXIT_RELEASED);
	stop_case("stop_nothread_status", 5, ERX_EXIT_NOTHREAD);
	record_case("fault_running", 5, ERX_FAULT_MEMORY, 77, 0);
	record_case("exit_halt", 5, ERX_FAULT_EXIT, 77, 0);
	record_case("exit_halt_status", 6, ERX_FAULT_EXIT, 77, 42);
	record_case("exit_nothread", 5, ERX_FAULT_EXIT, 77, ERX_EXIT_NOTHREAD);
	record_case("exit_crash", 5, ERX_FAULT_EXIT, 77, ERX_EXIT_CRASH);
	record_case("exit_library_unnoted", 5, ERX_FAULT_EXIT, SYSTEM_SPACE, 0);
	record_case("exit_ended", 7, ERX_FAULT_EXIT, 77, 0);
	record_case("fault_ended", 7, ERX_FAULT_MEMORY, 77, 0);
	record_case("exit_building", 8, ERX_FAULT_EXIT, 77, 0);
	record_case("exit_unknown", 9, ERX_FAULT_EXIT, 77, 0);
	record_case("exit_system", ERX_DOM_SYSTEM_ID, ERX_FAULT_EXIT, 77, 0);
	record_case("exit_wide_label", (UINT64_C(1) << 32) + 5, ERX_FAULT_EXIT,
	    77, 0);

	/* With 5 stopping for a fault and 6 stopping on request. */
	domains[0].stop = (erx_dom_end_t){ ERX_DOM_END_FAULT, ERX_FAULT_UNDEFINED };
	domains[1].stop = (erx_dom_end_t){ ERX_DOM_END_STOPPED, 0 };
	stop_case("stop_again", 5, 0);
	record_case("fault_stopping", 5, ERX_FAULT_ALIGNMENT, 77, 0);
	record_case("exit_fault_noted", 5, ERX_FAULT_EXIT, SYSTEM_SPACE,
	    ERX_EXIT_CRASH);
	record_case("exit_stopped", 6, ERX_FAULT_EXIT, SYSTEM_SPACE, 3);
	record_case("exit_fault_unknown_stopper", 5, ERX_FAULT_EXIT,
	    SYSTEM_SPACE, ERX_EXIT_CRASH);
	record_case("exit_halt_first", 5, ERX_FAULT_EXIT, 77, 2);
	record_case("exit_crash_first", 6, ERX_FAULT_EXIT, 77, ERX_EXIT_CRASH);
}

/*
 * Plans the give of unit row `unit` to a new domain id of the origin the
 * view's record of id has (none for an id no record holds), created into
 * the free record 4, as a configured creation plans its gives.
 */
static erx_status_t
give(uint32_t id, uint32_t unit, erx_dom_unit_plan_t *plan)
{
	static erx_dom_plan_t holder;

	memset(&holder, 0, sizeof(holder));
	holder.spec.id = id;
	holder.slot = 4;
	for (uint32_t slot = 0; slot < NDOMAINS; slot++)
		if (domains[slot].id == id)
			holder.spec.origin = domains[slot].origin;
	return (erx_dom_plan_unit_give(&view, &holder, unit, plan));
}

/* A unit's give: its status, then its steps' kinds and its undo's size. */
static void
device_case(const char *name, uint32_t id, uint32_t unit)
{
	erx_dom_unit_plan_t plan;
	erx_dom_obj_t undo[ERX_DOM_UNIT_STEPS];
	erx_status_t status = give(id, unit, &plan);

	if (status != ERX_OK) {
		printf("dev %s %d\n", name, status);
		return;
	}
	printf("dev %s 0 slot=%u steps=", name, plan.slot);
	for (uint32_t step = 0; step < plan.nsteps; step++)
		printf("%s%s", step == 0 ? "" : ",",
		    step_names[plan.steps[step].kind]);
	printf(" undo=%u\n", erx_dom_unit_undo(&plan, plan.nsteps, undo));
}

/* A window or line number of a unit's device, or "-" for none. */
static void
print_unit_number(uint32_t number)
{
	if (number == ERX_DOM_UNIT_NONE)
		printf("-");
	else
		printf("%u", number);
}

/*
 * The give of unit 0 to domain 5: its status, its steps' kinds, each
 * window's base and size, and for each device its entry, its window, its
 * offset in it, its line's object and whether the line is shared.
 */
static void
unit_case(const char *name)
{
	erx_dom_unit_plan_t plan;
	const erx_dom_unit_device_t *device;
	erx_status_t status = give(5, 0, &plan);

	if (status != ERX_OK) {
		printf("dev %s %d\n", name, status);
		return;
	}
	printf("dev %s 0 steps=", name);
	for (uint32_t step = 0; step < plan.nsteps; step++)
		printf("%s%s", step == 0 ? "" : ",",
		    step_names[plan.steps[step].kind]);
	printf(" windows=");
	for (uint32_t step = 0, count = 0; step < plan.nsteps; step++)
		if (plan.steps[step].kind == ERX_DOM_STEP_WINDOW)
			printf("%s%#" PRIx64 "+%#" PRIx64, count++ == 0 ? "" : ",",
			    plan.steps[step].base, plan.steps[step].size);
	printf(" devices=");
	for (uint32_t d = 0; d < plan.ndevices; d++) {
		device = &plan.devices[d];
		printf("%s%u:", d == 0 ? "" : ",", device->index);
		print_unit_number(device->window);
		printf("@%#" PRIx64 ":", device->offset);
		print_unit_number(device->line);
		printf(":%d", device->shared);
	}
	printf("\n");
}
static void
device_cases(void)
{
	reset_view();
	device_case("dev_unconfined_first", 5, 0);
	device_case("dev_confined", 6, 1);
	device_case("dev_unknown_domain", 9, 0);
	device_case("dev_ended_domain", 7, 0);
	device_case("dev_building_domain", 8, 0);
	device_case("dev_index_past", 5, 2);
	device_records[0].memory = (erx_cap_t){ 77 };
	device_case("dev_unconfined_kept", 5, 0);
	device_records[0].holder = 6;
	device_case("dev_busy", 5, 0);
	device_records[0].holder = 5;
	device_case("dev_busy_self", 5, 0);
	device_records[0].holder = 7;
	device_case("dev_holder_ended", 5, 0);
	device_records[0].holder = 9;
	device_case("dev_holder_retired", 5, 0);

	/* Placement: only a domain of the row the manifest places the unit on. */
	reset_view();
	device_case("dev_wrong_holder", 6, 0);
	devices[0].row = ERX_MF_NONE;
	device_case("dev_system_device", 5, 0);
	domains[0].origin = (erx_dom_origin_t){ ERX_DOM_REQUEST, ERX_MF_NONE };
	device_case("dev_requested_domain", 5, 0);
	devices[0].row = 0;
	device_case("dev_requested_domain_row", 5, 0);

	reset_view();
	view.ndevices = 3;
	/* Entry 2 of another unit, of no kind, meeting entry 0's page or beside it. */
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1, .unit = 2,
	    .ranges = { { 0x0a002000, 0x2000 } } };
	device_case("dev_overlap", 5, 0);
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a004000, 0x1000 };
	device_case("dev_adjacent", 5, 0);
	/*
	 * Entry 2 a driven device of entry 0's unit (docs/design-shared-devices.md,
	 * "The unit rule"): the unit's give makes one window per page run and
	 * one IRQ object per line, on its own page and entry 0's line, on
	 * entry 0's page 0x200 in, beside it, or over part of its page; of
	 * another unit, the give of unit 0 is entry 0's alone.
	 */
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a005000, 0x1000 } }, .lines = { 5 },
	    .role_word = "block", .peripheral = "virtio_mmio" };
	unit_case("dev_unit_shared_line");
	devices[2].lines[0] = 9;
	unit_case("dev_unit_other_line");
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a003000, 0x1000 };
	devices[2].offset = 0x200;
	unit_case("dev_unit_shared_page");
	devices[2].offset = 0;
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a004000, 0x1000 };
	unit_case("dev_unit_run");
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a002000, 0x2000 };
	unit_case("dev_unit_overlap");
	devices[2].unit = 2;
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a005000, 0x1000 };
	unit_case("dev_unit_other_unit");
	devices[2].unit = 0;
	devices[0].nlines = ERX_DEVICE_IRQS_MAX;
	for (uint32_t line = 0; line < ERX_DEVICE_IRQS_MAX; line++)
		devices[0].lines[line] = 20 + line;
	unit_case("dev_unit_lines_over");
	devices[0].nlines = 1;
	devices[0].lines[0] = 5;
	/*
	 * Entry 2 of no kind (docs/design-shared-devices.md, "The unit rule"):
	 * held, not driven, so the give makes only its resource, and entry 0's
	 * line is shared when entry 2 names it too. On entry 0's page it would
	 * lie in entry 0's window, so the give is refused.
	 */
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a005000, 0x1000 } }, .lines = { 5 } };
	unit_case("dev_kindless_second");
	devices[2].lines[0] = 9;
	devices[2].confined = true;
	unit_case("dev_kindless_alone");
	/* Unconfined with memory to give: still nothing but its resource. */
	devices[2].confined = false;
	devices[2].memory = 0x100000;
	unit_case("dev_kindless_memory");
	devices[2].memory = 0;
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a003000, 0x1000 };
	unit_case("dev_kindless_page");
	/*
	 * Entry 0 of no kind too, so no driven device names their line: no
	 * record reads its IRQ object, so the give makes none, nor a window.
	 */
	devices[0].role_word = devices[0].peripheral = NULL;
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a005000, 0x1000 } }, .lines = { 5 } };
	unit_case("dev_kindless_unit");
	devices[0].role_word = "block";
	devices[0].peripheral = "virtio_mmio";
	/*
	 * A placed framebuffer (erx/dom.h): no role word, one range, no line;
	 * a runtime drives it, so its give windows its pages for its record.
	 */
	devices[2] = (erx_dom_device_entry_t){ .role = ERX_MF_DEVICE_ROLE_FRAMEBUFFER,
	    .nranges = 1, .ranges = { { 0x0a005000, 0x3000 } }, .unit = 2 };
	device_case("dev_framebuffer_placed", 5, 2);
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1, .unit = 2,
	    .ranges = { { 0x0a000000, UINT64_MAX - 0x0a000000 + 1 } } };
	device_case("dev_overlap_wrapping", 5, 0);

	reset_view();
	devices[0].nranges = ERX_DEVICE_RANGES_MAX + 1;
	device_case("dev_ranges_over", 5, 0);
	reset_view();
	devices[0].nlines = ERX_DEVICE_IRQS_MAX + 1;
	device_case("dev_lines_over", 5, 0);
	/* Registers that start inside the device's window and end past it. */
	reset_view();
	devices[0].offset = 0x800;
	devices[0].size = 0x1000;
	device_case("dev_registers_past_window", 5, 0);
	reset_view();
	devices[0].ranges[0].base += 1;
	device_case("dev_range_unaligned", 5, 0);
	reset_view();
	devices[0].ranges[0].size = 0;
	device_case("dev_range_empty", 5, 0);
	reset_view();
	devices[0].ranges[0] = (erx_dom_range_t){ UINT64_MAX - 0xfff, 0x2000 };
	device_case("dev_range_wraps", 5, 0);
	reset_view();
	devices[1].memory = 0x1000;
	device_case("dev_confined_memory", 6, 1);
	reset_view();
	devices[0].memory = 0x1001;
	device_case("dev_memory_unaligned", 5, 0);
	reset_view();
	devices[0].memory = 0;
	device_case("dev_no_memory", 5, 0);
	reset_view();
	devices[1].nranges = ERX_DEVICE_RANGES_MAX;
	devices[1].nlines = ERX_DEVICE_IRQS_MAX;
	for (uint32_t line = 0; line < ERX_DEVICE_IRQS_MAX; line++)
		devices[1].lines[line] = 40 + line;
	for (uint32_t range = 0; range < ERX_DEVICE_RANGES_MAX; range++)
		devices[1].ranges[range] = (erx_dom_range_t){
		    0x20000000 + range * 0x10000, 0x1000 };
	device_case("dev_full", 6, 1);
}

/*
 * A device's give failed at every step of the fullest plan and of an
 * unconfined first give: undo destroys each made object, so none lives
 * and the holder's table keeps nothing of it (K25).
 */
static void
device_explore(void)
{
	erx_dom_unit_plan_t plan;
	erx_dom_obj_t undo[ERX_DOM_UNIT_STEPS];
	bool alive[ERX_DOM_OBJ_COUNT];
	uint32_t count, left;

	for (uint32_t index = 0; index < 2; index++) {
		reset_view();
		devices[1].row = 0;
		devices[1].nranges = ERX_DEVICE_RANGES_MAX;
		devices[1].nlines = ERX_DEVICE_IRQS_MAX;
		for (uint32_t line = 0; line < ERX_DEVICE_IRQS_MAX; line++)
			devices[1].lines[line] = 40 + line;
		for (uint32_t range = 0; range < ERX_DEVICE_RANGES_MAX; range++)
			devices[1].ranges[range] = (erx_dom_range_t){
			    0x20000000 + range * 0x10000, 0x1000 };
		if (give(5, index, &plan) != ERX_OK) {
			fail("a valid give was refused", index);
			continue;
		}
		for (uint32_t at = 0; at <= plan.nsteps; at++) {
			memset(alive, 0, sizeof(alive));
			for (uint32_t step = 0; step < at; step++)
				if (plan.steps[step].kind != ERX_DOM_STEP_INSTALL &&
				    plan.steps[step].kind != ERX_DOM_STEP_CONTIGUOUS)
					alive[plan.steps[step].obj] = true;
			count = erx_dom_unit_undo(&plan, at, undo);
			for (uint32_t step = 0; step < count; step++)
				alive[undo[step]] = false;
			left = 0;
			for (int obj = 0; obj < ERX_DOM_OBJ_COUNT; obj++)
				left += alive[obj];
			if (left != 0)
				fail("a give's undo left an object", at);
		}
		printf("dev-explore %u steps=%u\n", index, plan.nsteps);
	}
}

/* Seeded plans: each breaks one rule erx_dom_link_check enforces. */
static void
seeded(void)
{
	erx_dom_link_plan_t valid, plan;
	uint32_t last;

	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 65536, 0, 0, &valid) != ERX_OK)
		failures++;
	last = valid.nsteps - 1;
	printf("seeded valid %d\n", erx_dom_link_check(&valid));
#define	SEED(name, edit) do {						\
	plan = valid;							\
	edit;								\
	printf("seeded %s %d\n", name, erx_dom_link_check(&plan));	\
} while (0)
	SEED("foreign_gate", plan.steps[last].obj = ERX_DOM_OBJ_FAULT_GATE);
	SEED("creation_object", plan.steps[last].obj = ERX_DOM_OBJ_SYS_SIDE);
	SEED("extra_right", plan.steps[last].rights |= ERX_HR_WRITE);
	SEED("peer_side_writable", {
		for (uint32_t index = 0; index < plan.nsteps; index++)
			if (plan.steps[index].kind == ERX_DOM_STEP_INSTALL &&
			    plan.steps[index].obj == ERX_DOM_OBJ_SIDE_B &&
			    plan.steps[index].target == ERX_DOM_OBJ_SPACE_A)
				plan.steps[index].rights |= ERX_HR_WRITE;
	});
	SEED("creation_space", plan.steps[last].target = ERX_DOM_OBJ_SPACE);
	SEED("writer_pays", plan.steps[2].budget = ERX_DOM_OBJ_LINK_BUDGET_B);
	SEED("child_from_peer", plan.steps[1].budget = ERX_DOM_OBJ_OUTER_A);
	SEED("child_from_principal",
	    plan.steps[0].budget = ERX_DOM_OBJ_PRINCIPAL_BUDGET);
	SEED("bell_on_peer_group", plan.steps[4].target = ERX_DOM_OBJ_GROUP_B);
	SEED("bell_label_zero", plan.steps[4].label = 0);
	SEED("bell_label_split", plan.steps[5].label = ERX_LABEL_SPLIT);
	SEED("out_of_order", {
		erx_dom_step_t first = plan.steps[0];
		plan.steps[0] = plan.steps[2];
		plan.steps[2] = first;
	});
	SEED("made_twice", plan.steps[1] = plan.steps[0]);
	SEED("too_many", plan.nsteps = ERX_DOM_LINK_STEPS + 1);
	SEED("obj_range", plan.steps[last].budget = ERX_DOM_OBJ_COUNT);
	SEED("same_party", plan.b = plan.a);
	SEED("number_zero", plan.number = 0);

	/* A pixel area read by a: AREA_B, charged to a's child, at step 6. */
	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 65536, 8192, 5, &valid) != ERX_OK)
		failures++;
	printf("seeded area_valid %d\n", erx_dom_link_check(&valid));
	SEED("area_writer_pays", plan.steps[6].budget = ERX_DOM_OBJ_LINK_BUDGET_B);
	SEED("area_reader_unset", plan.area_reader = 0);
	SEED("area_reader_writer", plan.area_reader = 6);
	SEED("area_reader_writable", {
		for (uint32_t index = 0; index < plan.nsteps; index++)
			if (plan.steps[index].kind == ERX_DOM_STEP_INSTALL &&
			    plan.steps[index].obj == ERX_DOM_OBJ_AREA_B &&
			    plan.steps[index].target == ERX_DOM_OBJ_SPACE_A)
				plan.steps[index].rights |= ERX_HR_WRITE;
	});
	/* A second area, with the reader the last one names: only the one-area rule refuses it. */
	SEED("area_twice", {
		plan.steps[7] = ((erx_dom_step_t){ .kind = ERX_DOM_STEP_MEM,
		    .obj = ERX_DOM_OBJ_AREA_A, .budget = ERX_DOM_OBJ_LINK_BUDGET_B,
		    .size = 8192 });
		plan.area_reader = plan.b;
	});
	SEED("area_unaligned", plan.steps[6].size = ERX_PAGE_SIZE + 1);
#undef SEED
}

/* Seeded gives: each breaks one rule erx_dom_unit_check enforces. */
static void
device_seeded(void)
{
	erx_dom_unit_plan_t valid, plan;
	const erx_dom_step_t dma = { .kind = ERX_DOM_STEP_DMA,
	    .obj = ERX_DOM_OBJ_DEV_DMA, .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
	    .target = ERX_DOM_OBJ_DEV_RESOURCE };
	uint32_t last;

	reset_view();
	if (give(5, 0, &valid) != ERX_OK)
		failures++;
	last = valid.nsteps - 1;
	printf("seeded dev_valid %d\n", erx_dom_unit_check(&valid));
#define	SEED(name, edit) do {						\
	plan = valid;							\
	edit;								\
	printf("seeded %s %d\n", name, erx_dom_unit_check(&plan));	\
} while (0)
	SEED("dev_gate", plan.steps[last].obj = ERX_DOM_OBJ_FAULT_GATE);
	SEED("dev_install_resource",
	    plan.steps[last].obj = ERX_DOM_OBJ_DEV_RESOURCE);
	SEED("dev_install_unmade", plan.steps[last].obj = ERX_DOM_OBJ_DEV_DMA);
	SEED("dev_window_phys", plan.steps[4].rights |= ERX_HR_PHYS);
	SEED("dev_foreign_space",
	    plan.steps[last].target = ERX_DOM_OBJ_SPACE_A);
	SEED("dev_resource_not_root",
	    plan.steps[0].target = ERX_DOM_OBJ_PRINCIPAL_BUDGET);
	SEED("dev_window_system_pays",
	    plan.steps[1].budget = ERX_DOM_OBJ_SYSTEM_BUDGET);
	SEED("dev_memory_holder_pays",
	    plan.steps[3].budget = ERX_DOM_OBJ_HOLDER_BUDGET);
	SEED("dev_window_unaligned", plan.steps[1].base += 0x200);
	/* A second window that abuts the first: one page run, two windows. */
	SEED("dev_window_meets", {
		plan.steps[plan.nsteps] = plan.steps[1];
		plan.steps[plan.nsteps].obj = ERX_DOM_OBJ_DEV_WINDOW + 1;
		plan.steps[plan.nsteps++].base += plan.steps[1].size;
	});
	/* The line's IRQ object made before the resource it comes from. */
	SEED("dev_out_of_order", {
		erx_dom_step_t first = plan.steps[0];
		plan.steps[0] = plan.steps[2];
		plan.steps[2] = first;
	});
	/* A window over pages no range of the unit names. */
	SEED("dev_window_elsewhere", plan.steps[1].base += 0x10000);
	/* An object installed into the holder twice. */
	SEED("dev_install_twice", plan.steps[plan.nsteps++] = plan.steps[last]);
	/* A device of no kind whose resource a DMA window is made from. */
	SEED("dev_kindless_dma", {
		plan.devices[1] = ((erx_dom_unit_device_t){ .index = 2,
		    .window = ERX_DOM_UNIT_NONE, .line = ERX_DOM_UNIT_NONE });
		plan.ndevices = 2;
		plan.steps[plan.nsteps++] = ((erx_dom_step_t){
		    .kind = ERX_DOM_STEP_RESOURCE, .obj = ERX_DOM_OBJ_DEV_RESOURCE + 1,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_ROOT_RESOURCE, .index = 2 });
		plan.steps[plan.nsteps] = dma;
		plan.steps[plan.nsteps].obj = ERX_DOM_OBJ_DEV_DMA + 1;
		plan.steps[plan.nsteps++].target = ERX_DOM_OBJ_DEV_RESOURCE + 1;
	});
	SEED("dev_dma_and_memory", plan.steps[plan.nsteps++] = dma);
	SEED("dev_system_holder", plan.holder = ERX_DOM_SYSTEM_ID);
	SEED("dev_too_many", plan.nsteps = ERX_DOM_UNIT_STEPS + 1);
	SEED("dev_line_unmade", plan.devices[0].line = 1);
	SEED("dev_offset_outside", plan.devices[0].offset = 0x1000);
	/* A second device whose resource no step carves. */
	SEED("dev_resource_unmade", {
		plan.devices[1] = plan.devices[0];
		plan.devices[1].index = 2;
		plan.ndevices = 2;
	});
	device_records[0].memory = (erx_cap_t){ 77 };
	if (give(5, 0, &valid) != ERX_OK)
		failures++;
	SEED("dev_kept_not_last", {
		erx_dom_step_t kept = plan.steps[plan.nsteps - 1];
		plan.steps[plan.nsteps - 1] = plan.steps[plan.nsteps - 2];
		plan.steps[plan.nsteps - 2] = kept;
	});
	reset_view();
	device_records[0].index = 1;
	printf("seeded dev_record_index %d\n", give(5, 0, &plan));
#undef SEED
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "explore") == 0)
		return (explore());
	if (argc == 2 && strcmp(argv[1], "cases") == 0) {
		connect_cases();
		area_cases();
		teardown_cases();
		end_cases();
		device_cases();
		return (failures == 0 ? 0 : 1);
	}
	if (argc == 2 && strcmp(argv[1], "seeded") == 0) {
		seeded();
		device_seeded();
		return (failures == 0 ? 0 : 1);
	}
	fprintf(stderr, "usage: dom_life_driver explore|cases|seeded\n");
	return (2);
}
