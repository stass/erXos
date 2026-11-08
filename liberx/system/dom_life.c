/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's pure core after creation (docs/design-system.md,
 * "Introducing two domains" and "Ending a domain"): the connection planner
 * with its check and undo; the teardowns of disconnect, the destroy at an
 * exit record and retire; the end classifier; and the steps that turn a
 * record at the library's fault gate, or a stop request, into what the
 * library does next. Nothing here performs a kernel call.
 *
 * A domain's end runs through its record's states: built or running; then,
 * once the library stops it, stopping with the reason noted; then, at its
 * exit record, ended, with its own budget destroyed and its end
 * classified; then retired, once no connection names it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/dom.h"
#include "erx/lane.h"

static bool	life_add(uint64_t, uint64_t, uint64_t *);
static bool	life_alive(const erx_dom_t *);
static uint32_t	life_slot(const erx_dom_view_t *, uint64_t);
static uint32_t	life_connections(const erx_dom_view_t *, uint32_t);
static bool	life_room(const erx_dom_view_t *, const erx_dom_t *);
static bool	life_granted(const erx_dom_step_t *);
static bool	life_step_ok(const erx_dom_step_t *, const bool *);
static bool	life_by_library(const erx_dom_view_t *, uint64_t);

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
    uint32_t a_reads, uint32_t b_reads, erx_dom_link_plan_t *plan)
{
	const erx_dom_t *da, *db;
	const erx_dom_grant_row_t *row;
	erx_dom_link_plan_t draft = { .a = a, .b = b };
	uint64_t side_a = erx_lane_side_bytes(b_reads);
	uint64_t side_b = erx_lane_side_bytes(a_reads);
	uint64_t child_a, child_b;

	draft.a_slot = life_slot(view, a);
	draft.b_slot = life_slot(view, b);
	if (a == b || draft.a_slot == view->max_domains ||
	    draft.b_slot == view->max_domains || side_a == 0 || side_b == 0 ||
	    !life_add(side_b, ERX_DOM_BELL_BYTES, &child_a) ||
	    !life_add(side_a, ERX_DOM_BELL_BYTES, &child_b))
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
	/* Each party's share comes from erx_dom_grants alone (A7). */
	for (size_t index = 0; index < ERX_DOM_GRANTS_ROWS; index++) {
		row = &erx_dom_grants[index];
		if (row->target != ERX_DOM_OBJ_SPACE_A &&
		    row->target != ERX_DOM_OBJ_SPACE_B)
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
		if (row->obj == step->obj && row->target == step->target &&
		    row->flags == 0 && (step->rights & ~row->rights) == 0)
			return (true);
	}
	return (false);
}

/*
 * One step of a connection against what the steps before it made. The
 * pairs below are the charging rule: each child from its own party's
 * outer budget, the side a reads (b's) and a's bell on a's child, and the
 * same for b.
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
	return (ERX_OK);
}

uint32_t
erx_dom_link_undo(const erx_dom_link_plan_t *plan, uint32_t applied,
    erx_dom_obj_t *undo)
{
	return (erx_dom_steps_undo(plan->steps, plan->nsteps, applied, undo));
}

erx_status_t
erx_dom_plan_disconnect(const erx_dom_view_t *view, uint32_t number,
    erx_dom_teardown_t *teardown)
{
	const erx_dom_connection_t *row;
	erx_dom_teardown_t draft = { .kind = ERX_DOM_DISCONNECT };

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
		*teardown = draft;
		return (ERX_OK);
	}
	return (ERX_EINVAL);
}

erx_status_t
erx_dom_plan_retire(const erx_dom_view_t *view, uint32_t id,
    erx_dom_teardown_t *teardown)
{
	uint32_t slot = life_slot(view, id);
	const erx_dom_connection_t *row;

	if (slot == view->max_domains ||
	    view->domains[slot].state != ERX_DOM_ENDED)
		return (ERX_EINVAL);
	/* Every child of an outer budget is a connection's (A5). */
	for (uint32_t index = 0; index < view->max_connections; index++) {
		row = &view->connections[index];
		if (row->number != 0 && (row->a == id || row->b == id))
			return (ERX_EBUSY);
	}
	*teardown = (erx_dom_teardown_t){ .kind = ERX_DOM_RETIRE,
	    .index = slot, .ndestroy = 1,
	    .destroy = { view->domains[slot].outer } };
	return (ERX_OK);
}

erx_dom_end_t
erx_dom_classify(const erx_fault_t *exit, bool by_library,
    const erx_dom_end_t *noted)
{
	if (by_library)
		return (noted != NULL && noted->kind == ERX_DOM_END_FAULT ?
		    *noted : (erx_dom_end_t){ ERX_DOM_END_STOPPED, 0 });
	if (exit->status == ERX_EXIT_CRASH)
		return ((erx_dom_end_t){ ERX_DOM_END_CRASH, 0 });
	return ((erx_dom_end_t){ ERX_DOM_END_HALT, exit->status });
}

/* The stopper an exit record names is one of the library's threads. */
static bool
life_by_library(const erx_dom_view_t *view, uint64_t thread)
{
	for (uint32_t index = 0; index < view->nlibrary_threads; index++)
		if (view->library_threads[index] == thread)
			return (true);
	return (false);
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
		action->end = erx_dom_classify(record,
		    life_by_library(view, record->thread),
		    dom->stopping ? &dom->stop : NULL);
		action->teardown = (erx_dom_teardown_t){
		    .kind = ERX_DOM_DESTROY, .index = slot, .ndestroy = 1,
		    .destroy = { dom->budget } };
		return;
	}
	/* The first stop the library makes is the one its exit record names. */
	if (dom->stopping)
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
	if (!view->domains[slot].stopping) {
		action->kind = ERX_DOM_ACT_STOP;
		action->status = status;
		action->end = (erx_dom_end_t){ ERX_DOM_END_STOPPED, 0 };
	}
	return (ERX_OK);
}
