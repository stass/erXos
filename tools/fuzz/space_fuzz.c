/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the space core with the creation arguments a domain controls
 * (flags, capability limit, which spaces it names, and the types, rights
 * and statuses its capabilities resolve to), interleaved with stops,
 * closes, threads, fault-gate detaches and the steps of two stop walks
 * and two deletion walks, decoded from the input. It aborts when an
 * invariant breaks:
 *
 *   an accepted creation names a parent at or below its creator, one
 *   level deeper, at most ERX_SPACE_DEPTH_MAX deep, with known flags, a
 *   limit within bounds and capabilities of the right types and rights;
 *   an attach succeeds exactly when the parent is neither stopped nor
 *   closed, and puts the child at the front of its parent's list;
 *   a space's parent, depth, flags, limit and label never change, and its
 *   fault gate only goes;
 *   in every list the children that are not walked come first, and no
 *   listed child is deleting or has another parent;
 *   a deleting space is closed;
 *   a post queues its record exactly when no deletion began and no post came
 *   first, and a deletion asks for a withdrawal exactly when a post came first;
 *   a walked space has every thread killed;
 *   a stop walk that is done leaves every space below its root walked;
 *   a space holds one for each child whose record is not freed and one
 *   until it is released, a record is freed only when its count is zero,
 *   and no unfinished walk is on a freed record, so each way back up
 *   reads a live one (a freed record is poisoned under AddressSanitizer).
 *
 * Each operation is one byte of opcode followed by its operands.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__has_include)
#if __has_include(<sanitizer/asan_interface.h>)
#include <sanitizer/asan_interface.h>
#endif
#endif
#ifndef ASAN_POISON_MEMORY_REGION
#define ASAN_POISON_MEMORY_REGION(address, size)	((void)(address), (void)(size))
#define ASAN_UNPOISON_MEMORY_REGION(address, size)	((void)(address), (void)(size))
#endif

#include "erx/budget.h"
#include "erx/object.h"
#include "erx/space.h"

#define FUZZ_SPACES	32
#define FUZZ_THREADS	4
#define FUZZ_WALKS	2
#define FUZZ_OPS	12

typedef struct fuzz_space {
	erx_space_facts_t first;	/* its facts when attached */
	int		 nthreads;
	bool		 killed[FUZZ_THREADS];	/* in list order */
	bool		 posted;	/* its exit record's post was made */
	bool		 released;	/* its own hold dropped */
	bool		 freed;		/* its record poisoned */
} fuzz_space_t;

typedef struct fuzz_input {
	const uint8_t	*bytes;
	size_t		 size;
} fuzz_input_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static fuzz_space_t spaces[FUZZ_SPACES];
/* Allocated once, so each record's storage takes the core's type. */
static erx_space_t *records[FUZZ_SPACES];
static int nspaces;

/*
 * The effects of the cores the capability core calls, which the space core
 * links for its rights: one thread, never at a preemption point.
 */
uint32_t
erx_effect_thread_epoch(void)
{
	return (0);
}

void
erx_effect_budget_lock(erx_budget_t *budget)
{
	(void)budget;
}

void
erx_effect_budget_unlock(erx_budget_t *budget)
{
	(void)budget;
}
static erx_stop_walk_t walks[FUZZ_WALKS];
static erx_delete_walk_t deletes[FUZZ_WALKS];
static int due[FUZZ_SPACES];	/* the reaper's queue of records to free */
static int ndue;
static size_t record_bytes;

static uint8_t
take(fuzz_input_t *input)
{
	uint8_t byte;

	if (input->size == 0)
		return (0);
	byte = input->bytes[0];
	input->bytes++;
	input->size--;
	return (byte);
}

static erx_space_t *
record(int id)
{
	return (records[id]);
}

static int
id_of(const erx_space_t *space)
{
	for (int i = 0; i < nspaces; i++)
		if (record(i) == space)
			return (i);
	abort();
}

static bool
at_or_below(const erx_space_t *space, const erx_space_t *ancestor)
{
	for (int steps = 0; space != NULL; steps++) {
		if (steps > FUZZ_SPACES)
			abort();
		if (space == ancestor)
			return (true);
		space = erx_space_parent(space);
	}
	return (false);
}

/* A lookup's result: its status, then a type and a rights mask. */
static erx_space_source_t
source(fuzz_input_t *input, int named)
{
	static const erx_status_t statuses[] = { ERX_OK, ERX_OK, ERX_OK,
	    ERX_ESTALE };
	static const erx_ktype_t types[] = { ERX_K_BUDGET, ERX_K_SPACE,
	    ERX_K_GATE, ERX_K_MEMORY };
	static const erx_create_kind_t kinds[] = { ERX_KIND_CARVED_BUDGET,
	    ERX_KIND_NEW_SPACE, ERX_KIND_NEW_GATE, ERX_KIND_SHARED_MEMORY };
	erx_space_source_t result;
	uint32_t mask;
	uint8_t choice;

	choice = take(input);
	mask = (uint32_t)take(input) << 24 | (uint32_t)take(input) << 12 |
	    take(input);
	if ((choice & 0x80) == 0)
		mask = UINT32_MAX;
	memset(&result, 0, sizeof(result));
	result.status = statuses[choice & 3];
	result.view.type = types[(choice >> 2) & 3];
	result.view.rights = erx_rights_shrink(
	    erx_rights_create(kinds[(choice >> 2) & 3]), mask);
	result.view.object = (uint64_t)named + 1;
	return (result);
}

static void
check_plan(const erx_space_request_t *request, const erx_space_plan_t *plan)
{
	erx_space_facts_t parent;

	erx_space_read(request->parent, &parent);
	if (plan->stage != ERX_SPACE_PLANNED || plan->parent != request->parent ||
	    plan->depth != parent.depth + 1 ||
	    plan->depth > ERX_SPACE_DEPTH_MAX ||
	    (plan->flags & ~ERX_SPACE_JIT) != 0 || plan->cap_limit < 2 ||
	    plan->cap_limit > ERX_CAPS_MAX ||
	    !at_or_below(request->parent, request->self) ||
	    request->budget.view.type != ERX_K_BUDGET ||
	    !erx_rights_contain(request->budget.view.rights,
	    ERX_HR_ALLOC | ERX_HR_SPACES) ||
	    request->fault.view.type != ERX_K_GATE ||
	    !erx_rights_contain(request->fault.view.rights, ERX_HR_SERVE))
		abort();
	if (!request->parent_self &&
	    (request->parent_cap.view.type != ERX_K_SPACE ||
	    !erx_rights_contain(request->parent_cap.view.rights, ERX_HR_CAPS)))
		abort();
}

/*
 * The space a call names: a released space has no capability and no thread
 * left, so no call names it again.
 */
static erx_space_t *
call_names(int id)
{
	return (spaces[id].released ? NULL : record(id));
}

static void
op_create(fuzz_input_t *input)
{
	static const uint32_t limits[] = { 0, 1, 2, 16, ERX_CAPS_MAX,
	    ERX_CAPS_MAX + 1, UINT32_MAX, 64 };
	erx_space_request_t request;
	erx_space_facts_t parent;
	erx_space_plan_t plan;
	erx_status_t status;
	int creator, named;
	uint8_t byte;

	creator = take(input) % nspaces;
	byte = take(input);
	request.parent_self = byte == 0xff;
	named = request.parent_self ? creator : byte % nspaces;
	if (call_names(creator) == NULL || call_names(named) == NULL)
		return;
	request.self = record(creator);
	request.parent = record(named);
	byte = take(input);
	request.flags = (byte & 0x80) != 0 ? byte : (byte & 1);
	request.cap_limit = limits[take(input) & 7];
	request.label = take(input);
	request.budget = source(input, -1);
	request.parent_cap = source(input, named);
	request.fault = source(input, 1000);
	if ((take(input) & 0x40) != 0)
		request.parent_cap.view.object += 1;

	status = erx_space_plan(&request, &plan);
	if (status != ERX_OK) {
		if (plan.stage != ERX_SPACE_REFUSED)
			abort();
		return;
	}
	check_plan(&request, &plan);
	if (nspaces == FUZZ_SPACES)
		return;

	erx_space_read(request.parent, &parent);
	erx_space_record_init(record(nspaces));
	status = erx_space_attach(&plan, record(nspaces),
	    (uint64_t)nspaces + 1);
	if (plan.stage != ERX_SPACE_SPENT)
		abort();
	if (parent.closed ? status != ERX_ESTALE :
	    parent.run != ERX_SPACE_LIVE ? status != ERX_EDEAD :
	    status != ERX_OK)
		abort();
	if (status != ERX_OK) {
		/* A refused record goes by the free steps, from its defined start. */
		if (!erx_space_free_ready(record(nspaces)) ||
		    erx_space_unhold_parent(record(nspaces)) != NULL)
			abort();
		return;
	}
	if (erx_space_attach(&plan, record(nspaces), 1) != ERX_EINVAL ||
	    erx_space_child_after(request.parent, NULL) != record(nspaces))
		abort();
	erx_space_read(record(nspaces), &spaces[nspaces].first);
	spaces[nspaces].nthreads = 0;
	nspaces++;
}

/* Whether an unfinished walk counts space: its root or its held space. */
static bool
counted(const erx_space_t *space)
{
	for (int w = 0; w < FUZZ_WALKS; w++)
		if ((walks[w].cursor != NULL && (walks[w].root == space ||
		    walks[w].held == space)) || (deletes[w].cursor != NULL &&
		    (deletes[w].root == space || deletes[w].held == space)))
			return (true);
	return (false);
}

/* The reaper's record free, which may queue the parent for a later round. */
static void
free_record(int id)
{
	erx_space_t *parent;

	if (erx_space_holds(record(id)) != 0)
		abort();
	parent = erx_space_unhold_parent(record(id));
	memset(record(id), 0x5a, record_bytes);
	ASAN_POISON_MEMORY_REGION(record(id), record_bytes);
	spaces[id].freed = true;
	if (parent != NULL)
		due[ndue++] = id_of(parent);
}

/* Release a record that is otherwise ready to free, when that is legal. */
static void
op_release(int id)
{
	erx_space_facts_t facts;

	erx_space_read(record(id), &facts);
	if (id == 0 || facts.run != ERX_SPACE_DELETING || counted(record(id)))
		return;
	spaces[id].released = true;
	if (erx_space_free_ready(record(id)))
		free_record(id);
}

static void
op_reap(void)
{
	int n;

	n = ndue;
	for (int i = 0; i < n; i++)
		free_record(due[i]);
	memmove(due, due + n, (size_t)(ndue - n) * sizeof(due[0]));
	ndue -= n;
}

static void
op_close(int id)
{
	erx_space_facts_t after, before;
	erx_status_t status;

	erx_space_read(record(id), &before);
	status = erx_space_close(record(id));
	erx_space_read(record(id), &after);
	if (status != (before.closed ? ERX_ESTALE : ERX_OK) || !after.closed ||
	    after.run != before.run)
		abort();
}

static void
op_step(int w)
{
	erx_stop_action_t action;
	fuzz_space_t *slot;

	if (walks[w].finishing) {
		action = erx_stop_finish(&walks[w]);
		if (action != ERX_STOP_ASCEND && action != ERX_STOP_DONE)
			abort();
		return;
	}
	slot = walks[w].cursor == NULL ? NULL : &spaces[id_of(walks[w].cursor)];
	action = erx_stop_step(&walks[w],
	    slot != NULL && slot->nthreads > 0 && !slot->killed[0]);
	if (action == ERX_STOP_KILL) {
		memmove(&slot->killed[0], &slot->killed[1],
		    (size_t)(slot->nthreads - 1) * sizeof(slot->killed[0]));
		slot->killed[slot->nthreads - 1] = true;
	} else if (action == ERX_STOP_INVALID) {
		abort();
	}
}

static void
op_post(int id)
{
	erx_space_facts_t facts;
	erx_space_post_t expected, post;

	erx_space_read(record(id), &facts);
	expected = spaces[id].posted ? ERX_SPACE_POST_NONE :
	    facts.run == ERX_SPACE_DELETING ? ERX_SPACE_POST_DROP :
	    ERX_SPACE_POST_QUEUE;
	post = erx_space_exit_post(record(id));
	if (post != expected ||
	    erx_space_exit_waits(record(id)) != (facts.run != ERX_SPACE_DELETING))
		abort();
	spaces[id].posted = true;
}

/* A deletion that begins asks for a withdrawal when a post came first. */
static void
check_withdraw(int w, erx_delete_walk_action_t action)
{
	if (action == ERX_DELETE_SPACE &&
	    deletes[w].withdraw != spaces[id_of(deletes[w].cursor)].posted)
		abort();
	if (action != ERX_DELETE_SPACE && deletes[w].withdraw)
		abort();
}

static void
op_dstep(int w)
{
	erx_delete_walk_action_t action;

	action = erx_delete_walk_step(&deletes[w]);
	check_withdraw(w, action);
	if (action == ERX_DELETE_INVALID && deletes[w].cursor != NULL)
		abort();
}

static void
check_space(int id)
{
	erx_space_facts_t facts, child_facts;
	const erx_space_t *child;
	const fuzz_space_t *slot;
	bool walked_seen;
	int n;

	slot = &spaces[id];
	erx_space_read(record(id), &facts);
	n = 0;
	for (int i = 0; i < nspaces; i++)
		if (!spaces[i].freed && erx_space_parent(record(i)) == record(id))
			n++;
	if (erx_space_holds(record(id)) != (uint64_t)n + (slot->released ? 0 : 1))
		abort();
	if (facts.object != slot->first.object ||
	    facts.parent != slot->first.parent ||
	    facts.depth != slot->first.depth ||
	    facts.flags != slot->first.flags ||
	    facts.cap_limit != slot->first.cap_limit ||
	    facts.label != slot->first.label ||
	    (facts.fault_gate != slot->first.fault_gate &&
	    facts.fault_gate != 0))
		abort();
	if (facts.run == ERX_SPACE_DELETING && !facts.closed)
		abort();
	if (facts.run >= ERX_SPACE_WALKED)
		for (int t = 0; t < slot->nthreads; t++)
			if (!slot->killed[t])
				abort();

	walked_seen = false;
	child = NULL;
	for (n = 0; ; n++) {
		child = erx_space_child_after(record(id), child);
		if (child == NULL)
			break;
		if (n == FUZZ_SPACES || erx_space_parent(child) != record(id))
			abort();
		erx_space_read(child, &child_facts);
		if (child_facts.run == ERX_SPACE_DELETING ||
		    (walked_seen && child_facts.run != ERX_SPACE_WALKED))
			abort();
		walked_seen = child_facts.run == ERX_SPACE_WALKED;
	}
}

static void
check_walks(void)
{
	erx_space_facts_t facts;

	for (int i = 0; i < nspaces; i++)
		if (spaces[i].freed && counted(record(i)))
			abort();
	for (int w = 0; w < FUZZ_WALKS; w++) {
		/* The reference a step ended is neither of those the walk keeps. */
		if ((walks[w].drop != NULL && (walks[w].drop == walks[w].held ||
		    walks[w].drop == walks[w].cursor)) ||
		    (deletes[w].drop != NULL && (deletes[w].drop == deletes[w].held ||
		    deletes[w].drop == deletes[w].cursor)))
			abort();
		if ((walks[w].cursor != NULL &&
		    spaces[id_of(walks[w].cursor)].freed) ||
		    (deletes[w].cursor != NULL &&
		    spaces[id_of(deletes[w].cursor)].freed))
			abort();
		if (walks[w].root == NULL || walks[w].cursor != NULL)
			continue;
		for (int i = 0; i < nspaces; i++) {
			if (spaces[i].freed)
				continue;
			erx_space_read(record(i), &facts);
			if (at_or_below(record(i), walks[w].root) &&
			    facts.run < ERX_SPACE_WALKED)
				abort();
		}
	}
}

static void
allocate_records(void)
{
	size_t align, bytes;

	align = erx_space_record_align();
	bytes = (erx_space_record_size() + align - 1) / align * align;
	record_bytes = bytes;
	for (int i = 0; i < FUZZ_SPACES; i++) {
		records[i] = aligned_alloc(align, bytes);
		if (records[i] == NULL)
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t input = { .bytes = data, .size = size };
	fuzz_space_t *slot;
	erx_space_t *space;
	uint8_t op, byte;
	int id, w;

	if (records[0] == NULL)
		allocate_records();
	memset(walks, 0, sizeof(walks));
	memset(deletes, 0, sizeof(deletes));
	for (int i = 0; i < FUZZ_SPACES; i++) {
		ASAN_UNPOISON_MEMORY_REGION(record(i), record_bytes);
		spaces[i].posted = false;
		spaces[i].released = false;
		spaces[i].freed = false;
	}
	ndue = 0;
	if (erx_space_init_first(record(0), 1, 64) != ERX_OK)
		abort();
	erx_space_read(record(0), &spaces[0].first);
	spaces[0].nthreads = 0;
	nspaces = 1;

	while (input.size > 0) {
		op = take(&input);
		byte = take(&input);
		id = byte % nspaces;
		w = byte % FUZZ_WALKS;
		slot = &spaces[id];
		space = call_names(id);
		switch (op % FUZZ_OPS) {
		case 0:
			op_create(&input);
			break;
		case 1:
			if (space != NULL)
				erx_space_stop(space, (int8_t)take(&input), byte);
			break;
		case 2:
			if (space != NULL)
				op_close(id);
			break;
		case 3:
			space = call_names(take(&input) % nspaces);
			if (space == NULL ||
			    erx_stop_walk_begin(&walks[w], space) != ERX_OK)
				memset(&walks[w], 0, sizeof(walks[w]));
			break;
		case 4:
			op_step(w);
			break;
		case 5: {
			erx_delete_walk_action_t action;

			space = call_names(take(&input) % nspaces);
			if (space == NULL || erx_delete_walk_begin(&deletes[w],
			    space, &action) != ERX_OK)
				memset(&deletes[w], 0, sizeof(deletes[w]));
			else
				check_withdraw(w, action);
			break;
		}
		case 6:
			op_dstep(w);
			break;
		case 7:
			if (space != NULL &&
			    erx_space_admit(space, ERX_SPACE_ADMIT_THREAD) == ERX_OK &&
			    slot->nthreads < FUZZ_THREADS)
				slot->killed[slot->nthreads++] = false;
			break;
		case 8:
			if (space != NULL && erx_space_fault_detach(space,
			    take(&input) + UINT64_C(1000)) &&
			    slot->first.fault_gate == 0)
				abort();
			break;
		case 9:
			if (space != NULL)
				op_release(id);
			break;
		case 10:
			if (space != NULL)
				op_post(id);
			break;
		default:
			op_reap();
			break;
		}
		for (int i = 0; i < nspaces; i++)
			if (!spaces[i].freed)
				check_space(i);
		check_walks();
	}
	return (0);
}
