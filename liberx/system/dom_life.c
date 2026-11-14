/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's pure core after creation (docs/design-system.md,
 * "Introducing two domains" and "Ending a domain"): the connection planner
 * with its check, undo and record; the teardowns of disconnect, the
 * destroy at an exit record and retire; the end classifier; and the steps
 * that turn a record at the library's fault gate, or a stop request,
 * into what the library does next; and a device's give with its check and undo
 * ("Devices"). Nothing here performs a kernel call.
 *
 * A domain's end runs through its record's states: built or running; then,
 * once the library stops it, stopping with the reason noted; then, at its
 * exit record, ended, with its own budget destroyed and its end
 * classified; then retired as soon as the domain service has read its
 * crash area: the record is freed, and the outer budget is destroyed or,
 * while connection rows still name the domain, kept as its remains, which
 * the disconnect of the last such row destroys.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/dom.h"
#include "erx/lane.h"

static bool	life_add(uint64_t, uint64_t, uint64_t *);
static bool	life_alive(const erx_dom_t *);
static erx_dom_principal_t *life_principal(const erx_dom_view_t *, uint32_t);
static bool	life_gives_back(const erx_dom_view_t *, const erx_dom_t *);
static uint32_t	life_slot(const erx_dom_view_t *, uint64_t);
static uint32_t	life_connections(const erx_dom_view_t *, uint32_t);
static uint32_t	life_rows_naming(const erx_dom_view_t *, uint32_t);
static uint32_t	life_remains(const erx_dom_view_t *, uint32_t);
static uint32_t	life_remains_free(const erx_dom_view_t *);
static uint32_t	life_remains_last(const erx_dom_view_t *, uint32_t);
static bool	life_remains_held(const erx_dom_view_t *, const erx_dom_teardown_t *);
static bool	life_room(const erx_dom_view_t *, const erx_dom_t *);
static bool	life_granted(const erx_dom_step_t *);
static bool	life_step_ok(const erx_dom_step_t *, const bool *);
static bool	life_range_ok(const erx_dom_range_t *);
static bool	life_entry_ok(const erx_dom_device_entry_t *);
static uint64_t	life_range_end(const erx_dom_range_t *);
static bool	life_overlaps(const erx_dom_view_t *, uint32_t);

/*
 * A give's windows (life_unit_layout): its page runs, and for each of its
 * devices the run its first range lies in, ERX_DOM_UNIT_NONE for none,
 * and its registers' offset into it.
 */
typedef struct life_layout {
	uint32_t	nruns;
	erx_dom_range_t	runs[ERX_DOM_UNIT_WINDOWS_MAX];
	uint32_t	window[ERX_DOM_DEVICES_MAX];
	uint64_t	offset[ERX_DOM_DEVICES_MAX];
} life_layout_t;
static erx_dom_obj_t life_grant_key(erx_dom_obj_t);

static bool
life_add(uint64_t a, uint64_t b, uint64_t *sum)
{
	return (!__builtin_add_overflow(a, b, sum));
}

/* A domain the library may connect, stop or see a record of. */
static bool
life_alive(const erx_dom_t *dom)
{
	return (dom->state == ERX_DOM_BUILT || dom->state == ERX_DOM_RUNNING);
}

/* The principal numbered number, or NULL. */
static erx_dom_principal_t *
life_principal(const erx_dom_view_t *view, uint32_t number)
{
	for (uint32_t index = 0; number != 0 && index < view->nprincipals; index++)
		if (view->principals[index].number == number)
			return (&view->principals[index]);
	return (NULL);
}

/*
 * Whether dom's principal counts it, so its retire can give the domain
 * and the bytes of both its budgets back without wrapping either count.
 */
static bool
life_gives_back(const erx_dom_view_t *view, const erx_dom_t *dom)
{
	const erx_dom_principal_t *principal = life_principal(view, dom->principal);
	uint64_t bytes;

	return (principal != NULL && principal->domains != 0 &&
	    life_add(dom->own_bytes, dom->outer_bytes, &bytes) &&
	    principal->carved >= bytes);
}

/*
 * The record of domain id, or max_domains for none. Id 0 is a free
 * record's, and the system domain has no record, so neither names one.
 */
static uint32_t
life_slot(const erx_dom_view_t *view, uint64_t id)
{
	if (id <= ERX_DOM_SYSTEM_ID || id > ERX_DOM_ID_MAX)
		return (view->max_domains);
	for (uint32_t index = 0; index < view->max_domains; index++)
		if (view->domains[index].id == id)
			return (index);
	return (view->max_domains);
}

/*
 * The connections that count against domain id's quota: every row naming
 * it but its system connection, closing rows included, since a closing
 * row keeps its pages until the disconnect.
 */
static uint32_t
life_connections(const erx_dom_view_t *view, uint32_t id)
{
	const erx_dom_connection_t *row;
	uint32_t count = 0;

	for (uint32_t index = 0; index < view->max_connections; index++) {
		row = &view->connections[index];
		if (row->number != 0 && row->a != ERX_DOM_SYSTEM_ID &&
		    (row->a == id || row->b == id))
			count++;
	}
	return (count);
}

/*
 * The rows naming id, its system connection included; life_connections
 * counts the same rows less the system connection, for the quota.
 */
static uint32_t
life_rows_naming(const erx_dom_view_t *view, uint32_t id)
{
	const erx_dom_connection_t *row;
	uint32_t count = 0;

	for (uint32_t index = 0; index < view->max_connections; index++) {
		row = &view->connections[index];
		if (row->number != 0 && (row->a == id || row->b == id))
			count++;
	}
	return (count);
}

/* The remains row of retired domain id, or max_remains for none; 0 names none. */
static uint32_t
life_remains(const erx_dom_view_t *view, uint32_t id)
{
	for (uint32_t index = 0; id != 0 && index < view->max_remains; index++)
		if (view->remains[index].id == id)
			return (index);
	return (view->max_remains);
}

/* A free remains row, or max_remains for none. */
static uint32_t
life_remains_free(const erx_dom_view_t *view)
{
	for (uint32_t index = 0; index < view->max_remains; index++)
		if (view->remains[index].id == 0)
			return (index);
	return (view->max_remains);
}

/*
 * The remains row that a disconnect of a row naming id destroys: id's,
 * when the row is the last naming it; max_remains when id has none or
 * another row still names it.
 */
static uint32_t
life_remains_last(const erx_dom_view_t *view, uint32_t id)
{
	const uint32_t index = life_remains(view, id);

	if (index == view->max_remains || life_rows_naming(view, id) != 1)
		return (view->max_remains);
	return (index);
}

/*
 * Whether each principal of the remains a disconnect destroys holds
 * their bytes, summed per principal, so the record cannot wrap a count.
 */
static bool
life_remains_held(const erx_dom_view_t *view, const erx_dom_teardown_t *teardown)
{
	const erx_dom_remains_t *remains;
	const erx_dom_principal_t *principal;
	uint64_t bytes;

	for (uint32_t index = 0; index < teardown->nremains; index++) {
		remains = &view->remains[teardown->remains[index]];
		principal = life_principal(view, remains->principal);
		bytes = 0;
		for (uint32_t other = 0; other < teardown->nremains; other++)
			if (view->remains[teardown->remains[other]].principal == remains->principal &&
			    !life_add(bytes, view->remains[teardown->remains[other]].bytes, &bytes))
				return (false);
		if (principal == NULL || principal->carved < bytes)
			return (false);
	}
	return (true);
}

/*
 * A pixel area's arguments: none (0 bytes, reader 0), or whole pages read
 * by one of the two parties.
 */
static bool
life_area_ok(uint32_t a, uint32_t b, uint64_t area, uint32_t area_reader)
{
	if (area == 0)
		return (area_reader == 0);
	return (area % ERX_PAGE_SIZE == 0 && (area_reader == a || area_reader == b));
}

/* Room for one more connection: its quota and a bell label below the split. */
static bool
life_room(const erx_dom_view_t *view, const erx_dom_t *dom)
{
	return (life_connections(view, dom->id) < dom->connections &&
	    dom->labels >= ERX_DOM_SYSTEM_LABEL &&
	    dom->labels < ERX_LABEL_SPLIT - 1);
}

erx_status_t
erx_dom_plan_connect(const erx_dom_view_t *view, uint32_t a, uint32_t b,
    uint32_t a_reads, uint32_t b_reads, uint64_t area, uint32_t area_reader,
    erx_dom_link_plan_t *plan)
{
	const erx_dom_t *da, *db;
	const erx_dom_grant_row_t *row;
	erx_dom_link_plan_t draft = { .a = a, .b = b, .area_reader = area_reader };
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	uint64_t side_a = erx_lane_side_bytes(b_reads);
	uint64_t side_b = erx_lane_side_bytes(a_reads);
	uint64_t child_a, child_b;

	draft.a_slot = life_slot(view, a);
	draft.b_slot = life_slot(view, b);
	if (a == b || draft.a_slot == view->max_domains ||
	    draft.b_slot == view->max_domains || side_a == 0 || side_b == 0 ||
	    !life_add(side_b, ERX_DOM_BELL_BYTES, &child_a) ||
	    !life_add(side_a, ERX_DOM_BELL_BYTES, &child_b) ||
	    !life_area_ok(a, b, area, area_reader))
		return (ERX_EINVAL);
	/* The pixel area joins the side its reader reads on that reader's child. */
	if (area_reader == a && !life_add(child_a, area, &child_a))
		return (ERX_EINVAL);
	if (area_reader == b && !life_add(child_b, area, &child_b))
		return (ERX_EINVAL);
	da = &view->domains[draft.a_slot];
	db = &view->domains[draft.b_slot];
	if (!life_alive(da) || !life_alive(db))
		return (ERX_EINVAL);
	if (!life_room(view, da) || !life_room(view, db) ||
	    view->next_connection == 0)
		return (ERX_ELIMIT);
	draft.row = view->max_connections;
	for (uint32_t index = 0; index < view->max_connections; index++) {
		if (view->connections[index].number == 0) {
			draft.row = index;
			break;
		}
	}
	if (draft.row == view->max_connections)
		return (ERX_ELIMIT);
	draft.number = view->next_connection;

	/* Every page of a connection is charged to the party that reads it. */
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_CARVE, .obj = ERX_DOM_OBJ_LINK_BUDGET_A,
	    .budget = ERX_DOM_OBJ_OUTER_A, .size = child_a };
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_CARVE, .obj = ERX_DOM_OBJ_LINK_BUDGET_B,
	    .budget = ERX_DOM_OBJ_OUTER_B, .size = child_b };
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_MEM, .obj = ERX_DOM_OBJ_SIDE_B,
	    .budget = ERX_DOM_OBJ_LINK_BUDGET_A, .size = side_b };
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_MEM, .obj = ERX_DOM_OBJ_SIDE_A,
	    .budget = ERX_DOM_OBJ_LINK_BUDGET_B, .size = side_a };
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_BELL, .obj = ERX_DOM_OBJ_BELL_A,
	    .budget = ERX_DOM_OBJ_LINK_BUDGET_A, .target = ERX_DOM_OBJ_GROUP_A,
	    .label = da->labels + 1 };
	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_BELL, .obj = ERX_DOM_OBJ_BELL_B,
	    .budget = ERX_DOM_OBJ_LINK_BUDGET_B, .target = ERX_DOM_OBJ_GROUP_B,
	    .label = db->labels + 1 };
	/*
	 * The pixel area, like a side, is named by its writer and charged to
	 * its reader's child, so the rows of erx_dom_grants give the writer
	 * write access and the reader read access alone.
	 */
	if (area != 0)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_MEM,
		    .obj = area_reader == b ? ERX_DOM_OBJ_AREA_A : ERX_DOM_OBJ_AREA_B,
		    .budget = area_reader == b ? ERX_DOM_OBJ_LINK_BUDGET_B :
		    ERX_DOM_OBJ_LINK_BUDGET_A, .size = area };
	for (uint32_t index = 0; index < draft.nsteps; index++)
		made[draft.steps[index].obj] = true;
	/* Each party's share comes from erx_dom_grants alone (A7), of what it made. */
	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if ((row->target != ERX_DOM_OBJ_SPACE_A &&
		    row->target != ERX_DOM_OBJ_SPACE_B) ||
		    row->obj >= ERX_DOM_OBJ_MADE_COUNT || !made[row->obj])
			continue;
		if (draft.nsteps == ERX_DOM_LINK_STEPS)
			return (ERX_EINVAL);
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_INSTALL, .obj = row->obj,
		    .target = row->target, .rights = row->rights };
	}
	if (erx_dom_link_check(&draft) != ERX_OK)
		return (ERX_EINVAL);
	*plan = draft;
	return (ERX_OK);
}

/* An install has a row of erx_dom_grants for its object and space that covers it. */
static bool
life_granted(const erx_dom_step_t *step)
{
	const erx_dom_grant_row_t *row;

	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if (row->obj == life_grant_key(step->obj) &&
		    row->target == step->target &&
		    row->flags == 0 && (step->rights & ~row->rights) == 0)
			return (true);
	}
	return (false);
}

/*
 * One step of a connection against what the steps before it made. The
 * pairs below are the charging rule: each child from its own party's
 * outer budget, the side a reads (b's), a's bell and the pixel area a reads
 * (AREA_B) on a's child, and the same for b; a connection has one area at
 * most.
 */
static bool
life_step_ok(const erx_dom_step_t *step, const bool *made)
{
	erx_dom_obj_t obj = step->obj;
	bool fresh = obj < ERX_DOM_OBJ_MADE_COUNT && obj != ERX_DOM_OBJ_NONE &&
	    !made[obj];
	bool charged = step->budget < ERX_DOM_OBJ_MADE_COUNT &&
	    made[step->budget];

	switch (step->kind) {
	case ERX_DOM_STEP_CARVE:
		return (fresh && step->size != 0 &&
		    ((obj == ERX_DOM_OBJ_LINK_BUDGET_A &&
		    step->budget == ERX_DOM_OBJ_OUTER_A) ||
		    (obj == ERX_DOM_OBJ_LINK_BUDGET_B &&
		    step->budget == ERX_DOM_OBJ_OUTER_B)));
	case ERX_DOM_STEP_MEM:
		return (fresh && charged && step->size != 0 &&
		    ((obj == ERX_DOM_OBJ_SIDE_B &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_A) ||
		    (obj == ERX_DOM_OBJ_SIDE_A &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_B) ||
		    (obj == ERX_DOM_OBJ_AREA_B && !made[ERX_DOM_OBJ_AREA_A] &&
		    step->size % ERX_PAGE_SIZE == 0 &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_A) ||
		    (obj == ERX_DOM_OBJ_AREA_A && !made[ERX_DOM_OBJ_AREA_B] &&
		    step->size % ERX_PAGE_SIZE == 0 &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_B)));
	case ERX_DOM_STEP_BELL:
		/* Label 1 is the system connection's (ERX_DOM_SYSTEM_LABEL). */
		return (fresh && charged && step->label > ERX_DOM_SYSTEM_LABEL &&
		    step->label < ERX_LABEL_SPLIT &&
		    ((obj == ERX_DOM_OBJ_BELL_A &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_A &&
		    step->target == ERX_DOM_OBJ_GROUP_A) ||
		    (obj == ERX_DOM_OBJ_BELL_B &&
		    step->budget == ERX_DOM_OBJ_LINK_BUDGET_B &&
		    step->target == ERX_DOM_OBJ_GROUP_B)));
	case ERX_DOM_STEP_INSTALL:
		return (obj < ERX_DOM_OBJ_MADE_COUNT && obj != ERX_DOM_OBJ_NONE &&
		    made[obj] && life_granted(step));
	case ERX_DOM_STEP_SPACE:
	case ERX_DOM_STEP_GROUP:
	case ERX_DOM_STEP_SLICE:
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_BOOTINFO:
	case ERX_DOM_STEP_THREAD:
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
	case ERX_DOM_STEP_GIVE:
		return (false);
	}
	return (false);
}

erx_status_t
erx_dom_link_check(const erx_dom_link_plan_t *plan)
{
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	const erx_dom_step_t *step;

	if (plan->nsteps > ERX_DOM_LINK_STEPS || plan->number == 0 ||
	    plan->a == plan->b)
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		if (step->budget >= ERX_DOM_OBJ_COUNT ||
		    step->target >= ERX_DOM_OBJ_COUNT ||
		    step->aux != ERX_DOM_OBJ_NONE || !life_step_ok(step, made))
			return (ERX_EINVAL);
		if (step->kind != ERX_DOM_STEP_INSTALL)
			made[step->obj] = true;
	}
	/* The reader the view records is the one the area is charged to. */
	if (plan->area_reader != (made[ERX_DOM_OBJ_AREA_A] ? plan->b :
	    made[ERX_DOM_OBJ_AREA_B] ? plan->a : 0))
		return (ERX_EINVAL);
	return (ERX_OK);
}

uint32_t
erx_dom_link_undo(const erx_dom_link_plan_t *plan, uint32_t applied,
    erx_dom_obj_t *undo)
{
	return (erx_dom_steps_undo(plan->steps, plan->nsteps, applied, undo));
}

erx_status_t
erx_dom_link_record(erx_dom_view_t *view, const erx_dom_link_plan_t *plan)
{
	erx_dom_connection_t *row;
	erx_dom_t *da, *db;

	/*
	 * Everything is checked before anything is written. life_slot names
	 * no record for an id outside the domains', so a slot that matches
	 * is in range.
	 */
	if (plan->a == plan->b || life_slot(view, plan->a) != plan->a_slot ||
	    life_slot(view, plan->b) != plan->b_slot ||
	    plan->a_slot == view->max_domains ||
	    plan->b_slot == view->max_domains ||
	    plan->row >= view->max_connections ||
	    view->connections[plan->row].number != 0 || plan->number == 0 ||
	    plan->number != view->next_connection)
		return (ERX_EINVAL);
	da = &view->domains[plan->a_slot];
	db = &view->domains[plan->b_slot];
	/* Each bell the plan bound takes its party's next label, below the split. */
	if (da->labels >= ERX_LABEL_SPLIT - 1 || db->labels >= ERX_LABEL_SPLIT - 1 ||
	    plan->steps[4].kind != ERX_DOM_STEP_BELL ||
	    plan->steps[4].label != da->labels + 1 ||
	    plan->steps[5].kind != ERX_DOM_STEP_BELL ||
	    plan->steps[5].label != db->labels + 1)
		return (ERX_EINVAL);

	row = &view->connections[plan->row];
	row->number = plan->number;
	row->a = plan->a;
	row->b = plan->b;
	row->area_reader = plan->area_reader;
	row->closing = false;
	da->labels++;
	db->labels++;
	/* Numbers only grow within a boot; 0 marks them spent. */
	view->next_connection = plan->number == UINT32_MAX ? 0 : plan->number + 1;
	return (ERX_OK);
}

erx_status_t
erx_dom_plan_disconnect(const erx_dom_view_t *view, uint32_t number,
    erx_dom_teardown_t *teardown)
{
	const erx_dom_connection_t *row;
	erx_dom_teardown_t draft = { .kind = ERX_DOM_DISCONNECT };
	uint32_t remains;

	if (number == 0)
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < view->max_connections; index++) {
		row = &view->connections[index];
		if (row->number != number)
			continue;
		draft.index = index;
		/* A system connection keeps both sides on the domain's child. */
		if (row->a != ERX_DOM_SYSTEM_ID)
			draft.destroy[draft.ndestroy++] = row->budget_a;
		draft.destroy[draft.ndestroy++] = row->budget_b;
		/*
		 * A retired party's remains go with the last row naming it. A
		 * system connection never names one: a retire waits for it.
		 */
		for (uint32_t party = 0; party < 2 && row->a != ERX_DOM_SYSTEM_ID; party++) {
			remains = life_remains_last(view, party == 0 ? row->a : row->b);
			if (remains != view->max_remains)
				draft.remains[draft.nremains++] = remains;
		}
		if (!life_remains_held(view, &draft))
			return (ERX_EINVAL);
		*teardown = draft;
		return (ERX_OK);
	}
	return (ERX_EINVAL);
}

void
erx_dom_disconnect_record(erx_dom_view_t *view,
    const erx_dom_teardown_t *teardown)
{
	erx_dom_remains_t *remains;

	/* erx_dom_plan_disconnect checked that each principal holds the bytes. */
	for (uint32_t index = 0; index < teardown->nremains; index++) {
		remains = &view->remains[teardown->remains[index]];
		life_principal(view, remains->principal)->carved -= remains->bytes;
		*remains = (erx_dom_remains_t){ .id = 0 };
	}
	view->connections[teardown->index] = (erx_dom_connection_t){ .number = 0 };
}

erx_status_t
erx_dom_plan_retire(const erx_dom_view_t *view, uint32_t id,
    erx_dom_teardown_t *teardown)
{
	const uint32_t slot = life_slot(view, id);
	const erx_dom_connection_t *row;
	const erx_dom_t *dom;
	uint32_t free;

	if (slot == view->max_domains ||
	    view->domains[slot].state != ERX_DOM_ENDED ||
	    !life_gives_back(view, &view->domains[slot]))
		return (ERX_EINVAL);
	dom = &view->domains[slot];
	/* The system connection's child holds both its sides, which the system domain unmaps first. */
	for (uint32_t index = 0; index < view->max_connections; index++) {
		row = &view->connections[index];
		if (row->number != 0 && row->a == ERX_DOM_SYSTEM_ID && row->b == id)
			return (ERX_EBUSY);
	}
	/* Every other child of an outer budget is a connection's (A5). */
	if (life_rows_naming(view, id) == 0) {
		*teardown = (erx_dom_teardown_t){ .kind = ERX_DOM_RETIRE,
		    .index = slot, .ndestroy = 1, .destroy = { dom->outer } };
		return (ERX_OK);
	}
	free = life_remains_free(view);
	if (free == view->max_remains)
		return (ERX_EINVAL);
	/* The crash area is read; only what a survivor maps outlives the domain. */
	*teardown = (erx_dom_teardown_t){ .kind = ERX_DOM_RETIRE,
	    .index = slot, .ndestroy = dom->crash.raw != ERX_CAP_NULL ? 1 : 0,
	    .destroy = { dom->crash }, .nremains = 1, .remains = { free } };
	return (ERX_OK);
}

void
erx_dom_retire_record(erx_dom_view_t *view,
    const erx_dom_teardown_t *teardown)
{
	erx_dom_t *dom = &view->domains[teardown->index];
	erx_dom_principal_t *principal = life_principal(view, dom->principal);

	/* erx_dom_plan_retire checked that the counts hold the domain. */
	principal->domains--;
	principal->carved -= dom->own_bytes;
	if (teardown->nremains == 0)
		principal->carved -= dom->outer_bytes;
	else
		view->remains[teardown->remains[0]] = (erx_dom_remains_t){
		    .id = dom->id, .principal = dom->principal,
		    .outer = dom->outer, .bytes = dom->outer_bytes };
	*dom = (erx_dom_t){ .id = 0 };
}

erx_dom_end_t
erx_dom_classify(const erx_fault_t *exit, uint64_t system_space,
    erx_dom_end_t noted)
{
	if (exit->space == system_space)
		return (noted.kind == ERX_DOM_END_FAULT ? noted :
		    (erx_dom_end_t){ ERX_DOM_END_STOPPED, 0 });
	if (exit->status == ERX_EXIT_CRASH)
		return ((erx_dom_end_t){ ERX_DOM_END_CRASH, 0 });
	return ((erx_dom_end_t){ ERX_DOM_END_HALT, exit->status });
}

void
erx_dom_record_step(const erx_dom_view_t *view, uint64_t label,
    const erx_fault_t *record, erx_dom_action_t *action)
{
	uint32_t slot = life_slot(view, label);
	const erx_dom_t *dom;

	*action = (erx_dom_action_t){ .kind = ERX_DOM_ACT_DROP,
	    .slot = slot };
	if (slot == view->max_domains || !life_alive(&view->domains[slot]))
		return;
	dom = &view->domains[slot];
	if (record->kind == ERX_FAULT_EXIT) {
		action->kind = ERX_DOM_ACT_END;
		action->end = erx_dom_classify(record, view->system_space,
		    dom->stop);
		action->teardown = (erx_dom_teardown_t){
		    .kind = ERX_DOM_DESTROY, .index = slot, .ndestroy = 1,
		    .destroy = { dom->budget } };
		return;
	}
	/* The first stop the library makes is the one its exit record names. */
	if (dom->stop.kind != ERX_DOM_END_NONE)
		return;
	action->kind = ERX_DOM_ACT_STOP;
	action->status = ERX_EXIT_CRASH;
	action->end = (erx_dom_end_t){ ERX_DOM_END_FAULT, record->kind };
}

erx_status_t
erx_dom_plan_stop(const erx_dom_view_t *view, uint32_t id, int64_t status,
    erx_dom_action_t *action)
{
	uint32_t slot = life_slot(view, id);

	/* The kernel's own exit statuses are its alone. */
	if (slot == view->max_domains || !life_alive(&view->domains[slot]) ||
	    status == ERX_EXIT_PARENT || status == ERX_EXIT_RELEASED ||
	    status == ERX_EXIT_NOTHREAD)
		return (ERX_EINVAL);
	*action = (erx_dom_action_t){ .kind = ERX_DOM_ACT_DROP, .slot = slot };
	if (view->domains[slot].stop.kind == ERX_DOM_END_NONE) {
		action->kind = ERX_DOM_ACT_STOP;
		action->status = status;
		action->end = (erx_dom_end_t){ ERX_DOM_END_STOPPED, 0 };
	}
	return (ERX_OK);
}

/* A range a register window can cover: page-aligned, nonempty, unwrapped. */
static bool
life_range_ok(const erx_dom_range_t *range)
{
	uint64_t end;

	return (range->size != 0 && range->base % ERX_PAGE_SIZE == 0 &&
	    range->size % ERX_PAGE_SIZE == 0 &&
	    life_add(range->base, range->size, &end));
}

/* An entry the ABI's limits can hold, with well-formed ranges. */
static bool
life_entry_ok(const erx_dom_device_entry_t *entry)
{
	if (entry->nranges > ERX_DEVICE_RANGES_MAX ||
	    entry->nlines > ERX_DEVICE_IRQS_MAX ||
	    (entry->confined && entry->memory != 0) ||
	    entry->memory % ERX_PAGE_SIZE != 0)
		return (false);
	for (uint32_t index = 0; index < entry->nranges; index++)
		if (!life_range_ok(&entry->ranges[index]))
			return (false);
	return (true);
}

/* The end of a range, or UINT64_MAX for one that wraps. */
static uint64_t
life_range_end(const erx_dom_range_t *range)
{
	uint64_t end;

	return (life_add(range->base, range->size, &end) ? end : UINT64_MAX);
}

/*
 * Some range of entry index meets a range of an entry of another unit, so
 * its window would reach registers another holder may have. Inside the
 * unit pages may be shared, by driven devices and devices of no kind
 * alike: the unit's one window covers them, and sharing inside a domain
 * is the domain's business (docs/design-shared-devices.md, "The unit
 * rule"). Entry index's ranges are well formed; another entry's are read
 * within the ABI's limit whatever their count says.
 */
static bool
life_overlaps(const erx_dom_view_t *view, uint32_t index)
{
	const erx_dom_device_entry_t *mine = &view->devices[index], *other;
	const erx_dom_range_t *a, *b;
	uint32_t count;

	for (uint32_t each = 0; each < view->ndevices; each++) {
		other = &view->devices[each];
		if (other->unit == mine->unit)
			continue;
		count = other->nranges < ERX_DEVICE_RANGES_MAX ?
		    other->nranges : ERX_DEVICE_RANGES_MAX;
		for (uint32_t i = 0; i < mine->nranges; i++) {
			a = &mine->ranges[i];
			for (uint32_t j = 0; j < count; j++) {
				b = &other->ranges[j];
				if (a->base < life_range_end(b) &&
				    b->base < life_range_end(a))
					return (true);
			}
		}
	}
	return (false);
}

/*
 * Whether entry names interrupt line number. The entry's lines are read
 * within the ABI's limit whatever its count says, as another entry's
 * ranges are.
 */
static bool
life_names_line(const erx_dom_device_entry_t *entry, uint32_t number)
{
	const uint32_t count = entry->nlines < ERX_DEVICE_IRQS_MAX ?
	    entry->nlines : ERX_DEVICE_IRQS_MAX;

	for (uint32_t line = 0; line < count; line++)
		if (entry->lines[line] == number)
			return (true);
	return (false);
}

/*
 * The give's devices: every entry of the unit, in catalogue order, each
 * placed on holder's row, well formed, meeting no entry of another unit,
 * and held by no living domain, with the facts its windows come from.
 */
static erx_status_t
life_unit_devices(const erx_dom_view_t *view, const erx_dom_plan_t *holder,
    erx_dom_unit_plan_t *draft)
{
	const erx_dom_device_entry_t *entry;
	const erx_dom_device_t *record;
	erx_dom_unit_device_t *device;
	uint32_t held;

	for (uint32_t index = 0; index < view->ndevices; index++) {
		entry = &view->devices[index];
		record = &view->device_records[index];
		if (entry->unit != draft->unit)
			continue;
		if (draft->ndevices == ERX_DOM_DEVICES_MAX)
			return (ERX_ELIMIT);
		/*
		 * Only to a domain of the configured row the manifest places the
		 * unit on: not a requested or session domain, nor one of another
		 * row.
		 */
		if (!erx_dom_from_row(&holder->spec.origin, entry->row))
			return (ERX_EINVAL);
		if (record->index != index || !life_entry_ok(entry) ||
		    life_overlaps(view, index))
			return (ERX_EINVAL);
		/* A holder that has ended held objects its own budget took with it. */
		held = life_slot(view, record->holder);
		if (held != view->max_domains && life_alive(&view->domains[held]))
			return (ERX_EBUSY);
		device = &draft->devices[draft->ndevices++];
		*device = (erx_dom_unit_device_t){ .index = index,
		    .driven = erx_dom_entry_driven(entry),
		    .nranges = entry->nranges, .reg_offset = entry->offset,
		    .reg_size = entry->size, .window = ERX_DOM_UNIT_NONE,
		    .line = ERX_DOM_UNIT_NONE };
		for (uint32_t range = 0; range < entry->nranges; range++)
			device->ranges[range] = entry->ranges[range];
	}
	return (draft->ndevices == 0 ? ERX_EINVAL : ERX_OK);
}

/*
 * Adds a well-formed range to the page runs: it joins every run it meets
 * or abuts, which may join runs that were apart, so the scan starts again
 * after each join. ERX_ELIMIT past ERX_DOM_UNIT_WINDOWS_MAX runs.
 */
static erx_status_t
life_add_run(erx_dom_range_t *runs, uint32_t *nruns, const erx_dom_range_t *range)
{
	uint64_t base = range->base, end = life_range_end(range), run_end;
	uint32_t at = 0;

	while (at < *nruns) {
		run_end = life_range_end(&runs[at]);
		if (runs[at].base > end || base > run_end) {
			at++;
			continue;
		}
		base = runs[at].base < base ? runs[at].base : base;
		end = run_end > end ? run_end : end;
		runs[at] = runs[--*nruns];
		at = 0;
	}
	if (*nruns == ERX_DOM_UNIT_WINDOWS_MAX)
		return (ERX_ELIMIT);
	runs[(*nruns)++] = (erx_dom_range_t){ base, end - base };
	return (ERX_OK);
}

/*
 * The windows of a give, from the facts its devices carry alone: its page
 * runs, lowest first, one over each run of consecutive pages its driven
 * devices' ranges cover, so each is a union of the unit's driven ranges
 * and a page they share is in one; and for each driven device with a
 * range, the window its first range lies in and its registers' offset
 * into it. The planner makes the give's windows from it and the plan
 * check derives them again (erx_dom_unit_check). Only driven devices'
 * facts are read. ERX_EINVAL for more than ERX_DOM_DEVICES_MAX devices, a
 * driven device with more ranges than the ABI allows, a range that is
 * empty, unaligned or wraps, or registers that do not lie whole inside
 * their window; ERX_ELIMIT past ERX_DOM_UNIT_WINDOWS_MAX runs.
 */
static erx_status_t
life_unit_layout(const erx_dom_unit_plan_t *plan, life_layout_t *layout)
{
	const erx_dom_unit_device_t *device;
	const erx_dom_range_t *first, *run;
	erx_dom_range_t swap;
	erx_status_t status;
	uint64_t offset, end;

	*layout = (life_layout_t){ .nruns = 0 };
	if (plan->ndevices > ERX_DOM_DEVICES_MAX)
		return (ERX_EINVAL);
	for (uint32_t d = 0; d < plan->ndevices; d++) {
		device = &plan->devices[d];
		layout->window[d] = ERX_DOM_UNIT_NONE;
		if (!device->driven)
			continue;
		if (device->nranges > ERX_DEVICE_RANGES_MAX)
			return (ERX_EINVAL);
		for (uint32_t range = 0; range < device->nranges; range++) {
			if (!life_range_ok(&device->ranges[range]))
				return (ERX_EINVAL);
			if ((status = life_add_run(layout->runs, &layout->nruns,
			    &device->ranges[range])) != ERX_OK)
				return (status);
		}
	}
	for (uint32_t at = 1; at < layout->nruns; at++)
		for (uint32_t j = at; j > 0 &&
		    layout->runs[j - 1].base > layout->runs[j].base; j--) {
			swap = layout->runs[j];
			layout->runs[j] = layout->runs[j - 1];
			layout->runs[j - 1] = swap;
		}
	for (uint32_t d = 0; d < plan->ndevices; d++) {
		device = &plan->devices[d];
		if (!device->driven || device->nranges == 0)
			continue;
		first = &device->ranges[0];
		for (uint32_t w = 0; w < layout->nruns; w++) {
			run = &layout->runs[w];
			if (first->base < run->base || first->base >= life_range_end(run))
				continue;
			if (!life_add(first->base - run->base, device->reg_offset,
			    &offset) || !life_add(offset, device->reg_size, &end) ||
			    offset >= run->size || end > run->size)
				return (ERX_EINVAL);
			layout->window[d] = w;
			layout->offset[d] = offset;
			break;		/* the runs are apart, so no other holds it */
		}
	}
	return (ERX_OK);
}

/*
 * Which of the give's first nlines lines is line number, or nlines for
 * none: line l is line at[l] of the entry of the give's device sources[l].
 */
static uint32_t
life_line_find(const erx_dom_view_t *view, const erx_dom_unit_plan_t *draft,
    const uint32_t *sources, const uint32_t *at, uint32_t nlines,
    uint32_t number)
{
	const erx_dom_device_entry_t *source;
	uint32_t l;

	for (l = 0; l < nlines; l++) {
		source = &view->devices[draft->devices[sources[l]].index];
		if (source->lines[at[l]] == number)
			break;
	}
	return (l);
}

/*
 * Whether a device of the give other than device d, of a kind or not,
 * names line number.
 */
static bool
life_line_shared(const erx_dom_view_t *view, const erx_dom_unit_plan_t *draft,
    uint32_t d, uint32_t number)
{
	for (uint32_t other = 0; other < draft->ndevices; other++)
		if (other != d &&
		    life_names_line(&view->devices[draft->devices[other].index], number))
			return (true);
	return (false);
}

/*
 * The unit's lines, in the order its driven devices first name them, one
 * IRQ object each, made from the resource of the first driven device that
 * names it: sources[l] is that device's index in the give and at[l] the
 * line's index in its entry. A line only devices of no kind name has no
 * reader, so no object. Each driven device with a line gets its first
 * line's object, shared when another device of the unit names it.
 * ERX_ELIMIT past ERX_DOM_UNIT_LINES_MAX lines.
 */
static erx_status_t
life_unit_lines(const erx_dom_view_t *view, erx_dom_unit_plan_t *draft,
    uint32_t *sources, uint32_t *at, uint32_t *nlines)
{
	const erx_dom_device_entry_t *entry;
	erx_dom_unit_device_t *device;
	uint32_t found;

	*nlines = 0;
	for (uint32_t d = 0; d < draft->ndevices; d++) {
		device = &draft->devices[d];
		entry = &view->devices[device->index];
		if (!device->driven)
			continue;
		for (uint32_t line = 0; line < entry->nlines; line++) {
			found = life_line_find(view, draft, sources, at, *nlines,
			    entry->lines[line]);
			if (found == *nlines) {
				if (*nlines == ERX_DOM_UNIT_LINES_MAX)
					return (ERX_ELIMIT);
				sources[*nlines] = d;
				at[(*nlines)++] = line;
			}
			if (line == 0) {
				device->line = found;
				device->shared = life_line_shared(view, draft, d,
				    entry->lines[0]);
			}
		}
	}
	return (ERX_OK);
}

/* The grants row of a device object: each kind's objects share one. */
static erx_dom_obj_t
life_grant_key(erx_dom_obj_t obj)
{
	if (obj >= ERX_DOM_OBJ_DEV_RESOURCE && obj < ERX_DOM_OBJ_DEV_WINDOW)
		return (ERX_DOM_OBJ_DEV_RESOURCE);
	if (obj >= ERX_DOM_OBJ_DEV_WINDOW && obj < ERX_DOM_OBJ_DEV_IRQ)
		return (ERX_DOM_OBJ_DEV_WINDOW);
	if (obj >= ERX_DOM_OBJ_DEV_IRQ && obj < ERX_DOM_OBJ_DEV_DMA)
		return (ERX_DOM_OBJ_DEV_IRQ);
	if (obj >= ERX_DOM_OBJ_DEV_DMA && obj < ERX_DOM_OBJ_DEV_MEMORY)
		return (ERX_DOM_OBJ_DEV_DMA);
	if (obj >= ERX_DOM_OBJ_DEV_MEMORY && obj < ERX_DOM_OBJ_MADE_COUNT)
		return (ERX_DOM_OBJ_DEV_MEMORY);
	if (obj >= ERX_DOM_OBJ_DEV_KEPT && obj < ERX_DOM_OBJ_COUNT)
		return (ERX_DOM_OBJ_DEV_KEPT);
	return (obj);
}

/* An install into the holder of obj, with its row's rights. */
static void
life_unit_install(erx_dom_unit_plan_t *plan, erx_dom_obj_t obj)
{
	const erx_dom_grant_row_t *row;

	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if (row->obj == life_grant_key(obj) &&
		    row->target == ERX_DOM_OBJ_HOLDER_SPACE) {
			plan->steps[plan->nsteps++] = (erx_dom_step_t){
			    .kind = ERX_DOM_STEP_INSTALL, .obj = obj,
			    .target = ERX_DOM_OBJ_HOLDER_SPACE,
			    .rights = row->rights };
			return;
		}
	}
}

/* A step of the give that makes obj from device d's resource. */
static void
life_unit_make(erx_dom_unit_plan_t *plan, erx_dom_step_kind_t kind,
    erx_dom_obj_t obj, uint32_t d, uint32_t index)
{
	plan->steps[plan->nsteps++] = (erx_dom_step_t){ .kind = kind,
	    .obj = obj, .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
	    .target = ERX_DOM_OBJ_DEV_RESOURCE + d, .index = index };
}

erx_status_t
erx_dom_plan_unit_give(const erx_dom_view_t *view,
    const erx_dom_plan_t *holder, uint32_t unit, erx_dom_unit_plan_t *plan)
{
	erx_dom_unit_plan_t draft = { .unit = unit, .holder = holder->spec.id,
	    .slot = holder->slot };
	life_layout_t layout;
	uint32_t sources[ERX_DOM_UNIT_LINES_MAX], at[ERX_DOM_UNIT_LINES_MAX];
	uint32_t nlines, made;
	const erx_dom_device_entry_t *entry;
	bool kept[ERX_DOM_DEVICES_MAX] = { false };
	erx_status_t status;

	/* The holder is being created, into a free record. */
	if (draft.slot >= view->max_domains || view->domains[draft.slot].id != 0)
		return (ERX_EINVAL);
	if ((status = life_unit_devices(view, holder, &draft)) != ERX_OK ||
	    (status = life_unit_layout(&draft, &layout)) != ERX_OK ||
	    (status = life_unit_lines(view, &draft, sources, at, &nlines)) != ERX_OK)
		return (status);
	for (uint32_t d = 0; d < draft.ndevices; d++) {
		draft.devices[d].window = layout.window[d];
		draft.devices[d].offset = layout.offset[d];
	}

	for (uint32_t d = 0; d < draft.ndevices; d++)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_RESOURCE, .obj = ERX_DOM_OBJ_DEV_RESOURCE + d,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_ROOT_RESOURCE,
		    .index = draft.devices[d].index };
	for (uint32_t w = 0; w < layout.nruns; w++)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_WINDOW, .obj = ERX_DOM_OBJ_DEV_WINDOW + w,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_ROOT_RESOURCE,
		    .base = layout.runs[w].base, .size = layout.runs[w].size };
	for (uint32_t l = 0; l < nlines; l++)
		life_unit_make(&draft, ERX_DOM_STEP_IRQ, ERX_DOM_OBJ_DEV_IRQ + l,
		    sources[l], at[l]);
	/*
	 * A device of no kind is held, not driven (docs/design-shared-devices.md,
	 * "The unit rule"): no DMA window or memory, as no window or line.
	 */
	for (uint32_t d = 0; d < draft.ndevices; d++) {
		entry = &view->devices[draft.devices[d].index];
		if (!draft.devices[d].driven)
			continue;
		kept[d] = !entry->confined && entry->memory != 0 &&
		    view->device_records[draft.devices[d].index].memory.raw !=
		    ERX_CAP_NULL;
		if (entry->confined)
			life_unit_make(&draft, ERX_DOM_STEP_DMA,
			    ERX_DOM_OBJ_DEV_DMA + d, d, 0);
		else if (entry->memory != 0 && !kept[d]) {
			draft.steps[draft.nsteps++] = (erx_dom_step_t){
			    .kind = ERX_DOM_STEP_CONTIGUOUS,
			    .obj = ERX_DOM_OBJ_DEV_MEMORY + d,
			    .budget = ERX_DOM_OBJ_SYSTEM_BUDGET,
			    .target = ERX_DOM_OBJ_DEV_RESOURCE + d,
			    .size = entry->memory };
		}
	}
	/* The holder gets everything made but the resources (A7). */
	made = draft.nsteps;
	for (uint32_t step = 0; step < made; step++)
		if (draft.steps[step].kind != ERX_DOM_STEP_RESOURCE)
			life_unit_install(&draft, draft.steps[step].obj);
	/* Last, so no failing step follows an install undo cannot clear. */
	for (uint32_t d = 0; d < draft.ndevices; d++)
		if (kept[d])
			life_unit_install(&draft, ERX_DOM_OBJ_DEV_KEPT + d);
	if (erx_dom_unit_check(&draft) != ERX_OK)
		return (ERX_EINVAL);
	*plan = draft;
	return (ERX_OK);
}

/*
 * Whether obj is of the kind whose objects start at first, one per
 * device of the give, and so device *d's.
 */
static bool
life_device_obj(const erx_dom_unit_plan_t *plan, erx_dom_obj_t obj,
    erx_dom_obj_t first, uint32_t *d)
{
	*d = (uint32_t)(obj - first);
	return (obj >= first && *d < plan->ndevices);
}

/*
 * One step of a unit's give against the steps before it and what they
 * made: each device's resource from the root's, each window from the
 * root's resource, which life_unit_windows_ok holds to the page runs,
 * each line, DMA window and contiguous memory from a driven device's
 * resource, on the holder's budget but the memory, on the system
 * domain's, and installs into the holder by their rows.
 */
static bool
life_unit_step_ok(const erx_dom_unit_plan_t *plan, uint32_t at,
    const bool *made)
{
	const erx_dom_step_t *step = &plan->steps[at];
	const erx_dom_obj_t obj = step->obj;
	const bool fresh = obj < ERX_DOM_OBJ_MADE_COUNT &&
	    obj != ERX_DOM_OBJ_NONE && !made[obj];
	const bool holder_pays = step->budget == ERX_DOM_OBJ_HOLDER_BUDGET;
	uint32_t d, mine;
	/* The driven device whose resource the step names, made before it. */
	const bool from_device = life_device_obj(plan, step->target,
	    ERX_DOM_OBJ_DEV_RESOURCE, &d) && made[step->target] &&
	    plan->devices[d].driven;

	switch (step->kind) {
	case ERX_DOM_STEP_RESOURCE:
		return (fresh && life_device_obj(plan, obj,
		    ERX_DOM_OBJ_DEV_RESOURCE, &mine) && holder_pays &&
		    step->target == ERX_DOM_OBJ_ROOT_RESOURCE &&
		    step->index == plan->devices[mine].index);
	case ERX_DOM_STEP_WINDOW:
		return (fresh && life_grant_key(obj) == ERX_DOM_OBJ_DEV_WINDOW &&
		    holder_pays && step->target == ERX_DOM_OBJ_ROOT_RESOURCE);
	case ERX_DOM_STEP_IRQ:
		return (fresh && from_device && holder_pays &&
		    life_grant_key(obj) == ERX_DOM_OBJ_DEV_IRQ &&
		    step->index < ERX_DEVICE_IRQS_MAX);
	case ERX_DOM_STEP_DMA:
		return (fresh && from_device && holder_pays &&
		    obj == ERX_DOM_OBJ_DEV_DMA + d &&
		    !made[ERX_DOM_OBJ_DEV_MEMORY + d]);
	case ERX_DOM_STEP_CONTIGUOUS:
		return (fresh && from_device &&
		    obj == ERX_DOM_OBJ_DEV_MEMORY + d &&
		    step->budget == ERX_DOM_OBJ_SYSTEM_BUDGET &&
		    step->size != 0 && !made[ERX_DOM_OBJ_DEV_DMA + d]);
	case ERX_DOM_STEP_INSTALL:
		return (step->target == ERX_DOM_OBJ_HOLDER_SPACE &&
		    ((life_device_obj(plan, obj, ERX_DOM_OBJ_DEV_KEPT, &mine) &&
		    obj < ERX_DOM_OBJ_COUNT && plan->devices[mine].driven &&
		    !made[ERX_DOM_OBJ_DEV_MEMORY + mine]) ||
		    (obj < ERX_DOM_OBJ_MADE_COUNT &&
		    life_grant_key(obj) != ERX_DOM_OBJ_DEV_RESOURCE &&
		    made[obj])) && life_granted(step));
	case ERX_DOM_STEP_CARVE:
	case ERX_DOM_STEP_SPACE:
	case ERX_DOM_STEP_GROUP:
	case ERX_DOM_STEP_MEM:
	case ERX_DOM_STEP_BELL:
	case ERX_DOM_STEP_SLICE:
	case ERX_DOM_STEP_IMAGE_MAP:
	case ERX_DOM_STEP_MAP:
	case ERX_DOM_STEP_BOOTINFO:
	case ERX_DOM_STEP_THREAD:
	case ERX_DOM_STEP_GIVE:
		return (false);
	}
	return (false);
}

/*
 * The give's windows are the ones its devices' facts give
 * (life_unit_layout): its WINDOW steps make windows 0 to n - 1, in order,
 * each over its page run, and each device names its window and its
 * registers' offset there. So no window of the give reaches a page no
 * driven range of the unit names, whatever base and size a step carries.
 * That the runs are apart, lowest first, so no page is in two windows, is
 * checked here too, apart from the code that joins them.
 */
static bool
life_unit_windows_ok(const erx_dom_unit_plan_t *plan)
{
	const erx_dom_step_t *step;
	life_layout_t layout;
	uint32_t w = 0;

	if (life_unit_layout(plan, &layout) != ERX_OK)
		return (false);
	for (uint32_t at = 0; at < plan->nsteps; at++) {
		step = &plan->steps[at];
		if (step->kind != ERX_DOM_STEP_WINDOW)
			continue;
		if (w == layout.nruns || step->obj != ERX_DOM_OBJ_DEV_WINDOW + w ||
		    step->base != layout.runs[w].base ||
		    step->size != layout.runs[w].size)
			return (false);
		w++;
	}
	if (w != layout.nruns)
		return (false);
	for (w = 1; w < layout.nruns; w++)
		if (life_range_end(&layout.runs[w - 1]) >= layout.runs[w].base)
			return (false);
	for (uint32_t d = 0; d < plan->ndevices; d++)
		if (plan->devices[d].window != layout.window[d] ||
		    plan->devices[d].offset != layout.offset[d])
			return (false);
	return (true);
}

/*
 * Each device of a checked give: its own entry, once, its resource made,
 * and its line, which only a driven device has, an object the give made.
 */
static bool
life_unit_devices_ok(const erx_dom_unit_plan_t *plan, const bool *made)
{
	const erx_dom_unit_device_t *device;

	for (uint32_t d = 0; d < plan->ndevices; d++) {
		device = &plan->devices[d];
		for (uint32_t other = 0; other < d; other++)
			if (plan->devices[other].index == device->index)
				return (false);
		if (!made[ERX_DOM_OBJ_DEV_RESOURCE + d])
			return (false);
		/* Only a device with a line can share it. */
		if (device->line == ERX_DOM_UNIT_NONE) {
			if (device->shared)
				return (false);
			continue;
		}
		/* Only a driven device reads a line, an object the give made. */
		if (!device->driven || device->line >= ERX_DOM_UNIT_LINES_MAX ||
		    !made[ERX_DOM_OBJ_DEV_IRQ + device->line])
			return (false);
	}
	return (true);
}

erx_status_t
erx_dom_unit_check(const erx_dom_unit_plan_t *plan)
{
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	bool installed[ERX_DOM_OBJ_COUNT] = { false };
	const erx_dom_step_t *step;
	bool keeping = false;

	if (plan->nsteps > ERX_DOM_UNIT_STEPS ||
	    plan->holder <= ERX_DOM_SYSTEM_ID || plan->ndevices == 0 ||
	    plan->ndevices > ERX_DOM_DEVICES_MAX)
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		/* Kept memory outlives an undo, so its installs are last. */
		if (keeping && (step->kind != ERX_DOM_STEP_INSTALL ||
		    life_grant_key(step->obj) != ERX_DOM_OBJ_DEV_KEPT))
			return (ERX_EINVAL);
		keeping = step->kind == ERX_DOM_STEP_INSTALL &&
		    life_grant_key(step->obj) == ERX_DOM_OBJ_DEV_KEPT;
		if (step->budget >= ERX_DOM_OBJ_COUNT ||
		    step->target >= ERX_DOM_OBJ_COUNT ||
		    step->aux != ERX_DOM_OBJ_NONE ||
		    !life_unit_step_ok(plan, index, made))
			return (ERX_EINVAL);
		if (step->kind != ERX_DOM_STEP_INSTALL)
			made[step->obj] = true;
		else if (installed[step->obj])
			return (ERX_EINVAL);
		else
			installed[step->obj] = true;
	}
	return (life_unit_windows_ok(plan) && life_unit_devices_ok(plan, made) ?
	    ERX_OK : ERX_EINVAL);
}

uint32_t
erx_dom_unit_undo(const erx_dom_unit_plan_t *plan, uint32_t applied,
    erx_dom_obj_t *undo)
{
	return (erx_dom_steps_undo(plan->steps, plan->nsteps, applied, undo));
}
