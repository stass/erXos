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
 * library does next; and a device's give with its check and undo
 * ("Devices"). Nothing here performs a kernel call.
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
static bool	life_range_ok(const erx_dom_range_t *);
static bool	life_entry_ok(const erx_dom_device_entry_t *);
static uint64_t	life_range_end(const erx_dom_range_t *);
static bool	life_overlaps(const erx_dom_view_t *, uint32_t);
static erx_dom_obj_t life_grant_key(erx_dom_obj_t);
static void	life_device_install(erx_dom_device_plan_t *, erx_dom_obj_t);
static bool	life_device_step_ok(const erx_dom_step_t *, const bool *);

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
	case ERX_DOM_STEP_RESOURCE:
	case ERX_DOM_STEP_WINDOW:
	case ERX_DOM_STEP_IRQ:
	case ERX_DOM_STEP_DMA:
	case ERX_DOM_STEP_CONTIGUOUS:
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
 * Some range of entry index meets a range of another entry, so its windows
 * would reach another device's registers. Entry index's ranges are well
 * formed; another entry's are read within the ABI's limit whatever their
 * count says.
 */
static bool
life_overlaps(const erx_dom_view_t *view, uint32_t index)
{
	const erx_dom_device_entry_t *mine = &view->devices[index], *other;
	const erx_dom_range_t *a, *b;
	uint32_t count;

	for (uint32_t each = 0; each < view->ndevices; each++) {
		if (each == index)
			continue;
		other = &view->devices[each];
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

/* The grants row of a device object: every window shares one, every line one. */
static erx_dom_obj_t
life_grant_key(erx_dom_obj_t obj)
{
	if (obj >= ERX_DOM_OBJ_DEV_WINDOW && obj < ERX_DOM_OBJ_DEV_IRQ)
		return (ERX_DOM_OBJ_DEV_WINDOW);
	if (obj >= ERX_DOM_OBJ_DEV_IRQ && obj < ERX_DOM_OBJ_DEV_DMA)
		return (ERX_DOM_OBJ_DEV_IRQ);
	return (obj);
}

/* An install into the holder of obj, with its row's rights. */
static void
life_device_install(erx_dom_device_plan_t *plan, erx_dom_obj_t obj)
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

erx_status_t
erx_dom_plan_device_give(const erx_dom_view_t *view, uint32_t id,
    uint32_t index, erx_dom_device_plan_t *plan)
{
	erx_dom_device_plan_t draft = { .index = index, .holder = id };
	const erx_dom_device_entry_t *entry;
	const erx_dom_device_t *record;
	uint32_t held, made;
	bool kept;

	draft.slot = life_slot(view, id);
	if (draft.slot == view->max_domains ||
	    !life_alive(&view->domains[draft.slot]) || index >= view->ndevices)
		return (ERX_EINVAL);
	entry = &view->devices[index];
	record = &view->device_records[index];
	if (record->index != index || !life_entry_ok(entry) ||
	    life_overlaps(view, index))
		return (ERX_EINVAL);
	/* A holder that has ended held objects its own budget took with it. */
	held = life_slot(view, record->holder);
	if (held != view->max_domains && life_alive(&view->domains[held]))
		return (ERX_EBUSY);

	draft.steps[draft.nsteps++] = (erx_dom_step_t){
	    .kind = ERX_DOM_STEP_RESOURCE, .obj = ERX_DOM_OBJ_DEV_RESOURCE,
	    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
	    .target = ERX_DOM_OBJ_ROOT_RESOURCE, .index = index };
	for (uint32_t range = 0; range < entry->nranges; range++)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_WINDOW,
		    .obj = ERX_DOM_OBJ_DEV_WINDOW + range,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_DEV_RESOURCE, .index = range,
		    .size = entry->ranges[range].size };
	for (uint32_t line = 0; line < entry->nlines; line++)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_IRQ, .obj = ERX_DOM_OBJ_DEV_IRQ + line,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_DEV_RESOURCE, .index = line };
	kept = !entry->confined && entry->memory != 0 &&
	    record->memory.raw != ERX_CAP_NULL;
	if (entry->confined)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_DMA, .obj = ERX_DOM_OBJ_DEV_DMA,
		    .budget = ERX_DOM_OBJ_HOLDER_BUDGET,
		    .target = ERX_DOM_OBJ_DEV_RESOURCE };
	else if (entry->memory != 0 && !kept)
		draft.steps[draft.nsteps++] = (erx_dom_step_t){
		    .kind = ERX_DOM_STEP_CONTIGUOUS,
		    .obj = ERX_DOM_OBJ_DEV_MEMORY,
		    .budget = ERX_DOM_OBJ_SYSTEM_BUDGET, .size = entry->memory };
	/* The holder gets everything made but the resource (A7). */
	made = draft.nsteps;
	for (uint32_t step = 0; step < made; step++)
		if (draft.steps[step].kind != ERX_DOM_STEP_RESOURCE)
			life_device_install(&draft, draft.steps[step].obj);
	/* Last, so no failing step follows an install undo cannot clear. */
	if (kept)
		life_device_install(&draft, ERX_DOM_OBJ_DEV_KEPT);
	if (erx_dom_device_check(&draft) != ERX_OK)
		return (ERX_EINVAL);
	*plan = draft;
	return (ERX_OK);
}

/*
 * One step of a device's give against what the steps before it made: the
 * resource from the root's, each window, line and DMA window from the
 * resource on the holder's budget, the contiguous memory on the system
 * domain's, and installs into the holder by their rows.
 */
static bool
life_device_step_ok(const erx_dom_step_t *step, const bool *made)
{
	erx_dom_obj_t obj = step->obj;
	bool fresh = obj < ERX_DOM_OBJ_MADE_COUNT && obj != ERX_DOM_OBJ_NONE &&
	    !made[obj];
	bool from_resource = step->target == ERX_DOM_OBJ_DEV_RESOURCE &&
	    made[ERX_DOM_OBJ_DEV_RESOURCE] &&
	    step->budget == ERX_DOM_OBJ_HOLDER_BUDGET;

	switch (step->kind) {
	case ERX_DOM_STEP_RESOURCE:
		return (fresh && obj == ERX_DOM_OBJ_DEV_RESOURCE &&
		    step->budget == ERX_DOM_OBJ_HOLDER_BUDGET &&
		    step->target == ERX_DOM_OBJ_ROOT_RESOURCE);
	case ERX_DOM_STEP_WINDOW:
		return (fresh && from_resource && step->size != 0 &&
		    life_grant_key(obj) == ERX_DOM_OBJ_DEV_WINDOW &&
		    step->index == obj - ERX_DOM_OBJ_DEV_WINDOW);
	case ERX_DOM_STEP_IRQ:
		return (fresh && from_resource &&
		    life_grant_key(obj) == ERX_DOM_OBJ_DEV_IRQ &&
		    step->index == obj - ERX_DOM_OBJ_DEV_IRQ);
	case ERX_DOM_STEP_DMA:
		return (fresh && from_resource && obj == ERX_DOM_OBJ_DEV_DMA &&
		    !made[ERX_DOM_OBJ_DEV_MEMORY]);
	case ERX_DOM_STEP_CONTIGUOUS:
		return (fresh && obj == ERX_DOM_OBJ_DEV_MEMORY &&
		    step->budget == ERX_DOM_OBJ_SYSTEM_BUDGET &&
		    step->size != 0 && !made[ERX_DOM_OBJ_DEV_DMA]);
	case ERX_DOM_STEP_INSTALL:
		return (step->target == ERX_DOM_OBJ_HOLDER_SPACE &&
		    (obj == ERX_DOM_OBJ_DEV_KEPT ||
		    (obj < ERX_DOM_OBJ_MADE_COUNT &&
		    obj != ERX_DOM_OBJ_DEV_RESOURCE && made[obj])) &&
		    life_granted(step));
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
		return (false);
	}
	return (false);
}

erx_status_t
erx_dom_device_check(const erx_dom_device_plan_t *plan)
{
	bool made[ERX_DOM_OBJ_MADE_COUNT] = { false };
	const erx_dom_step_t *step;

	if (plan->nsteps > ERX_DOM_DEVICE_STEPS ||
	    plan->holder <= ERX_DOM_SYSTEM_ID)
		return (ERX_EINVAL);
	for (uint32_t index = 0; index < plan->nsteps; index++) {
		step = &plan->steps[index];
		/* The kept memory outlives an undo, so its install is last. */
		if (step->kind == ERX_DOM_STEP_INSTALL &&
		    step->obj == ERX_DOM_OBJ_DEV_KEPT &&
		    index + 1 != plan->nsteps)
			return (ERX_EINVAL);
		if (step->budget >= ERX_DOM_OBJ_COUNT ||
		    step->target >= ERX_DOM_OBJ_COUNT ||
		    step->aux != ERX_DOM_OBJ_NONE ||
		    !life_device_step_ok(step, made))
			return (ERX_EINVAL);
		if (step->kind != ERX_DOM_STEP_INSTALL)
			made[step->obj] = true;
	}
	return (ERX_OK);
}

uint32_t
erx_dom_device_undo(const erx_dom_device_plan_t *plan, uint32_t applied,
    erx_dom_obj_t *undo)
{
	return (erx_dom_steps_undo(plan->steps, plan->nsteps, applied, undo));
}
