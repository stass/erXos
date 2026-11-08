/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The deletion core's exhaustive model (docs/design-kernel.md, "Closing and
 * deleting"), run by test/host/delete_test.rb over the real cores: the
 * object store, the capability table, the inserts, the deletion core and
 * the grace tracker.
 *
 * One object X, a gate, starts named by three slots: S1 in table T1, S2
 * and S3 in table T2. The scenario, the program's argument, names up to
 * four actors by letter; each is a program of atomic steps, every step
 * one critical section under the locks the cores name:
 *
 *   D  a deletion: erx_delete_step's close, the drain (enabled only while
 *      no one holds X's existence lock), one slot clear per step with a
 *      preemption point after it, the put retired to the grace tracker,
 *      and the free once the put's stamp is mature;
 *   C  a close of S1, whose release, by the release rule, starts a destroy
 *      that this actor then runs as D does;
 *   E  the emptying of T2: marks it emptied, then closes each slot of T2
 *      one per step, and runs the destroy its release starts;
 *   M  a move of S1 into T2 by a pass, planned, taken and installed in one
 *      step under X's capability lock and the tables' locks;
 *   A  a copy of S2 into T1 (an attachment);
 *   O  an operation: looks X up through S2 and takes a counted reference,
 *      then takes X's existence lock, changes X, and drops both;
 *   R  a reader: looks X up through S3 without a reference, uses the
 *      pointer, then passes a preemption point.
 *
 * Each actor runs on a CPU of its own, so a CPU's report of a quiescent
 * point at an actor's preemption point is sound, and a CPU whose actor
 * has finished is idle and reports at once. The model explores every
 * interleaving depth first, restoring the whole world from a snapshot at
 * each branch; the world lives in one static record, so every pointer the
 * cores keep stays valid across a restore. After every step it checks:
 *
 *   no lookup, attachment or taking of the existence lock succeeds after
 *   the close; no one holds the existence lock once the drain has ended;
 *   one destroy alone goes on past its close; the object is released at
 *   most once, and only when no slot names it; a release of a closed
 *   object asks for no destroy; once the teardown hands out the put, no
 *   slot names X and none is ever linked again; and a pointer a lookup
 *   returned is never used after the record is freed.
 *
 * The existence lock itself is the model's: a take refuses a closed object
 * and the drain waits for every holder, so only the deletion core's side
 * of the drain is under test. A destroy that a release asks for is run by
 * the releasing actor, shown as 'd', which begins it with its close in the
 * same step. S2 and S3 sit on T2's second page.
 *
 * At the end of every interleaving every actor has finished, and a closed
 * or released object has been torn down and freed. A violation prints its
 * name and the interleaving and exits 1; success prints the count of
 * steps and interleavings explored.
 */

#include <inttypes.h>
#include <stdalign.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/delete.h"
#include "erx/grace.h"
#include "erx/object.h"

#define MODEL_ACTORS	4
#define MODEL_DEPTH	64
#define MODEL_T2_CAPS	4
#define MODEL_LIMIT	(2 * ERX_CAP_PAGE_SLOTS)

enum model_pc {
	PC_START = 0,
	PC_DRAIN,		/* D: the drain is due */
	PC_TEAR,		/* D: the teardown's parts are due */
	PC_FREE,		/* D: the put is queued; the free is due */
	PC_CLEAR,		/* E: clearing T2's slots */
	PC_LOCK,		/* O: holds a counted reference; the lock is due */
	PC_WORK,		/* O: holds the existence lock */
	PC_USE,			/* R: holds a borrowed pointer */
	PC_POINT,		/* R: the preemption point is due */
	PC_DONE
};

typedef struct model_actor {
	char		 kind;
	uint32_t	 pc;
	uint32_t	 cpu;
	uint32_t	 epoch;		/* its count of preemption points */
	uint32_t	 next;		/* E: the next of T2's values to close */
	uint64_t	 stamp;		/* D: the put's stamp */
	bool		 goes_on;	/* D: its destroy went on past the close */
	erx_delete_t	 destroy;
	erx_uref_t	 ref;
} model_actor_t;

typedef struct model_world {
	alignas(64) unsigned char tables[2][256];
	alignas(64) unsigned char directories[2][64];
	alignas(64) unsigned char pages[3][ERX_CAP_PAGE_SLOTS *
	    ERX_CAP_SLOT_SIZE];
	alignas(64) unsigned char record[256];
	alignas(64) unsigned char store[64];
	alignas(64) unsigned char grace[512];
	erx_object_t	*records[1];
	erx_cap_reservation_t reservation;
	erx_cap_t	 s1;
	erx_cap_t	 t2[MODEL_T2_CAPS];
	uint32_t	 nt2;
	model_actor_t	 actors[MODEL_ACTORS];
	uint32_t	 nactors;
	uint32_t	 holders;	/* holders of X's existence lock */
	uint32_t	 refs;		/* counted references actors hold */
	uint32_t	 closes;	/* destroys that went on past the close */
	uint32_t	 releases;
	bool		 drained;
	bool		 torn;		/* a teardown handed out the put */
	bool		 freed;
} model_world_t;

static model_world_t world;
static uint32_t current;		/* the actor whose step runs */
static uint8_t schedule[MODEL_DEPTH];
static uint64_t nsteps, nruns;

/* The effects the cores take from their host. */

uint32_t
erx_effect_thread_epoch(void)
{
	return (world.actors[current].epoch);
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

void
erx_effect_grace_lock(erx_grace_t *grace)
{
	(void)grace;
}

void
erx_effect_grace_unlock(erx_grace_t *grace)
{
	(void)grace;
}

static erx_object_t *
model_x(void)
{
	return (world.records[0]);
}

static erx_cap_table_t *
model_table(int i)
{
	return ((erx_cap_table_t *)world.tables[i]);
}

static erx_grace_t *
model_grace(void)
{
	return ((erx_grace_t *)world.grace);
}

static void
model_violation(const char *what, uint32_t depth)
{
	uint32_t i;

	printf("violation: %s\nschedule:", what);
	for (i = 0; i < depth; i++)
		printf(" %c", world.actors[schedule[i]].kind);
	printf("\n");
	exit(1);
}

static void
model_setup(const char *scenario)
{
	erx_oid_key_t key = { { 1, 2, 3, 4 } };
	erx_cap_t fill[ERX_CAP_PAGE_SLOTS];
	bool released;
	uint32_t i;
	int t;

	memset(&world, 0, sizeof(world));
	if (erx_cap_table_size() > sizeof(world.tables[0]) ||
	    erx_cap_directory_size(MODEL_LIMIT) > sizeof(world.directories[0]) ||
	    erx_object_record_size() > sizeof(world.record) ||
	    erx_object_store_size() > sizeof(world.store) ||
	    erx_grace_record_size() > sizeof(world.grace) ||
	    strlen(scenario) == 0 || strlen(scenario) > MODEL_ACTORS) {
		fprintf(stderr, "delete_model: bad setup\n");
		exit(2);
	}
	world.records[0] = (erx_object_t *)world.record;
	erx_object_test_store(world.records, 1);
	erx_object_store_init((erx_object_store_t *)world.store, &key);
	for (t = 0; t < 2; t++)
		if (erx_cap_table_init(model_table(t), world.directories[t],
		    sizeof(world.directories[t]), MODEL_LIMIT) != ERX_OK ||
		    erx_cap_table_add_page(model_table(t), world.pages[t],
		    sizeof(world.pages[t])) != ERX_OK)
			exit(2);
	if (erx_cap_table_add_page(model_table(1), world.pages[2],
	    sizeof(world.pages[2])) != ERX_OK ||
	    erx_object_init((erx_object_store_t *)world.store, model_x(),
	    ERX_K_GATE, NULL) != ERX_OK ||
	    erx_cap_install_kind(model_table(0), model_x(), ERX_KIND_NEW_GATE,
	    UINT32_MAX, &world.s1) != ERX_OK)
		exit(2);
	/*
	 * T2's slots on its second page, so the teardown names slots past a
	 * table's first page: fill the first page's free slots and close them,
	 * which sends them to the free list's tail.
	 */
	for (i = 1; i < ERX_CAP_PAGE_SLOTS; i++)
		if (erx_cap_install_kind(model_table(1), model_x(),
		    ERX_KIND_NEW_GATE, UINT32_MAX, &fill[i]) != ERX_OK)
			exit(2);
	for (i = 1; i < ERX_CAP_PAGE_SLOTS; i++)
		if (erx_cap_slot_clear(model_table(1), fill[i], model_x(),
		    &released) != ERX_OK || released)
			exit(2);
	if (erx_cap_install_kind(model_table(1), model_x(), ERX_KIND_NEW_GATE,
	    UINT32_MAX, &world.t2[0]) != ERX_OK ||
	    erx_cap_install_kind(model_table(1), model_x(), ERX_KIND_NEW_GATE,
	    UINT32_MAX, &world.t2[1]) != ERX_OK ||
	    erx_cap_reserve(model_table(1), 1, &world.reservation) != ERX_OK)
		exit(2);
	world.nt2 = 2;
	if ((world.t2[0].raw & ((UINT64_C(1) << ERX_CAP_SLOT_BITS) - 1)) <
	    ERX_CAP_PAGE_SLOTS)
		exit(2);
	erx_grace_init(model_grace());
	world.nactors = (uint32_t)strlen(scenario);
	for (i = 0; i < world.nactors; i++)
		erx_grace_cpu_join(model_grace(), i);
	for (i = 0; i < world.nactors; i++) {
		world.actors[i].kind = scenario[i];
		world.actors[i].cpu = i;
		world.actors[i].pc = PC_START;
	}
}

/*
 * The reports a destroy's free step makes before it reads the stamp: its
 * own CPU is at a quiescent point, and so is every CPU whose actor has
 * finished.
 */
static void
model_free_reports(erx_grace_t *grace, const model_actor_t *a)
{
	uint32_t i;

	(void)erx_grace_report(grace, a->cpu);
	for (i = 0; i < world.nactors; i++)
		if (world.actors[i].pc == PC_DONE)
			(void)erx_grace_report(grace, world.actors[i].cpu);
}

/* Whether the free step would find the put's stamp mature. */
static bool
model_free_due(const model_actor_t *a)
{
	alignas(64) unsigned char copy[sizeof(world.grace)];

	memcpy(copy, world.grace, sizeof(copy));
	model_free_reports((erx_grace_t *)copy, a);
	return (erx_grace_mature((erx_grace_t *)copy, a->stamp));
}

/* A preemption point of the current actor: its CPU is quiescent. */
static void
model_point(model_actor_t *a)
{
	a->epoch++;
	(void)erx_grace_report(model_grace(), a->cpu);
}

/*
 * The checks on a reported release (K21): once, only when no slot names
 * the object, and never a destroy of an object a destroy has closed.
 * Returns what the release rule asks for.
 */
static erx_release_action_t
model_release(uint32_t depth)
{
	erx_release_action_t action = erx_release_rule(model_x(), false);

	if (++world.releases > 1)
		model_violation("an object released twice", depth);
	if (erx_object_ncaps(model_x()) != 0)
		model_violation("a release while a slot names the object",
		    depth);
	if (action == ERX_RELEASE_DESTROY &&
	    erx_object_state(model_x()) == ERX_OBJ_DELETED)
		model_violation("a release of a closed object destroys it",
		    depth);
	return (action);
}

/* One part of a destroy: the close, a slot, or the put. */
static void
model_destroy_part(model_actor_t *a, uint32_t depth)
{
	erx_delete_part_t part;
	bool released;

	part = erx_delete_step(&a->destroy);
	if (part.action != ERX_DELETE_STOP && !a->goes_on) {
		a->goes_on = true;
		if (++world.closes > 1)
			model_violation("two destroys went on past the close",
			    depth);
	}
	if ((part.action == ERX_DELETE_CLEAR ||
	    part.action == ERX_DELETE_PUT) && world.holders > 0)
		model_violation("a teardown part while the existence lock is "
		    "held", depth);
	switch (part.action) {
	case ERX_DELETE_STOP:
		a->pc = PC_DONE;
		break;
	case ERX_DELETE_DRAIN:
		a->pc = PC_DRAIN;
		break;
	case ERX_DELETE_CLEAR:
		if (erx_cap_slot_clear(part.table, part.cap, model_x(),
		    &released) != ERX_OK)
			model_violation("the teardown named a slot that does "
			    "not name the object", depth);
		if (released)
			(void)model_release(depth);
		model_point(a);
		break;
	case ERX_DELETE_PUT:
		if (erx_object_ncaps(model_x()) != 0 ||
		    erx_object_slots(model_x()) != NULL)
			model_violation("the teardown ended with a slot "
			    "naming the object", depth);
		world.torn = true;
		a->stamp = erx_grace_retire(model_grace());
		a->pc = PC_FREE;
		break;
	}
}

/*
 * A release that asks for a destroy: the releasing actor, 'd' from here on,
 * runs it, and begins it with its close in the same critical section as
 * the release, as erx/delete.h requires.
 */
static void
model_become_destroy(model_actor_t *a, uint32_t depth)
{
	a->kind = 'd';
	erx_delete_begin(&a->destroy, model_x());
	model_destroy_part(a, depth);
}

static bool
model_enabled(const model_actor_t *a)
{
	switch (a->pc) {
	case PC_DONE:
		return (false);
	case PC_DRAIN:
		return (world.holders == 0);
	case PC_FREE:
		return (model_free_due(a));
	default:
		return (true);
	}
}

static erx_status_t
model_move(bool *releasedp)
{
	erx_pass_item_t item = { .cap = world.s1, .op = ERX_PASS_MOVE,
	    .mask = UINT32_MAX, .type = ERX_CAP_ANY_TYPE, .required = 0 };
	erx_pass_request_t request = { .items = &item, .count = 1,
	    .room = world.reservation.count,
	    .route = ERX_PASS_CREATED_TO_CREATED, .from = model_table(0),
	    .to = model_table(1) };
	erx_pass_result_t results[ERX_MSG_CAPS];
	erx_pass_source_t source;
	erx_pass_plan_t plan;
	erx_status_t status;

	*releasedp = false;
	memset(&source, 0, sizeof(source));
	source.status = erx_cap_read(model_table(0), NULL, world.s1,
	    ERX_CAP_ANY_TYPE, 0, &source.view);
	status = erx_pass_plan(&request, &source, &plan);
	if (status != ERX_OK)
		return (status);
	status = erx_pass_take(&plan, model_table(0), &world.reservation);
	if (status != ERX_OK)
		return (status);
	status = erx_pass_install(&plan, model_table(1), &world.reservation,
	    results);
	if (status == ERX_OK)
		world.t2[world.nt2++] = results[0].cap;
	*releasedp = plan.steps[0].released;
	return (status);
}

/* A slot clear's report: a release that asks for a destroy starts one. */
static void
model_on_release(model_actor_t *a, bool released, uint32_t depth)
{
	if (released && model_release(depth) == ERX_RELEASE_DESTROY)
		model_become_destroy(a, depth);
}

/*
 * The first step of each actor: a deletion's close, a close of S1 (which
 * removes exactly one slot, K25), the emptying's mark, a move, a copy, or a
 * lookup through T2. closed says whether X was closed before the step.
 */
static void
model_start(model_actor_t *a, bool closed, uint32_t depth)
{
	uint32_t before = erx_object_ncaps(model_x());
	erx_status_t status;
	bool released;
	erx_cap_t copy;

	switch (a->kind) {
	case 'D':
		erx_delete_begin(&a->destroy, model_x());
		model_destroy_part(a, depth);
		return;
	case 'C':
		a->pc = PC_DONE;
		if (erx_cap_slot_clear(model_table(0), world.s1, model_x(),
		    &released) != ERX_OK)
			return;
		if (erx_object_ncaps(model_x()) + 1 != before)
			model_violation("a close removed other than one slot",
			    depth);
		model_on_release(a, released, depth);
		return;
	case 'E':
		erx_cap_table_set_emptied(model_table(1));
		a->pc = PC_CLEAR;
		return;
	case 'M':
		a->pc = PC_DONE;
		status = model_move(&released);
		if (status == ERX_OK && closed)
			model_violation("a move attached after the close", depth);
		model_on_release(a, released, depth);
		return;
	case 'A':
		a->pc = PC_DONE;
		if (erx_cap_install_copy(model_table(0), model_table(1),
		    world.t2[0], model_x(), UINT32_MAX, &copy) == ERX_OK && closed)
			model_violation("an attachment after the close", depth);
		return;
	default:	/* 'O' and 'R' */
		status = erx_cap_lookup(model_table(1), NULL,
		    world.t2[a->kind == 'O' ? 0 : 1], ERX_CAP_ANY_TYPE, 0,
		    &a->ref);
		if (status != ERX_OK) {
			a->pc = PC_DONE;
			return;
		}
		if (closed)
			model_violation("a lookup after the close", depth);
		if (a->kind == 'R') {
			a->pc = PC_USE;
			return;
		}
		(void)erx_object_ref(a->ref);
		world.refs++;
		a->pc = PC_LOCK;
		return;
	}
}

/* Runs the next step of actor i, which is enabled. */
static void
model_step(uint32_t i, uint32_t depth)
{
	model_actor_t *a = &world.actors[i];
	bool released, closed;

	current = i;
	/*
	 * Whether a destroy had closed X before this step began: a step that
	 * succeeds on X although it was already closed broke K26.
	 */
	closed = erx_object_state(model_x()) == ERX_OBJ_DELETED;
	switch (a->pc) {
	case PC_START:
		model_start(a, closed, depth);
		return;
	case PC_DRAIN:
		world.drained = true;
		a->pc = PC_TEAR;
		model_point(a);
		return;
	case PC_TEAR:
		model_destroy_part(a, depth);
		return;
	case PC_FREE:
		model_free_reports(model_grace(), a);
		if (!erx_grace_mature(model_grace(), a->stamp))
			model_violation("a free step before its stamp is mature",
			    depth);
		a->pc = PC_DONE;
		if (erx_object_put(model_x()))
			world.freed = true;
		return;
	case PC_CLEAR:
		if (a->next == world.nt2) {
			a->pc = PC_DONE;
			return;
		}
		model_point(a);
		if (erx_cap_slot_clear(model_table(1), world.t2[a->next++],
		    model_x(), &released) == ERX_OK)
			model_on_release(a, released, depth);
		return;
	case PC_LOCK:
		/* The lock's one acquire refuses a closed object. */
		if (closed) {
			world.refs--;
			if (erx_object_put(model_x()))
				world.freed = true;
			a->pc = PC_DONE;
			model_point(a);
			return;
		}
		if (world.drained)
			model_violation("the existence lock taken after the "
			    "drain", depth);
		world.holders++;
		a->pc = PC_WORK;
		return;
	case PC_WORK:
		if (world.drained)
			model_violation("an operation changed the object after "
			    "the drain", depth);
		world.holders--;
		world.refs--;
		if (erx_object_put(model_x()))
			world.freed = true;
		a->pc = PC_DONE;
		model_point(a);
		return;
	case PC_USE:
		if (world.freed)
			model_violation("a borrowed pointer used after the free",
			    depth);
		(void)erx_uref_get(a->ref);
		a->pc = PC_POINT;
		return;
	case PC_POINT:
		model_point(a);
		a->pc = PC_DONE;
		return;
	}
	fprintf(stderr, "delete_model: actor %c at an unknown step\n",
	    a->kind);
	exit(2);
}

/* The checks after every step. */
static void
model_check(uint32_t depth)
{
	if (world.drained && world.holders > 0)
		model_violation("the existence lock held after the drain",
		    depth);
	if (world.torn && (erx_object_ncaps(model_x()) != 0 ||
	    erx_object_slots(model_x()) != NULL))
		model_violation("a slot names the object after its teardown",
		    depth);
	if (world.freed && (!world.torn || world.refs != 0))
		model_violation("the record freed before its teardown and its "
		    "references", depth);
}

/* The checks at the end of an interleaving. */
static void
model_check_end(uint32_t depth)
{
	uint32_t i;

	for (i = 0; i < world.nactors; i++)
		if (world.actors[i].pc != PC_DONE)
			model_violation("an actor never finishes", depth);
	if (world.releases > 0 && world.closes == 0)
		model_violation("a released object never destroyed", depth);
	if (world.closes > 0 && !world.freed)
		model_violation("a destroyed object never freed", depth);
}

static void
model_explore(uint32_t depth)
{
	model_world_t *snapshot;
	bool any = false;
	uint32_t i;

	if (depth == MODEL_DEPTH) {
		fprintf(stderr, "delete_model: depth bound reached\n");
		exit(2);
	}
	snapshot = malloc(sizeof(*snapshot));
	if (snapshot == NULL)
		exit(2);
	memcpy(snapshot, &world, sizeof(world));
	for (i = 0; i < snapshot->nactors; i++) {
		memcpy(&world, snapshot, sizeof(world));
		if (!model_enabled(&world.actors[i]))
			continue;
		any = true;
		schedule[depth] = (uint8_t)i;
		model_step(i, depth + 1);
		nsteps++;
		model_check(depth + 1);
		model_explore(depth + 1);
	}
	if (!any) {
		model_check_end(depth);
		nruns++;
	}
	memcpy(&world, snapshot, sizeof(world));
	free(snapshot);
}

/*
 * The release rule over every type, attached and not, on a fresh LIVE
 * object: one line per type, "rule TYPE ATTACHED UNATTACHED", each an
 * erx_release_action_t.
 */
static void
model_rules(void)
{
	erx_oid_key_t key = { { 1, 2, 3, 4 } };
	erx_ktype_t type;

	for (type = ERX_K_BUDGET; type <= ERX_K_DMA; type++) {
		memset(&world, 0, sizeof(world));
		world.records[0] = (erx_object_t *)world.record;
		erx_object_store_init((erx_object_store_t *)world.store, &key);
		if (erx_object_init((erx_object_store_t *)world.store,
		    model_x(), type, NULL) != ERX_OK)
			exit(2);
		printf("rule %d %d %d\n", (int)type,
		    (int)erx_release_rule(model_x(), true),
		    (int)erx_release_rule(model_x(), false));
	}
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "rules") == 0) {
		model_rules();
		return (0);
	}
	if (argc != 2 || strspn(argv[1], "DCEMAOR") != strlen(argv[1])) {
		fprintf(stderr, "usage: delete_model rules | ACTORS (of DCEMAOR)\n");
		return (2);
	}
	model_setup(argv[1]);
	model_explore(0);
	printf("explored %s: %" PRIu64 " steps, %" PRIu64 " interleavings\n",
	    argv[1], nsteps, nruns);
	return (0);
}
