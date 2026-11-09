/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the domain library's planning entries with requests, manifest rows,
 * ids and row indexes the input chooses, and aborts when an invariant
 * breaks. The input patches valid starting values (see
 * LLVMFuzzerTestOneInput), so mutations reach deep fields and still plan.
 * An accepted plan must:
 *
 *   pass erx_dom_plan_check, carry the origin of the entry that made it
 *   and the CPU parent that origin selects;
 *   for a request, hold zeros past the arguments and environment;
 *   name a free record and an id no record holds;
 *   fit what each carved budget pays for within its size (the outer
 *   budget's crash area and system child, the child's sides and bells);
 *   undo, once fully applied, by destroying exactly its carved budgets,
 *   the last carved first;
 *   record into the view it was planned against, leaving the domain's
 *   record, its principal within its quota and budget, the service
 *   grants and its system connection's row as the plan named them, so a
 *   second plan of the same id is refused.
 * A connection's plan, likewise, records into its view, and a second plan
 * of the same pair takes another row and the next number.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/dom.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define FUZZ_MIB	(UINT64_C(1) << 20)

static const erx_dom_t fuzz_domains[2] = { { .id = 9 }, { 0 } };
static const erx_dom_connection_t fuzz_connections[2] = {
	{ .number = 1 }, { 0 }
};

static const erx_dom_file_t fuzz_files[] = {
	{ ERX_ENTRY_IMAGE, 0, true, 0, 1 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_IMAGE, 0, true, ERX_IMAGE_JIT, 2 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, 0, false, 0, 3 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, 0, false, 0, 4 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SYSTEM, false, 0, 5 * ERX_PAGE_SIZE, 100 },
	{ ERX_ENTRY_FILE, ERX_ENTRY_SEAL, false, 0, 6 * ERX_PAGE_SIZE, 100 },
};

static erx_grant_t
fuzz_grant(uint64_t quota, uint64_t cpuset)
{
	erx_grant_t grant;

	memset(&grant, 0, sizeof(grant));
	grant.quota_ns = quota;
	grant.period_ns = quota == ERX_QUOTA_NONE ? 0 : UINT64_C(10000000);
	grant.cpuset = cpuset;
	grant.ceiling.raw = 40;
	return (grant);
}

static erx_runtime_limits_t
fuzz_limits(uint32_t scale)
{
	return ((erx_runtime_limits_t){ .max_frame = 65536 * scale,
	    .max_message_heap = 1048576 * scale, .funnel_depth = 64 * scale,
	    .exports = 256 * scale, .tmp = FUZZ_MIB * scale,
	    .overlay = FUZZ_MIB * scale, .atoms = 4096 * scale,
	    .foreign_atoms = 1024 * scale, .processes = 1024 * scale,
	    .peer_held = FUZZ_MIB * scale,
	    .peer_held_total = 4 * FUZZ_MIB * scale });
}

/* The size a plan carves for budget, or 0 when it carves none. */
static uint64_t
fuzz_carved(const erx_dom_plan_t *plan, erx_dom_obj_t budget)
{
	for (uint32_t index = 0; index < plan->nsteps; index++)
		if (plan->steps[index].kind == ERX_DOM_STEP_CARVE &&
		    plan->steps[index].obj == budget)
			return (plan->steps[index].size);
	return (0);
}

/* The bytes a plan charges or carves on budget; bells cost their reserve. */
static uint64_t
fuzz_charged(const erx_dom_plan_t *plan, erx_dom_obj_t budget)
{
	const erx_dom_step_t *step;
	uint64_t total = 0;

	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		if (step->budget != budget)
			continue;
		if (step->kind == ERX_DOM_STEP_CARVE ||
		    step->kind == ERX_DOM_STEP_MEM)
			total += step->size;
		else if (step->kind == ERX_DOM_STEP_BELL)
			total += ERX_DOM_BELL_BYTES;
	}
	return (total);
}

/*
 * Everything one run lets the input choose: the request and its limits,
 * the configured and partial-boot rows, and the id and row the entries
 * plan. Patches overwrite it starting from valid values.
 */
typedef struct fuzz_input {
	erx_dom_spec_t		req;
	erx_runtime_limits_t	limits;
	uint32_t		given, id, row;
	erx_dom_configured_t	configured;
	erx_dom_partial_t	partial;
	/* The entries after creation: their records, rows and arguments. */
	erx_dom_t		doms[3];
	erx_dom_connection_t	conns[3];
	uint32_t		a, b, a_reads, b_reads, number, next;
	uint64_t		label;
	erx_fault_t		record;
	/* A device's give over the input's catalogue, and a principal's check. */
	erx_dom_device_entry_t	devs[2];
	erx_dom_device_t	dev_records[2];
	uint32_t		dev_index;
	erx_dom_principal_t	principal;
} fuzz_input_t;

/*
 * The entries after creation over the input's records and rows: connect
 * (connect true), or disconnect, retire, stop and the record step. Each
 * result names only records and rows the view holds, a connection's plan
 * passes its check with each object on its reader's child, and its undo
 * is its two carves, last first. A device's give names a living holder
 * and a device no living domain holds, passes its check, sizes each window
 * by its range, and undoes every object it made; a principal's record
 * starts with no counts.
 */
static void
fuzz_life(const fuzz_input_t *in, bool connect)
{
	erx_dom_principal_t held = { .number = 1 };
	erx_dom_t doms[3];
	erx_dom_connection_t conns[3];
	erx_dom_device_entry_t devs[2];
	erx_dom_view_t view = { .domains = doms, .max_domains = 3,
	    .connections = conns, .max_connections = 3,
	    .next_connection = in->next, .system_space = 4000,
	    .devices = devs, .device_records = in->dev_records,
	    .ndevices = 2, .principals = &held, .nprincipals = 1 };
	erx_dom_link_plan_t link, again;
	erx_dom_device_plan_t give;
	erx_dom_obj_t made[ERX_DOM_DEVICE_STEPS];
	erx_dom_principal_t principal;
	uint32_t nmade;
	erx_dom_teardown_t teardown;
	erx_dom_action_t action;
	erx_dom_obj_t undo[ERX_DOM_LINK_STEPS];
	uint8_t raw;

	/* The library writes its own records, so a flag is always a bool. */
	memcpy(doms, in->doms, sizeof(doms));
	memcpy(conns, in->conns, sizeof(conns));
	for (uint32_t index = 0; index < 3; index++) {
		memcpy(&raw, &conns[index].closing, 1);
		conns[index].closing = (raw & 1) != 0;
	}
	memcpy(devs, in->devs, sizeof(devs));
	for (uint32_t index = 0; index < 2; index++) {
		memcpy(&raw, &devs[index].confined, 1);
		devs[index].confined = (raw & 1) != 0;
	}

	if (connect) {
		if (erx_dom_plan_connect(&view, in->a, in->b, in->a_reads,
		    in->b_reads, &link) != ERX_OK)
			return;
		if (erx_dom_link_check(&link) != ERX_OK || link.a == link.b ||
		    link.a_slot >= 3 || link.b_slot >= 3 || link.row >= 3 ||
		    doms[link.a_slot].id != in->a ||
		    doms[link.b_slot].id != in->b ||
		    conns[link.row].number != 0 || link.number != in->next ||
		    erx_dom_link_undo(&link, link.nsteps, undo) != 2 ||
		    undo[0] != ERX_DOM_OBJ_LINK_BUDGET_B ||
		    undo[1] != ERX_DOM_OBJ_LINK_BUDGET_A)
			abort();
		for (uint32_t index = 0; index < link.nsteps; index++)
			if ((link.steps[index].obj == ERX_DOM_OBJ_SIDE_A &&
			    link.steps[index].kind == ERX_DOM_STEP_MEM &&
			    link.steps[index].budget != ERX_DOM_OBJ_LINK_BUDGET_B) ||
			    (link.steps[index].obj == ERX_DOM_OBJ_SIDE_B &&
			    link.steps[index].kind == ERX_DOM_STEP_MEM &&
			    link.steps[index].budget != ERX_DOM_OBJ_LINK_BUDGET_A))
				abort();
		/* The record is what the next plan of the pair sees. */
		if (erx_dom_link_record(&view, &link) != ERX_OK ||
		    conns[link.row].number != link.number ||
		    conns[link.row].a != in->a || conns[link.row].b != in->b ||
		    doms[link.a_slot].labels != link.steps[4].label ||
		    doms[link.b_slot].labels != link.steps[5].label ||
		    view.next_connection != (link.number == UINT32_MAX ? 0 :
		    link.number + 1))
			abort();
		if (erx_dom_plan_connect(&view, in->a, in->b, in->a_reads,
		    in->b_reads, &again) == ERX_OK &&
		    (again.row == link.row || again.number != view.next_connection))
			abort();
		return;
	}
	if (erx_dom_plan_disconnect(&view, in->number, &teardown) == ERX_OK &&
	    (teardown.index >= 3 || in->number == 0 ||
	    conns[teardown.index].number != in->number ||
	    teardown.ndestroy == 0 || teardown.ndestroy > 2))
		abort();
	if (erx_dom_plan_retire(&view, in->a, &teardown) == ERX_OK) {
		if (teardown.index >= 3 ||
		    doms[teardown.index].state != ERX_DOM_ENDED)
			abort();
		for (uint32_t index = 0; index < 3; index++)
			if (conns[index].number != 0 &&
			    (conns[index].a == in->a ||
			    conns[index].b == in->a))
				abort();
	}
	if (erx_dom_plan_stop(&view, in->b, in->record.status, &action) ==
	    ERX_OK && (action.slot >= 3 || doms[action.slot].id != in->b))
		abort();
	erx_dom_record_step(&view, in->label, &in->record, &action);
	if (action.kind != ERX_DOM_ACT_DROP && (action.slot >= 3 ||
	    doms[action.slot].id != in->label ||
	    (doms[action.slot].state != ERX_DOM_BUILT &&
	    doms[action.slot].state != ERX_DOM_RUNNING)))
		abort();
	if (erx_dom_plan_device_give(&view, in->a, in->dev_index, &give) ==
	    ERX_OK) {
		nmade = 0;
		for (uint32_t index = 0; index < give.nsteps; index++)
			nmade += give.steps[index].kind != ERX_DOM_STEP_INSTALL;
		if (erx_dom_device_check(&give) != ERX_OK || give.index >= 2 ||
		    give.slot >= 3 || doms[give.slot].id != in->a ||
		    (doms[give.slot].state != ERX_DOM_BUILT &&
		    doms[give.slot].state != ERX_DOM_RUNNING) ||
		    erx_dom_device_undo(&give, give.nsteps, made) != nmade)
			abort();
		for (uint32_t index = 0; index < 3; index++)
			if (doms[index].id != 0 &&
			    doms[index].id == in->dev_records[give.index].holder &&
			    (doms[index].state == ERX_DOM_BUILT ||
			    doms[index].state == ERX_DOM_RUNNING))
				abort();
		for (uint32_t index = 0; index < give.nsteps; index++)
			if (give.steps[index].kind == ERX_DOM_STEP_WINDOW &&
			    (give.steps[index].index >= ERX_DEVICE_RANGES_MAX ||
			    give.steps[index].size !=
			    devs[give.index].ranges[give.steps[index].index].size))
				abort();
	}
	if (erx_dom_principal_check(&view, &in->principal, &principal) ==
	    ERX_OK && (principal.carved != 0 || principal.domains != 0 ||
	    principal.number == held.number ||
	    principal.number != in->principal.number ||
	    principal.memory == 0 || principal.memory % ERX_PAGE_SIZE != 0))
		abort();
}

static void
fuzz_check(const fuzz_input_t *in, uint32_t origin, const erx_dom_view_t *view,
    const erx_dom_plan_t *plan)
{
	const erx_dom_spec_t *spec = &plan->spec;
	erx_dom_obj_t undo[ERX_DOM_PLAN_STEPS_MAX];
	uint32_t count, carves = 0;
	size_t used;

	if (erx_dom_plan_check(plan) != ERX_OK ||
	    plan->nsteps > ERX_DOM_PLAN_STEPS_MAX ||
	    spec->origin.kind != origin ||
	    plan->parent != (origin == ERX_DOM_CONFIGURED ?
	    ERX_DOM_PARENT_SYSTEM : ERX_DOM_PARENT_PRINCIPAL))
		abort();
	if (origin == ERX_DOM_REQUEST) {
		used = (size_t)in->req.args_len + in->req.env_len;
		for (size_t index = used; index < sizeof(spec->strings); index++)
			if (spec->strings[index] != 0)
				abort();
	}
	if (spec->id <= ERX_DOM_SYSTEM_ID || plan->slot >= view->max_domains ||
	    view->domains[plan->slot].id != 0)
		abort();
	for (uint32_t index = 0; index < view->max_domains; index++)
		if (view->domains[index].id == spec->id)
			abort();
	if (fuzz_charged(plan, ERX_DOM_OBJ_OUTER) >
	    fuzz_carved(plan, ERX_DOM_OBJ_OUTER) ||
	    fuzz_charged(plan, ERX_DOM_OBJ_SYS_BUDGET) >
	    fuzz_carved(plan, ERX_DOM_OBJ_SYS_BUDGET))
		abort();

	count = erx_dom_plan_undo(plan, plan->nsteps, undo);
	for (uint32_t index = plan->nsteps; index > 0; index--) {
		if (plan->steps[index - 1].kind != ERX_DOM_STEP_CARVE)
			continue;
		if (carves >= count || undo[carves] != plan->steps[index - 1].obj)
			abort();
		carves++;
	}
	if (carves != count)
		abort();
}

/*
 * Records an accepted plan into the view it was planned against: it must
 * fit, and leave the record, the principal's counts within its quota and
 * budget, the service grants and the system connection's row as the plan
 * named them.
 */
static void
fuzz_record(erx_dom_view_t *view, const erx_dom_plan_t *plan)
{
	const erx_dom_spec_t *spec = &plan->spec;
	const erx_dom_principal_t *principal = &view->principals[0];
	const erx_dom_t *dom = &view->domains[plan->slot];
	const erx_dom_connection_t *row;
	uint32_t services = view->nservice_grants;

	if (erx_dom_plan_record(view, plan) != ERX_OK || dom->id != spec->id ||
	    dom->state != ERX_DOM_BUILT ||
	    dom->system_connection != plan->connection ||
	    principal->domains > principal->domains_max ||
	    principal->carved > principal->memory ||
	    view->nservice_grants != services +
	    (spec->origin.kind == ERX_DOM_CONFIGURED) ||
	    view->nservice_grants > view->max_domains)
		abort();
	if (plan->connection_row != ERX_DOM_NO_ROW) {
		row = &view->connections[plan->connection_row];
		if (row->number != plan->connection ||
		    row->a != ERX_DOM_SYSTEM_ID || row->b != spec->id)
			abort();
	}
}

/*
 * The input: one byte picking the entry (0 request, 1 configured, 2
 * partial boot, 3 connect, 4 disconnect, retire, stop and the record
 * step), then patches, each a little-endian u16 offset into the
 * fuzz_input_t (modulo its size), a length byte and that many bytes,
 * clipped at its end.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_dom_principal_t principal = { .number = 1, .memory = 64 * FUZZ_MIB,
	    .domains_max = 4, .share = fuzz_grant(UINT64_C(20000000), 0xf),
	    .default_limits = fuzz_limits(1), .ceiling_limits = fuzz_limits(2) };
	fuzz_input_t in = {
		.req = { .id = 5, .principal = 1, .release = 2,
		    .release_files = 2, .memory = 4 * FUZZ_MIB, .outer = FUZZ_MIB,
		    .grant = fuzz_grant(UINT64_C(10000000), 0x3), .lane = 65536,
		    .connections = 2, .args_len = 2, .strings = "a" },
		.limits = fuzz_limits(1), .given = 0, .id = 6, .row = 0,
		.configured = { .principal = 1, .flags = ERX_DOM_SPACES,
		    .release = 2, .release_files = 2, .runtime = 1,
		    .memory = 4 * FUZZ_MIB, .outer = FUZZ_MIB,
		    .grant = fuzz_grant(UINT64_C(5000000), 0x3),
		    .spaces = fuzz_grant(UINT64_C(2500000), 0x1),
		    .runtime_limits = fuzz_limits(1), .lane = 65536,
		    .connections = 2 },
		.partial = { .runtime = 0, .memory = FUZZ_MIB, .outer = 64 * 1024,
		    .grant = fuzz_grant(UINT64_C(1000000), 0x1) },
		.doms = { { .id = 5, .state = ERX_DOM_RUNNING, .budget = { 51 },
		    .outer = { 52 }, .connections = 2, .labels = 1 },
		    { .id = 6, .state = ERX_DOM_ENDED, .budget = { 61 },
		    .outer = { 62 }, .connections = 2, .labels = 1 },
		    { .id = 7, .state = ERX_DOM_BUILT, .budget = { 71 },
		    .outer = { 72 }, .connections = 1, .labels = 1 } },
		.conns = { { .number = 1, .a = ERX_DOM_SYSTEM_ID, .b = 5,
		    .budget_b = { 53 } }, { .number = 2, .a = 5, .b = 6,
		    .budget_a = { 54 }, .budget_b = { 63 }, .closing = true } },
		.a = 5, .b = 7, .a_reads = 65536, .b_reads = 16384, .number = 2,
		.next = 3, .label = 5, .record = { .kind = ERX_FAULT_EXIT },
		.devs = { { .nranges = 1, .nlines = 1,
		    .ranges = { { 0x0a003000, 0x1000 } }, .memory = FUZZ_MIB },
		    { .nranges = 2, .nlines = 2, .ranges = { { 0x10000000, 0x4000 },
		    { 0x10010000, 0x1000 } }, .confined = true } },
		.dev_records = { { .index = 0 }, { .index = 1, .holder = 6 } },
		.principal = { .number = 2, .memory = 16 * FUZZ_MIB, .domains_max = 2,
		    .share = fuzz_grant(UINT64_C(5000000), 0x3),
		    .default_limits = fuzz_limits(1), .ceiling_limits = fuzz_limits(2) },
	};
	erx_dom_t domains[2];
	erx_dom_connection_t connections[2];
	erx_grant_t services[2];
	erx_dom_view_t view = { .domains = domains, .max_domains = 2,
	    .connections = connections, .max_connections = 2,
	    .service_grants = services,
	    .principals = &principal, .nprincipals = 1, .files = fuzz_files,
	    .nfiles = sizeof(fuzz_files) / sizeof(fuzz_files[0]),
	    .configured = &in.configured, .nconfigured = 1,
	    .partial = &in.partial, .npartial = 1, .partial_principal = 1,
	    .native_limits = fuzz_limits(1),
	    .system_grant = fuzz_grant(ERX_QUOTA_NONE, 0xf),
	    .system_reserve = 250, .system_lane = 16384,
	    .next_connection = 1 };
	uint8_t *target = (uint8_t *)&in;
	erx_dom_plan_t plan;
	erx_status_t status;
	uint32_t origin;
	size_t at = 1, offset, count;

	if (length == 0)
		return (0);
	while (length - at >= 3) {
		offset = ((size_t)bytes[at] | (size_t)bytes[at + 1] << 8) %
		    sizeof(in);
		count = bytes[at + 2];
		at += 3;
		if (count > length - at)
			count = length - at;
		if (count > sizeof(in) - offset)
			count = sizeof(in) - offset;
		memcpy(target + offset, bytes + at, count);
		at += count;
	}

	/* Each run starts from the same records; a record writes only these. */
	memcpy(domains, fuzz_domains, sizeof(domains));
	memcpy(connections, fuzz_connections, sizeof(connections));
	memset(services, 0, sizeof(services));
	if (bytes[0] % 5 >= 3) {
		fuzz_life(&in, bytes[0] % 5 == 3);
		return (0);
	}
	switch (bytes[0] % 3) {
	case 0:
		origin = ERX_DOM_REQUEST;
		status = erx_dom_plan_request(&view, &in.req, &in.limits,
		    in.given, &plan);
		break;
	case 1:
		origin = ERX_DOM_CONFIGURED;
		status = erx_dom_plan_configured(&view, in.id, in.row, &plan);
		break;
	default:
		origin = ERX_DOM_PARTIAL_BOOT;
		status = erx_dom_plan_partial(&view, in.id, in.row, &plan);
		break;
	}
	if (status != ERX_OK)
		return (0);
	fuzz_check(&in, origin, &view, &plan);
	fuzz_record(&view, &plan);
	switch (origin) {
	case ERX_DOM_REQUEST:
		status = erx_dom_plan_request(&view, &in.req, &in.limits,
		    in.given, &plan);
		break;
	case ERX_DOM_CONFIGURED:
		status = erx_dom_plan_configured(&view, in.id, in.row, &plan);
		break;
	default:
		status = erx_dom_plan_partial(&view, in.id, in.row, &plan);
		break;
	}
	if (status == ERX_OK)
		abort();
	return (0);
}
