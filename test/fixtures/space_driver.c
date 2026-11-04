/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the space core (kernel/core/space.c), through its public
 * interface alone: it never sees a record's fields. It stands in for what
 * the core leaves to its caller: each space's threads, as a list of kill
 * flags in which a posted kill moves its thread to the end; each space's
 * table, as an emptied flag; each space's exit record and its gate's count
 * of dropped records; the lookups, as the statuses and views a
 * command gives; the walks' positions and counted references, which are
 * each walk's root and held space; and the reaper's queue of records
 * whose free a child's free handed on. It reads one command per line
 * from the file named by its argument and prints, for each, its result
 * ("= ...") and then the whole tree ("S ..."), which
 * test/fixtures/space_model.rb predicts independently:
 *
 *   first                    a new machine: space 0, the first
 *   plan K SELF PARENT FLAGS LIMIT B P F
 *                            plan a creation into plan slot K; PARENT is
 *                            a space or "self"; B, P and F are the
 *                            budget's, the parent's and the fault gate's
 *                            lookups, each STATUS,TYPE,RIGHTS[,OBJECT]
 *   attach K                 attach plan K as the next space; a refused
 *                            record goes by the free steps at once
 *   stop S STATUS STOPPER    stop space S
 *   close S                  close space S for its destroy
 *   admit S WHAT             1 child, 2 thread, 3 mapping, other invalid
 *   thread S                 admit a thread and add it to S's list
 *   walk W R                 begin stop walk W from space R
 *   step W                   one step of stop walk W: its finish when one
 *                            is due; a KILL posts one thread's kill; prints
 *                            the action, cursor, held space and drop
 *   delete W R               begin deletion walk W from space R
 *   dstep W                  one step of deletion walk W, printed as a step
 *   detach S G               detach gate G from space S
 *   release S                space S's record is otherwise ready to free:
 *                            it must not be the first space, and must be
 *                            deleting, with no exit record waiting,
 *                            released once, neither the root nor
 *                            the held space of an unfinished walk, and
 *                            named by no unspent plan; prints 1
 *                            when its record is freed now, 0 when a
 *                            child's record keeps it
 *   post S                   S's last death makes its post; a QUEUE leaves
 *                            the record to be placed; prints the action, the
 *                            record's state and the gate's drop count
 *   place S                  under the gate's lock, place a record that has
 *                            just been posted, or move one whose receiver
 *                            died; prints the state and count
 *   dead S                   the receiver of S's record dies: a withdrawal
 *                            sent to it is refused until its drain places
 *                            the record
 *   take S                   the gate's server receives S's record, when one
 *                            waits; prints as place does
 *   exit S                   prints as place does
 *   ready S                  prints 1 when nothing a party holds keeps S's
 *                            record: it is closed, it is deleting, and no
 *                            exit record of it waits at its gate
 *   reap                     one round of the reaper: free every record
 *                            queued before it began, queueing in turn each
 *                            parent whose last hold such a free dropped;
 *                            prints how many it freed
 *   state                    print the tree alone
 *
 * A freed record is overwritten, and poisoned under AddressSanitizer, so
 * a read of it is caught.
 */

#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
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

#include "erx/space.h"

#define SPACES_MAX	96
#define THREADS_MAX	8
#define PLANS_MAX	8
#define WALKS_MAX	4
#define OBJECT_BASE	100

typedef struct space_slot {
	erx_space_t	*space;
	int		 exists;
	int		 released;	/* its own hold dropped */
	int		 emptied;	/* its table's emptied flag */
	char		 exit;		/* its exit record: N none, P posted and
					 * not placed, W waiting, T taken, D
					 * dropped */
	int		 dead;		/* its receiver died; no withdrawal
					 * reaches it */
	int		 deletions;	/* the walks that ran its own parts */
	int		 nthreads;
	int		 killed[THREADS_MAX];	/* in list order */
} space_slot_t;

static space_slot_t spaces[SPACES_MAX];
static int nspaces;
static erx_space_plan_t plans[PLANS_MAX];
static erx_stop_walk_t walks[WALKS_MAX];
static erx_delete_walk_t deletes[WALKS_MAX];
static int due[SPACES_MAX];	/* the reaper's queue of records to free */
static int ndue;
static int dropped;	/* the gate's count of dropped exit records */
static size_t record_bytes;

static void
fail(const char *what)
{
	fprintf(stderr, "space-driver: %s\n", what);
	exit(2);
}

static int
space_id(const erx_space_t *space)
{
	if (space == NULL)
		return (-1);
	for (int i = 0; i < nspaces; i++)
		if (spaces[i].space == space)
			return (i);
	fail("unknown record");
	return (-1);
}

static int
object_id(uint64_t object)
{
	return (object == 0 ? -1 : (int)(object - OBJECT_BASE));
}

/*
 * A space a command's caller holds: a released space has no capability
 * and no thread left, so no call names it again.
 */
static erx_space_t *
fetch_space(int id)
{
	if (id < 0 || id >= nspaces || !spaces[id].exists ||
	    spaces[id].released)
		fail("no such space");
	return (spaces[id].space);
}

static erx_space_t *
new_record(void)
{
	if (nspaces == SPACES_MAX)
		fail("too many spaces");
	if (spaces[nspaces].space == NULL) {
		spaces[nspaces].space = aligned_alloc(erx_space_record_align(),
		    record_bytes);
		if (spaces[nspaces].space == NULL)
			fail("out of memory");
	}
	ASAN_UNPOISON_MEMORY_REGION(spaces[nspaces].space, record_bytes);
	/* Fill with garbage: attach must initialise every field it reads. */
	memset(spaces[nspaces].space, 0xa5, record_bytes);
	erx_space_record_init(spaces[nspaces].space);
	return (spaces[nspaces].space);
}

static void
print_state(void)
{
	static const char runs[] = "?LSWD";
	erx_space_facts_t facts;
	const erx_space_t *child;

	printf("S");
	for (int i = 0; i < nspaces; i++) {
		if (!spaces[i].exists)
			continue;
		erx_space_read(spaces[i].space, &facts);
		printf(" %d:%d,%" PRIu32 ",%c,%d,%" PRIu32 ",%" PRIu32 ",%" PRIu64
		    ",%" PRIx64 ",%" PRId64 ",%" PRIu64 ",%d,%" PRIu64 ",[", i,
		    object_id(facts.parent), facts.depth, runs[facts.run],
		    facts.closed ? 1 : 0, facts.flags, facts.cap_limit,
		    facts.fault_gate, facts.label, facts.status, facts.stopper,
		    spaces[i].emptied, erx_space_holds(spaces[i].space));
		child = NULL;
		for (int n = 0; ; n++) {
			child = erx_space_child_after(spaces[i].space, child);
			if (child == NULL)
				break;
			if (n == SPACES_MAX)
				fail("list does not end");
			printf("%s%d", n == 0 ? "" : " ", space_id(child));
		}
		printf("],");
		for (int t = 0; t < spaces[i].nthreads; t++)
			putchar(spaces[i].killed[t] ? 'k' : 'u');
	}
	printf("\n");
}

static erx_space_source_t
parse_source(const char *text)
{
	erx_space_source_t source;
	unsigned long long object;
	unsigned int rights, type;
	int fields, status;

	memset(&source, 0, sizeof(source));
	object = 0;
	fields = sscanf(text, "%d,%u,%x,%llu", &status, &type, &rights,
	    &object);
	if (fields < 3)
		fail("bad source");
	source.status = status;
	source.view.type = type;
	/* Rights reach the core only through the constructors. */
	source.view.rights = erx_rights_shrink(
	    erx_rights_create(type == ERX_K_BUDGET ? ERX_KIND_CARVED_BUDGET :
	    type == ERX_K_SPACE ? ERX_KIND_NEW_SPACE : ERX_KIND_NEW_GATE),
	    rights);
	source.view.object = object;
	return (source);
}

static void
cmd_plan(char **argv, int argc)
{
	erx_space_request_t request;
	erx_status_t status;
	int k, parent, self;

	if (argc != 9)
		fail("plan takes eight arguments");
	k = atoi(argv[1]);
	if (k < 0 || k >= PLANS_MAX)
		fail("bad plan slot");
	self = atoi(argv[2]);
	memset(&request, 0, sizeof(request));
	request.self = fetch_space(self);
	request.parent_self = strcmp(argv[3], "self") == 0;
	parent = request.parent_self ? self : atoi(argv[3]);
	request.parent = fetch_space(parent);
	request.flags = (uint32_t)strtoul(argv[4], NULL, 0);
	request.cap_limit = (uint32_t)strtoul(argv[5], NULL, 0);
	request.budget = parse_source(argv[6]);
	request.parent_cap = parse_source(argv[7]);
	if (request.parent_cap.view.object == 0)
		request.parent_cap.view.object = OBJECT_BASE + (uint64_t)parent;
	request.fault = parse_source(argv[8]);
	request.label = 0x1000 + (uint64_t)k;
	status = erx_space_plan(&request, &plans[k]);
	printf("= %d %d %" PRIu32 "\n", status, plans[k].stage,
	    plans[k].depth);
}

static void
cmd_attach(int k)
{
	erx_space_t *record;
	erx_status_t status;

	if (k < 0 || k >= PLANS_MAX)
		fail("bad plan slot");
	record = new_record();
	status = erx_space_attach(&plans[k], record,
	    OBJECT_BASE + (uint64_t)nspaces);
	if (status == ERX_OK) {
		spaces[nspaces].exists = 1;
		printf("= %d %d\n", status, nspaces);
		nspaces++;
	} else {
		/* A refused record's defined start needs only the free steps. */
		if (!erx_space_free_ready(record) ||
		    erx_space_unhold_parent(record) != NULL)
			fail("a refused record does not go");
		printf("= %d -\n", status);
	}
}

static void
cmd_step(int w)
{
	static const char *names[] = { "?", "KILL", "DESCEND", "FINISH",
	    "ASCEND", "DONE", "INVALID", "STOPPED" };
	erx_stop_action_t action;
	space_slot_t *slot;
	int cursor, t;

	if (w < 0 || w >= WALKS_MAX)
		fail("bad walk");
	if (walks[w].finishing) {
		action = erx_stop_finish(&walks[w]);
	} else {
		slot = walks[w].cursor == NULL ? NULL :
		    &spaces[space_id(walks[w].cursor)];
		action = erx_stop_step(&walks[w],
		    slot != NULL && slot->nthreads > 0 && !slot->killed[0]);
		if (action == ERX_STOP_KILL) {
			/* A part of one thread: post its kill, move it to the end. */
			for (t = 1; t < slot->nthreads; t++)
				slot->killed[t - 1] = slot->killed[t];
			slot->killed[slot->nthreads - 1] = 1;
		}
	}
	cursor = space_id(walks[w].cursor);
	printf("= %s %d %d %d\n", names[action], cursor,
	    space_id(walks[w].held), space_id(walks[w].drop));
}

static void
drop_record(int id)
{
	spaces[id].exit = 'D';
	dropped++;
}

/*
 * The space's own deletion, as ERX_DELETE_SPACE asks of the caller, by the
 * one walk that owns it: the table's emptied flag and, when the core says a
 * record was posted, its withdrawal on the home CPU, which finds it or not.
 */
static void
delete_parts(int id, bool withdraw)
{
	if (spaces[id].deletions++ != 0)
		fail("two walks deleted one space");
	spaces[id].emptied = 1;
	if (withdraw && spaces[id].exit == 'W' && !spaces[id].dead)
		drop_record(id);
}

static void
cmd_dstep(int w)
{
	static const char *names[] = { "?", "DELETE", "ASCEND", "DONE",
	    "INVALID" };
	erx_delete_walk_action_t action;

	if (w < 0 || w >= WALKS_MAX)
		fail("bad walk");
	action = erx_delete_walk_step(&deletes[w]);
	if (action != ERX_DELETE_SPACE && deletes[w].withdraw)
		fail("a withdrawal with no deletion begun");
	if (action == ERX_DELETE_SPACE)
		delete_parts(space_id(deletes[w].cursor), deletes[w].withdraw);
	printf("= %s %d %d %d\n", names[action], space_id(deletes[w].cursor),
	    space_id(deletes[w].held), space_id(deletes[w].drop));
}

static void
cmd_delete(int w, int root)
{
	erx_delete_walk_action_t action;
	erx_status_t status;

	if (w < 0 || w >= WALKS_MAX)
		fail("bad walk");
	action = ERX_DELETE_INVALID;
	status = erx_delete_walk_begin(&deletes[w], fetch_space(root), &action);
	if (status == ERX_OK && action == ERX_DELETE_SPACE)
		delete_parts(root, deletes[w].withdraw);
	printf("= %d %d\n", status, status == ERX_OK ? (int)action : 0);
}

/* Whether an unfinished walk counts space: its root or its held space. */
static int
walk_counts(const erx_space_t *root, const erx_space_t *cursor,
    const erx_space_t *held, const erx_space_t *space)
{
	return (cursor != NULL && (space == root || space == held));
}

/*
 * The reaper's record free: the parent's hold goes before the record's
 * memory, and a parent whose last hold that was waits for the next round.
 */
static void
free_record(int id)
{
	erx_space_t *parent;

	parent = erx_space_unhold_parent(spaces[id].space);
	memset(spaces[id].space, 0x5a, record_bytes);
	ASAN_POISON_MEMORY_REGION(spaces[id].space, record_bytes);
	spaces[id].exists = 0;
	if (parent != NULL)
		due[ndue++] = space_id(parent);
}

static void
cmd_release(int id)
{
	erx_space_facts_t facts;
	erx_space_t *space;
	int now;

	space = fetch_space(id);
	erx_space_read(space, &facts);
	if (id == 0 || facts.run != ERX_SPACE_DELETING ||
	    spaces[id].exit == 'W' || spaces[id].exit == 'P')
		fail("release of a space in use");
	for (int w = 0; w < WALKS_MAX; w++)
		if (walk_counts(walks[w].root, walks[w].cursor, walks[w].held,
		    space) || walk_counts(deletes[w].root, deletes[w].cursor,
		    deletes[w].held, space))
			fail("release of a space a walk counts");
	for (int k = 0; k < PLANS_MAX; k++)
		if (plans[k].stage == ERX_SPACE_PLANNED && plans[k].parent == space)
			fail("release of a planned parent");
	spaces[id].released = 1;
	now = erx_space_free_ready(space) ? 1 : 0;
	if (now)
		free_record(id);
	printf("= %d\n", now);
}

static void
print_exit(int id)
{
	printf("= %c %d\n", spaces[id].exit, dropped);
}

static void
cmd_post(int id)
{
	static const char *names[] = { "NONE", "QUEUE", "DROP" };
	erx_space_post_t post;

	post = erx_space_exit_post(fetch_space(id));
	if (post == ERX_SPACE_POST_QUEUE)
		spaces[id].exit = 'P';
	else if (post == ERX_SPACE_POST_DROP)
		drop_record(id);
	printf("= %s %c %d\n", names[post], spaces[id].exit, dropped);
}

static void
cmd_place(int id)
{
	if (spaces[id].exit == 'P' || spaces[id].exit == 'W') {
		if (erx_space_exit_waits(fetch_space(id)))
			spaces[id].exit = 'W';
		else
			drop_record(id);
	}
	print_exit(id);
}

static void
cmd_take(int id)
{
	(void)fetch_space(id);
	if (spaces[id].exit == 'W')
		spaces[id].exit = 'T';
	print_exit(id);
}

static void
cmd_ready(int id)
{
	erx_space_facts_t facts;

	erx_space_read(fetch_space(id), &facts);
	printf("= %d\n", facts.closed && facts.run == ERX_SPACE_DELETING &&
	    spaces[id].exit != 'W' ? 1 : 0);
}

static void
cmd_reap(void)
{
	int n;

	/* The records queued before the round; their parents go next round. */
	n = ndue;
	for (int i = 0; i < n; i++)
		free_record(due[i]);
	memmove(due, due + n, (size_t)(ndue - n) * sizeof(due[0]));
	ndue -= n;
	printf("= %d\n", n);
}

static void
reset(void)
{
	for (int i = 0; i < SPACES_MAX; i++) {
		spaces[i].exists = 0;
		spaces[i].released = 0;
		spaces[i].emptied = 0;
		spaces[i].exit = 'N';
		spaces[i].deletions = 0;
		spaces[i].dead = 0;
		spaces[i].nthreads = 0;
	}
	memset(plans, 0, sizeof(plans));
	memset(walks, 0, sizeof(walks));
	memset(deletes, 0, sizeof(deletes));
	ndue = 0;
	dropped = 0;
	nspaces = 0;
	new_record();
	if (erx_space_init_first(spaces[0].space, OBJECT_BASE, 64) != ERX_OK)
		fail("first space refused");
	spaces[0].exists = 1;
	nspaces = 1;
	printf("= 0\n");
}

static void
run_command(char **argv, int argc)
{
	space_slot_t *slot;
	erx_status_t status;
	int id;

	if (strcmp(argv[0], "first") == 0) {
		reset();
	} else if (strcmp(argv[0], "plan") == 0) {
		cmd_plan(argv, argc);
	} else if (strcmp(argv[0], "attach") == 0 && argc == 2) {
		cmd_attach(atoi(argv[1]));
	} else if (strcmp(argv[0], "stop") == 0 && argc == 4) {
		printf("= %d\n", erx_space_stop(fetch_space(atoi(argv[1])),
		    strtoll(argv[2], NULL, 0), strtoull(argv[3], NULL, 0)) ?
		    1 : 0);
	} else if (strcmp(argv[0], "close") == 0 && argc == 2) {
		printf("= %d\n", erx_space_close(fetch_space(atoi(argv[1]))));
	} else if (strcmp(argv[0], "admit") == 0 && argc == 3) {
		printf("= %d\n", erx_space_admit(fetch_space(atoi(argv[1])),
		    (erx_space_admit_t)atoi(argv[2])));
	} else if (strcmp(argv[0], "thread") == 0 && argc == 2) {
		id = atoi(argv[1]);
		status = erx_space_admit(fetch_space(id),
		    ERX_SPACE_ADMIT_THREAD);
		slot = &spaces[id];
		if (status == ERX_OK) {
			if (slot->nthreads == THREADS_MAX)
				fail("too many threads");
			slot->killed[slot->nthreads++] = 0;
		}
		printf("= %d\n", status);
	} else if (strcmp(argv[0], "walk") == 0 && argc == 3) {
		id = atoi(argv[1]);
		if (id < 0 || id >= WALKS_MAX)
			fail("bad walk");
		printf("= %d\n", erx_stop_walk_begin(&walks[id],
		    fetch_space(atoi(argv[2]))));
	} else if (strcmp(argv[0], "step") == 0 && argc == 2) {
		cmd_step(atoi(argv[1]));
	} else if (strcmp(argv[0], "delete") == 0 && argc == 3) {
		cmd_delete(atoi(argv[1]), atoi(argv[2]));
	} else if (strcmp(argv[0], "dstep") == 0 && argc == 2) {
		cmd_dstep(atoi(argv[1]));
	} else if (strcmp(argv[0], "detach") == 0 && argc == 3) {
		printf("= %d\n", erx_space_fault_detach(
		    fetch_space(atoi(argv[1])), strtoull(argv[2], NULL, 0)) ?
		    1 : 0);
	} else if (strcmp(argv[0], "release") == 0 && argc == 2) {
		cmd_release(atoi(argv[1]));
	} else if (strcmp(argv[0], "reap") == 0 && argc == 1) {
		cmd_reap();
	} else if (strcmp(argv[0], "post") == 0 && argc == 2) {
		cmd_post(atoi(argv[1]));
	} else if (strcmp(argv[0], "place") == 0 && argc == 2) {
		cmd_place(atoi(argv[1]));
	} else if (strcmp(argv[0], "dead") == 0 && argc == 2) {
		(void)fetch_space(atoi(argv[1]));
		spaces[atoi(argv[1])].dead = 1;
		print_exit(atoi(argv[1]));
	} else if (strcmp(argv[0], "take") == 0 && argc == 2) {
		cmd_take(atoi(argv[1]));
	} else if (strcmp(argv[0], "exit") == 0 && argc == 2) {
		(void)fetch_space(atoi(argv[1]));
		print_exit(atoi(argv[1]));
	} else if (strcmp(argv[0], "ready") == 0 && argc == 2) {
		cmd_ready(atoi(argv[1]));
	} else if (strcmp(argv[0], "state") != 0) {
		fail("unknown command");
	}
	print_state();
}

int
main(int argc, char **argv)
{
	char *args[12], line[512], *save, *word;
	size_t align;
	FILE *input;
	int nargs;

	if (argc != 2)
		fail("usage: space-driver SCRIPT");
	align = erx_space_record_align();
	record_bytes = (erx_space_record_size() + align - 1) / align * align;
	input = fopen(argv[1], "r");
	if (input == NULL)
		fail("cannot open script");
	while (fgets(line, sizeof(line), input) != NULL) {
		nargs = 0;
		for (word = strtok_r(line, " \t\n", &save); word != NULL;
		    word = strtok_r(NULL, " \t\n", &save)) {
			if (nargs == 12)
				fail("too many words");
			args[nargs++] = word;
		}
		if (nargs > 0)
			run_command(args, nargs);
	}
	fclose(input);
	for (int i = 0; i < SPACES_MAX; i++) {
		if (spaces[i].space != NULL)
			ASAN_UNPOISON_MEMORY_REGION(spaces[i].space, record_bytes);
		free(spaces[i].space);
	}
	return (0);
}
