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
 * Output is one line per result; the test compares them.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/dom.h"

#define NDOMAINS	5
#define NCONNECTIONS	4

static erx_dom_t domains[NDOMAINS];
static erx_dom_connection_t connections[NCONNECTIONS];
/* The one principal, which counts domain 7, the one a retire may take. */
static erx_dom_principal_t principals[1];
/* The system domain's space, as records name it; 77 is a domain's own. */
#define SYSTEM_SPACE	UINT64_C(4000)
static erx_dom_view_t view;
/* The catalogue: 0 an unconfined virtio-mmio transport, 1 a confined device. */
#define NDEVICES	3
static erx_dom_device_entry_t devices[NDEVICES];
static erx_dom_device_t device_records[NDEVICES];
static unsigned long failures;

static void	device_explore(void);
static void	link_record_cases(void);

static const char *const step_names[] = {
	"CARVE", "SPACE", "GROUP", "MEM", "BELL", "SLICE", "IMAGE_MAP", "MAP",
	"INSTALL", "BOOTINFO", "THREAD", "RESOURCE", "WINDOW", "IRQ", "DMA",
	"CONTIGUOUS"
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
	domains[0] = (erx_dom_t){ .id = 5, .state = ERX_DOM_RUNNING,
	    .budget = { 501 }, .outer = { 502 }, .connections = 2,
	    .labels = ERX_DOM_SYSTEM_LABEL };
	domains[1] = (erx_dom_t){ .id = 6, .state = ERX_DOM_BUILT,
	    .budget = { 601 }, .outer = { 602 }, .connections = 1, .labels = 3 };
	principals[0] = (erx_dom_principal_t){ .number = 1, .domains = 1 };
	domains[2] = (erx_dom_t){ .id = 7, .principal = 1, .state = ERX_DOM_ENDED,
	    .budget = { 701 }, .outer = { 702 }, .connections = 1, .labels = 1 };
	domains[3] = (erx_dom_t){ .id = 8, .state = ERX_DOM_BUILDING,
	    .budget = { 801 }, .outer = { 802 }, .connections = 1, .labels = 1 };
	connections[0] = (erx_dom_connection_t){ .number = 1,
	    .a = ERX_DOM_SYSTEM_ID, .b = 5, .budget_b = { 511 } };
	connections[1] = (erx_dom_connection_t){ .number = 2,
	    .a = ERX_DOM_SYSTEM_ID, .b = 6, .budget_b = { 611 } };
	view = (erx_dom_view_t){ .domains = domains, .max_domains = NDOMAINS,
	    .connections = connections, .max_connections = NCONNECTIONS,
	    .principals = principals, .nprincipals = 1, .next_connection = 20, .system_space = SYSTEM_SPACE,
	    .devices = devices, .device_records = device_records,
	    .ndevices = 2 };
	memset(devices, 0, sizeof(devices));
	memset(device_records, 0, sizeof(device_records));
	devices[0] = (erx_dom_device_entry_t){ .nranges = 1, .nlines = 1,
	    .ranges = { { 0x0a003000, 0x1000 } }, .memory = 0x100000 };
	devices[1] = (erx_dom_device_entry_t){ .nranges = 2, .nlines = 2,
	    .ranges = { { 0x10000000, 0x4000 }, { 0x10010000, 0x1000 } },
	    .confined = true };
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
	if (obj == ERX_DOM_OBJ_SIDE_B || obj == ERX_DOM_OBJ_BELL_A)
		return (ERX_DOM_OBJ_LINK_BUDGET_A);
	if (obj == ERX_DOM_OBJ_SIDE_A || obj == ERX_DOM_OBJ_BELL_B)
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

static int
explore(void)
{
	erx_dom_link_plan_t plan;
	erx_dom_teardown_t teardown;
	erx_dom_obj_t undo[ERX_DOM_LINK_STEPS];
	uint32_t count;
	model_t m;

	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, &plan) != ERX_OK) {
		printf("FAIL the valid connection was refused\n");
		return (1);
	}
	printf("steps");
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
	device_explore();
	printf("explore steps=%u failures=%lu\n", plan.nsteps, failures);
	return (failures == 0 ? 0 : 1);
}

static void
connect_case(const char *name, uint32_t a, uint32_t b, uint32_t a_reads,
    uint32_t b_reads)
{
	erx_dom_link_plan_t plan;
	erx_status_t status;

	status = erx_dom_plan_connect(&view, a, b, a_reads, b_reads, &plan);
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
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, &plan) != ERX_OK)
		failures++;
	link_record_case("record_ok", &plan);
	connect_case("record_then_quota", 5, 6, 65536, 16384);
	link_record_case("record_twice", &plan);

	/* A plan that no longer fits the view leaves it as it was. */
	reset_view();
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, &plan) != ERX_OK)
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
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 16384, &plan) != ERX_OK)
		failures++;
	link_record_case("record_last_number", &plan);
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
	printf("\n");
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
	connections[2] = (erx_dom_connection_t){ .number = 9, .a = 5, .b = 7,
	    .closing = true };
	teardown_case("retire_busy", erx_dom_plan_retire(&view, 7, &teardown),
	    &teardown);
	connections[2] = (erx_dom_connection_t){ .number = 9,
	    .a = ERX_DOM_SYSTEM_ID, .b = 7 };
	teardown_case("retire_busy_system",
	    erx_dom_plan_retire(&view, 7, &teardown), &teardown);
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

/* A device's give: its status, then its steps' kinds and its undo's size. */
static void
device_case(const char *name, uint32_t id, uint32_t index)
{
	erx_dom_device_plan_t plan;
	erx_dom_obj_t undo[ERX_DOM_DEVICE_STEPS];
	erx_status_t status = erx_dom_plan_device_give(&view, id, index, &plan);

	if (status != ERX_OK) {
		printf("dev %s %d\n", name, status);
		return;
	}
	printf("dev %s 0 slot=%u steps=", name, plan.slot);
	for (uint32_t step = 0; step < plan.nsteps; step++)
		printf("%s%s", step == 0 ? "" : ",",
		    step_names[plan.steps[step].kind]);
	printf(" undo=%u\n", erx_dom_device_undo(&plan, plan.nsteps, undo));
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

	reset_view();
	view.ndevices = 3;
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1,
	    .ranges = { { 0x0a002000, 0x2000 } } };
	device_case("dev_overlap", 5, 0);
	devices[2].ranges[0] = (erx_dom_range_t){ 0x0a004000, 0x1000 };
	device_case("dev_adjacent", 5, 0);
	devices[2] = (erx_dom_device_entry_t){ .nranges = 1,
	    .ranges = { { 0x0a000000, UINT64_MAX - 0x0a000000 + 1 } } };
	device_case("dev_overlap_wrapping", 5, 0);

	reset_view();
	devices[0].nranges = ERX_DEVICE_RANGES_MAX + 1;
	device_case("dev_ranges_over", 5, 0);
	reset_view();
	devices[0].nlines = ERX_DEVICE_IRQS_MAX + 1;
	device_case("dev_lines_over", 5, 0);
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
	erx_dom_device_plan_t plan;
	erx_dom_obj_t undo[ERX_DOM_DEVICE_STEPS];
	bool alive[ERX_DOM_OBJ_COUNT];
	uint32_t count, left;

	for (uint32_t index = 0; index < 2; index++) {
		reset_view();
		devices[1].nranges = ERX_DEVICE_RANGES_MAX;
		devices[1].nlines = ERX_DEVICE_IRQS_MAX;
		for (uint32_t range = 0; range < ERX_DEVICE_RANGES_MAX; range++)
			devices[1].ranges[range] = (erx_dom_range_t){
			    0x20000000 + range * 0x10000, 0x1000 };
		if (erx_dom_plan_device_give(&view, 5, index, &plan) != ERX_OK) {
			fail("a valid give was refused", index);
			continue;
		}
		for (uint32_t at = 0; at <= plan.nsteps; at++) {
			memset(alive, 0, sizeof(alive));
			for (uint32_t step = 0; step < at; step++)
				if (plan.steps[step].kind != ERX_DOM_STEP_INSTALL)
					alive[plan.steps[step].obj] = true;
			count = erx_dom_device_undo(&plan, at, undo);
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
	if (erx_dom_plan_connect(&view, 5, 6, 65536, 65536, &valid) != ERX_OK)
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
#undef SEED
}

/* Seeded gives: each breaks one rule erx_dom_device_check enforces. */
static void
device_seeded(void)
{
	erx_dom_device_plan_t valid, plan;
	const erx_dom_step_t dma = { .kind = ERX_DOM_STEP_DMA,
	    .obj = ERX_DOM_OBJ_DEV_DMA, .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
	    .target = ERX_DOM_OBJ_DEV_RESOURCE };
	uint32_t last;

	reset_view();
	if (erx_dom_plan_device_give(&view, 5, 0, &valid) != ERX_OK)
		failures++;
	last = valid.nsteps - 1;
	printf("seeded dev_valid %d\n", erx_dom_device_check(&valid));
#define	SEED(name, edit) do {						\
	plan = valid;							\
	edit;								\
	printf("seeded %s %d\n", name, erx_dom_device_check(&plan));	\
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
	SEED("dev_window_index", plan.steps[1].index = 1);
	SEED("dev_out_of_order", {
		erx_dom_step_t first = plan.steps[0];
		plan.steps[0] = plan.steps[1];
		plan.steps[1] = first;
	});
	SEED("dev_dma_and_memory", plan.steps[plan.nsteps++] = dma);
	SEED("dev_system_holder", plan.holder = ERX_DOM_SYSTEM_ID);
	SEED("dev_too_many", plan.nsteps = ERX_DOM_DEVICE_STEPS + 1);
	device_records[0].memory = (erx_cap_t){ 77 };
	if (erx_dom_plan_device_give(&view, 5, 0, &valid) != ERX_OK)
		failures++;
	SEED("dev_kept_not_last", {
		erx_dom_step_t kept = plan.steps[plan.nsteps - 1];
		plan.steps[plan.nsteps - 1] = plan.steps[plan.nsteps - 2];
		plan.steps[plan.nsteps - 2] = kept;
	});
	reset_view();
	device_records[0].index = 1;
	printf("seeded dev_record_index %d\n", erx_dom_plan_device_give(&view, 5, 0, &plan));
#undef SEED
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "explore") == 0)
		return (explore());
	if (argc == 2 && strcmp(argv[1], "cases") == 0) {
		connect_cases();
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
