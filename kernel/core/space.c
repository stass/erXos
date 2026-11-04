/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The space core (docs/design-kernel.md, "Creating spaces"). A space's
 * place in the tree is fixed when it is attached: its parent, its depth,
 * its flags, its capability limit, its fault gate and its label. What
 * changes is its run state, which only advances (LIVE, STOPPED, WALKED,
 * DELETING), whether it is closed, which is never unset, and its parent's
 * list of children, which this file alone edits:
 *
 * - attach links a child at the front, under a parent that is neither
 *   stopped nor closed;
 * - a stop walk's finish marks a child walked and moves it to the end, in
 *   the same critical section under the parent's lock;
 * - a deletion walk unlinks a child as it begins the child's deletion, and
 *   sets it closed, under the parent's lock.
 *
 * So the children that are not walked always come first, a walk that
 * finds its first child walked knows that every child is, and a list
 * names only spaces whose deletion has not begun. So a space dies with its
 * parent: a space's destroy runs the deletion walk over every space below
 * it, and the walk that takes a space off its parent's list owns its
 * deletion.
 *
 * A space's record is freed only after every child's record: holds counts
 * one for each child whose record is not freed, and one for the record
 * itself until it is otherwise ready to free, and only the drop that takes
 * it to zero lets the record go. So a record's parent pointer is valid for
 * the record's whole life, and a walk that holds any space counted keeps
 * every space above it to its root.
 *
 * Locks: the run state moves from LIVE to STOPPED only under the space's
 * own lock, and from STOPPED on only under its parent's; the status and
 * stopper are written before the release store of STOPPED, so a reader
 * that sees a stopped space reads them whole. closed is set by an atomic
 * exchange under the space's own lock when its own destroy closes it, and by
 * a store under its parent's when a deletion walk reaches it, so either may
 * come second and exactly one close of a destroy succeeds; the release store
 * of DELETING publishes it. exit_bits moves by fetch-or under no lock. The fault
 * gate goes by a compare-and-swap. holds rises
 * only in attach, under the parent's lock, and falls by atomic subtraction
 * wherever a record is freed.
 */

#include <stdalign.h>
#include <stdatomic.h>

#include "erx/space.h"

/* The bits of a space's exit word: its record's post, its deletion's begin. */
#define EXIT_POSTED	0x1u
#define EXIT_DELETED	0x2u

typedef struct erx_space_link erx_space_link_t;

/* An intrusive circular list: a head, and a link in each element. */
struct erx_space_link {
	erx_space_link_t *next;
	erx_space_link_t *prev;
};

struct erx_space {
	erx_space_t	*parent;	/* fixed; NULL only for the first space;
					 * valid for this record's whole life */
	erx_space_link_t children;	/* its children whose deletion has not
					 * begun, those not walked first; under
					 * its lock */
	erx_space_link_t in_parent;	/* its link on its parent's list until
					 * its deletion begins; under the
					 * parent's lock */
	uint64_t	 object;	/* its object's handle; fixed */
	_Atomic uint64_t fault_gate;	/* the gate's handle; fixed at attach,
					 * 0 once detached */
	uint64_t	 label;		/* on each of its records; fixed */
	uint64_t	 stopper;	/* the first stop's, written before
					 * run leaves LIVE */
	int64_t		 status;	/* the first stop's, likewise */
	uint32_t	 depth;		/* 0 for the first; fixed */
	uint32_t	 flags;		/* ERX_SPACE_JIT; fixed */
	uint32_t	 cap_limit;	/* its table's limit; fixed */
	_Atomic uint32_t run;		/* an erx_space_run_t; only advances */
	_Atomic uint32_t exit_bits;	/* EXIT_POSTED and EXIT_DELETED, each set
					 * once */
	_Atomic bool	 closed;	/* set by its destroy's close or the
					 * deletion walk that reaches it */
	_Atomic uint64_t holds;		/* its children's records not freed,
					 * plus one until it is ready to free;
					 * it cannot wrap, since each is a
					 * record in memory */
};

static void	list_init(erx_space_link_t *);
static bool	deletion_take(erx_space_t *);
static bool	list_is_empty(const erx_space_link_t *);
static void	list_insert_after(erx_space_link_t *, erx_space_link_t *);
static void	list_remove(erx_space_link_t *);
static erx_space_t *first_child(const erx_space_t *);
static erx_space_t *space_of_link(const erx_space_link_t *);
static erx_space_run_t run_load(const erx_space_t *);
static void	run_store(erx_space_t *, erx_space_run_t);
static bool	space_at_or_below(const erx_space_t *, const erx_space_t *);
static void	space_init(erx_space_t *, erx_space_t *, uint64_t, uint32_t,
		    uint32_t, uint32_t, uint64_t, uint64_t);
static bool	space_stop(erx_space_t *, int64_t, uint64_t);
static bool	space_unhold(erx_space_t *);
static erx_status_t source_check(const erx_space_source_t *, erx_ktype_t,
		    uint32_t);

size_t
erx_space_record_size(void)
{
	return (sizeof(erx_space_t));
}

size_t
erx_space_record_align(void)
{
	return (alignof(erx_space_t));
}

erx_status_t
erx_space_init_first(erx_space_t *space, uint64_t object, uint32_t cap_limit)
{
	if (space == NULL || object == 0 || cap_limit < 2 ||
	    cap_limit > ERX_CAPS_MAX)
		return (ERX_EINVAL);
	space_init(space, NULL, object, 0, 0, cap_limit, 0, 0);
	return (ERX_OK);
}

erx_status_t
erx_space_plan(const erx_space_request_t *request, erx_space_plan_t *plan)
{
	const erx_space_t *parent, *self;
	erx_status_t error;

	*plan = (erx_space_plan_t){ .stage = ERX_SPACE_REFUSED };
	self = request->self;
	parent = request->parent;
	if (self == NULL || parent == NULL)
		return (ERX_EINVAL);

	if ((request->flags & ~ERX_SPACE_JIT) != 0 || request->cap_limit < 2 ||
	    request->cap_limit > ERX_CAPS_MAX)
		return (ERX_EINVAL);

	/* The capabilities in argument order, each as the one lookup would. */
	error = source_check(&request->budget, ERX_K_BUDGET,
	    ERX_HR_ALLOC | ERX_HR_SPACES);
	if (error != ERX_OK)
		return (error);
	if (request->parent_self) {
		if (parent != self)
			return (ERX_EINVAL);
	} else {
		error = source_check(&request->parent_cap, ERX_K_SPACE,
		    ERX_HR_CAPS);
		if (error != ERX_OK)
			return (error);
		if (parent->object != request->parent_cap.view.object)
			return (ERX_EINVAL);
	}
	error = source_check(&request->fault, ERX_K_GATE, ERX_HR_SERVE);
	if (error != ERX_OK)
		return (error);

	/*
	 * The right to make code follows from the image: a space allows JIT
	 * objects only when its budget may make code or its creator's own
	 * space allows them.
	 */
	if ((request->flags & ERX_SPACE_JIT) != 0 &&
	    !erx_rights_contain(request->budget.view.rights, ERX_HR_CODE) &&
	    (self->flags & ERX_SPACE_JIT) == 0)
		return (ERX_ERIGHTS);

	/*
	 * The parent's state first, then its place: only a parent that takes
	 * children is worth the walk up its chain, which follows parent
	 * pointers that are valid because the parent's record is, and every
	 * record outlives its children's.
	 */
	error = erx_space_admit(parent, ERX_SPACE_ADMIT_CHILD);
	if (error != ERX_OK)
		return (error);
	if (!space_at_or_below(parent, self))
		return (ERX_ERIGHTS);
	if (parent->depth >= ERX_SPACE_DEPTH_MAX)
		return (ERX_ELIMIT);

	*plan = (erx_space_plan_t){
		.stage = ERX_SPACE_PLANNED,
		.parent = request->parent,
		.budget = request->budget.view.object,
		.fault_gate = request->fault.view.object,
		.label = request->label,
		.depth = parent->depth + 1,
		.flags = request->flags,
		.cap_limit = request->cap_limit
	};
	return (ERX_OK);
}

erx_status_t
erx_space_attach(erx_space_plan_t *plan, erx_space_t *space, uint64_t object)
{
	erx_space_t *parent;
	erx_status_t error;

	if (plan->stage != ERX_SPACE_PLANNED || plan->parent == NULL ||
	    space == NULL || object == 0)
		return (ERX_EINVAL);
	plan->stage = ERX_SPACE_SPENT;
	parent = plan->parent;

	/*
	 * Checked under the parent's lock, under which a walk reads the
	 * parent's list: a child attached here is at the front of the list
	 * before any walk of the parent reads it, and once the parent has
	 * stopped no child joins, so the lists below a stopped space only
	 * shrink.
	 */
	error = erx_space_admit(parent, ERX_SPACE_ADMIT_CHILD);
	if (error != ERX_OK)
		return (error);

	space_init(space, parent, object, plan->depth, plan->flags,
	    plan->cap_limit, plan->fault_gate, plan->label);
	list_insert_after(&parent->children, &space->in_parent);
	/*
	 * The child's record holds the parent's. The parent is not closed
	 * and the caller holds it counted, so it is not ready to free and its
	 * count is at least its own hold: the count never rises from zero.
	 */
	atomic_fetch_add_explicit(&parent->holds, 1, memory_order_relaxed);
	return (ERX_OK);
}

erx_status_t
erx_space_admit(const erx_space_t *space, erx_space_admit_t what)
{
	switch (what) {
	case ERX_SPACE_ADMIT_CHILD:
	case ERX_SPACE_ADMIT_THREAD:
	case ERX_SPACE_ADMIT_MAPPING:
		break;
	default:
		return (ERX_EINVAL);
	}

	/* A space being destroyed is gone to its callers, as a stale value is. */
	if (atomic_load_explicit(&space->closed, memory_order_relaxed))
		return (ERX_ESTALE);
	if (what != ERX_SPACE_ADMIT_MAPPING && run_load(space) != ERX_SPACE_LIVE)
		return (ERX_EDEAD);
	return (ERX_OK);
}

bool
erx_space_stop(erx_space_t *space, int64_t status, uint64_t stopper)
{
	return (space_stop(space, status, stopper));
}

erx_status_t
erx_space_close(erx_space_t *space)
{
	/* An exchange: a deletion walk may set it at any time. */
	if (atomic_exchange_explicit(&space->closed, true, memory_order_relaxed))
		return (ERX_ESTALE);
	return (ERX_OK);
}

bool
erx_space_stopped(const erx_space_t *space)
{
	return (run_load(space) != ERX_SPACE_LIVE);
}

erx_space_t *
erx_space_parent(const erx_space_t *space)
{
	return (space->parent);
}

erx_space_t *
erx_space_child_after(const erx_space_t *space, const erx_space_t *child)
{
	const erx_space_link_t *link;

	link = child == NULL ? &space->children : &child->in_parent;
	if (link->next == &space->children)
		return (NULL);
	return (space_of_link(link->next));
}

void
erx_space_read(const erx_space_t *space, erx_space_facts_t *facts)
{
	erx_space_run_t run;

	run = run_load(space);
	*facts = (erx_space_facts_t){
		.object = space->object,
		.parent = space->parent == NULL ? 0 : space->parent->object,
		.fault_gate = erx_space_fault_gate(space),
		.label = space->label,
		.stopper = run == ERX_SPACE_LIVE ? 0 : space->stopper,
		.status = run == ERX_SPACE_LIVE ? 0 : space->status,
		.depth = space->depth,
		.flags = space->flags,
		.cap_limit = space->cap_limit,
		.run = run,
		.closed = atomic_load_explicit(&space->closed,
		    memory_order_relaxed)
	};
}

uint64_t
erx_space_holds(const erx_space_t *space)
{
	return (atomic_load_explicit(&space->holds, memory_order_relaxed));
}

void
erx_space_record_init(erx_space_t *space)
{
	space->parent = NULL;
	atomic_init(&space->holds, 1);
}

bool
erx_space_free_ready(erx_space_t *space)
{
	return (space_unhold(space));
}

erx_space_t *
erx_space_unhold_parent(erx_space_t *space)
{
	erx_space_t *parent;

	parent = space->parent;
	if (parent == NULL || !space_unhold(parent))
		return (NULL);
	return (parent);
}

uint64_t
erx_space_fault_gate(const erx_space_t *space)
{
	/* Relaxed: the handle names an object; no other field rides on it. */
	return (atomic_load_explicit(&space->fault_gate, memory_order_relaxed));
}

bool
erx_space_fault_detach(erx_space_t *space, uint64_t gate)
{
	uint64_t expected;

	if (gate == 0)
		return (false);
	expected = gate;
	return (atomic_compare_exchange_strong_explicit(&space->fault_gate,
	    &expected, 0, memory_order_relaxed, memory_order_relaxed));
}

erx_status_t
erx_stop_walk_begin(erx_stop_walk_t *walk, erx_space_t *root)
{
	if (root == NULL || run_load(root) == ERX_SPACE_LIVE)
		return (ERX_EINVAL);
	*walk = (erx_stop_walk_t){ .root = root, .cursor = root };
	return (ERX_OK);
}

erx_stop_action_t
erx_stop_step(erx_stop_walk_t *walk, bool unkilled)
{
	erx_space_t *child, *cursor;

	walk->drop = NULL;
	cursor = walk->cursor;
	if (cursor == NULL)
		return (ERX_STOP_DONE);
	if (walk->finishing)
		return (ERX_STOP_INVALID);

	/*
	 * A space the walk descended into may not have stopped yet: stop it
	 * here, under its own lock, before its list is read, so it takes no
	 * child the walk would miss, and say so, since the stop has effects
	 * of its own. Its parent stopped before the walk descended from it,
	 * so the parent's stopper is written.
	 */
	if (run_load(cursor) == ERX_SPACE_LIVE) {
		space_stop(cursor, ERX_EXIT_PARENT, cursor->parent->stopper);
		return (ERX_STOP_STOPPED);
	}

	if (unkilled)
		return (ERX_STOP_KILL);

	/* The run states are declared in the order they advance. */
	child = first_child(cursor);
	if (child != NULL && run_load(child) < ERX_SPACE_WALKED) {
		walk->cursor = child;
		walk->drop = walk->held;
		walk->held = child;
		return (ERX_STOP_DESCEND);
	}
	walk->finishing = true;
	return (ERX_STOP_FINISH);
}

erx_stop_action_t
erx_stop_finish(erx_stop_walk_t *walk)
{
	erx_space_t *cursor;

	walk->drop = NULL;
	cursor = walk->cursor;
	if (cursor == NULL || !walk->finishing)
		return (ERX_STOP_INVALID);
	walk->finishing = false;

	/*
	 * Under the parent's lock, as the walks that read the parent's list
	 * are: the mark and the move are one critical section, so no walk
	 * sees a walked child ahead of one that is not. A space another
	 * walk marked first stays where that walk put it, and one whose
	 * deletion began is on no list.
	 */
	if (run_load(cursor) == ERX_SPACE_STOPPED) {
		run_store(cursor, ERX_SPACE_WALKED);
		if (cursor->parent != NULL) {
			list_remove(&cursor->in_parent);
			list_insert_after(cursor->parent->children.prev,
			    &cursor->in_parent);
		}
	}

	if (cursor == walk->root) {
		walk->cursor = NULL;
		walk->drop = walk->held;
		walk->held = NULL;
		return (ERX_STOP_DONE);
	}
	/* The held space, at or below the cursor, keeps the parent's record. */
	walk->cursor = cursor->parent;
	return (ERX_STOP_ASCEND);
}

erx_status_t
erx_delete_walk_begin(erx_delete_walk_t *walk, erx_space_t *root,
    erx_delete_walk_action_t *action)
{
	erx_space_run_t run;

	if (root == NULL ||
	    !atomic_load_explicit(&root->closed, memory_order_relaxed))
		return (ERX_EINVAL);
	run = run_load(root);
	if (run != ERX_SPACE_WALKED && run != ERX_SPACE_DELETING)
		return (ERX_EINVAL);

	*walk = (erx_delete_walk_t){ .root = root };
	if (run == ERX_SPACE_DELETING) {
		/* Another walk unlinked root, and owns it and all below it. */
		*action = ERX_DELETE_DONE;
		return (ERX_OK);
	}

	walk->withdraw = deletion_take(root);
	walk->cursor = root;
	*action = ERX_DELETE_SPACE;
	return (ERX_OK);
}

erx_delete_walk_action_t
erx_delete_walk_step(erx_delete_walk_t *walk)
{
	erx_space_t *child, *cursor;

	walk->drop = NULL;
	walk->withdraw = false;
	cursor = walk->cursor;
	if (cursor == NULL)
		return (ERX_DELETE_DONE);

	child = first_child(cursor);
	if (child != NULL) {
		/*
		 * The stop walk of the root was done before this walk began,
		 * and no child joins a stopped space, so every listed child
		 * is walked; one that is not is a broken tree.
		 */
		if (run_load(child) != ERX_SPACE_WALKED)
			return (ERX_DELETE_INVALID);
		walk->withdraw = deletion_take(child);
		walk->cursor = child;
		walk->drop = walk->held;
		walk->held = child;
		return (ERX_DELETE_SPACE);
	}
	if (cursor == walk->root) {
		walk->cursor = NULL;
		walk->drop = walk->held;
		walk->held = NULL;
		return (ERX_DELETE_DONE);
	}
	/* The held space, at or below the cursor, keeps the parent's record. */
	walk->cursor = cursor->parent;
	return (ERX_DELETE_ASCEND);
}

erx_space_post_t
erx_space_exit_post(erx_space_t *space)
{
	uint32_t old;

	/* Relaxed: one word's order of changes decides; nothing rides on it. */
	old = atomic_fetch_or_explicit(&space->exit_bits, EXIT_POSTED,
	    memory_order_relaxed);
	if ((old & EXIT_POSTED) != 0)
		return (ERX_SPACE_POST_NONE);
	return ((old & EXIT_DELETED) != 0 ? ERX_SPACE_POST_DROP :
	    ERX_SPACE_POST_QUEUE);
}

bool
erx_space_exit_waits(const erx_space_t *space)
{
	/*
	 * Relaxed: the caller holds the gate's lock, and a withdrawal that held
	 * it first did so after its fetch-or, so this reads the bit; one that
	 * comes later finds the place this caller records.
	 */
	return ((atomic_load_explicit(&space->exit_bits, memory_order_relaxed) &
	    EXIT_DELETED) == 0);
}

/*
 * The one critical section that begins a space's deletion, under its
 * parent's lock (none for the first space): the walk that makes it owns the
 * deletion. Its own destroy may have closed it already, when the store
 * changes nothing; the release store of the run word publishes it. True when
 * its exit record was posted first, so the caller asks for its withdrawal.
 */
static bool
deletion_take(erx_space_t *space)
{
	uint32_t old;

	atomic_store_explicit(&space->closed, true, memory_order_relaxed);
	old = atomic_fetch_or_explicit(&space->exit_bits, EXIT_DELETED,
	    memory_order_relaxed);
	run_store(space, ERX_SPACE_DELETING);
	if (space->parent != NULL)
		list_remove(&space->in_parent);
	return ((old & EXIT_POSTED) != 0);
}

static void
list_init(erx_space_link_t *head)
{
	head->next = head;
	head->prev = head;
}

static bool
list_is_empty(const erx_space_link_t *head)
{
	return (head->next == head);
}

static void
list_insert_after(erx_space_link_t *at, erx_space_link_t *link)
{
	link->prev = at;
	link->next = at->next;
	at->next->prev = link;
	at->next = link;
}

static void
list_remove(erx_space_link_t *link)
{
	link->prev->next = link->next;
	link->next->prev = link->prev;
	list_init(link);
}

static erx_space_t *
first_child(const erx_space_t *space)
{
	if (list_is_empty(&space->children))
		return (NULL);
	return (space_of_link(space->children.next));
}

static erx_space_t *
space_of_link(const erx_space_link_t *link)
{
	return ((erx_space_t *)(uintptr_t)((uintptr_t)link -
	    offsetof(erx_space_t, in_parent)));
}

static erx_space_run_t
run_load(const erx_space_t *space)
{
	/* Pairs with the release in run_store: the stop's status and stopper. */
	return ((erx_space_run_t)atomic_load_explicit(&space->run,
	    memory_order_acquire));
}

static void
run_store(erx_space_t *space, erx_space_run_t run)
{
	/* Pairs with the acquire in run_load. */
	atomic_store_explicit(&space->run, (uint32_t)run, memory_order_release);
}

/*
 * Whether space is ancestor or a space below it: the walk up the fixed
 * chain of parents takes exactly the difference of their depths, at
 * most ERX_SPACE_DEPTH_MAX steps.
 */
static bool
space_at_or_below(const erx_space_t *space, const erx_space_t *ancestor)
{
	uint32_t steps;

	if (space->depth < ancestor->depth)
		return (false);
	steps = space->depth - ancestor->depth;
	if (steps > ERX_SPACE_DEPTH_MAX)
		return (false);
	for (uint32_t i = 0; i < steps; i++) {
		space = space->parent;
		if (space == NULL)
			return (false);
	}
	return (space == ancestor);
}

static void
space_init(erx_space_t *space, erx_space_t *parent, uint64_t object,
    uint32_t depth, uint32_t flags, uint32_t cap_limit, uint64_t fault_gate,
    uint64_t label)
{
	space->parent = parent;
	list_init(&space->children);
	list_init(&space->in_parent);
	space->object = object;
	atomic_init(&space->fault_gate, fault_gate);
	space->label = label;
	space->stopper = 0;
	space->status = 0;
	space->depth = depth;
	space->flags = flags;
	space->cap_limit = cap_limit;
	atomic_init(&space->run, (uint32_t)ERX_SPACE_LIVE);
	atomic_init(&space->exit_bits, 0);
	atomic_init(&space->closed, false);
	atomic_init(&space->holds, 1);
}

/* Under the space's own lock: the one place a space leaves LIVE. */
static bool
space_stop(erx_space_t *space, int64_t status, uint64_t stopper)
{
	if (run_load(space) != ERX_SPACE_LIVE)
		return (false);
	space->status = status;
	space->stopper = stopper;
	run_store(space, ERX_SPACE_STOPPED);
	return (true);
}

/*
 * Drop one hold of the space's record: true when it was the last, so the
 * record goes now. Acquire and release, so that whoever frees the record
 * sees every write the other holders made before their drops.
 */
static bool
space_unhold(erx_space_t *space)
{
	return (atomic_fetch_sub_explicit(&space->holds, 1,
	    memory_order_acq_rel) == 1);
}

static erx_status_t
source_check(const erx_space_source_t *source, erx_ktype_t type,
    uint32_t required)
{
	if (source->status != ERX_OK)
		return (source->status);
	if (source->view.type != type)
		return (ERX_ETYPE);
	if (!erx_rights_contain(source->view.rights, required))
		return (ERX_ERIGHTS);
	return (ERX_OK);
}
