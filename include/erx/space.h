/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_SPACE_H
#define ERX_SPACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cap.h"
#include "erx/cdefs.h"

/*
 * The space core: a space's place in the tree of spaces and its life in
 * that tree (docs/design-kernel.md, "Creating spaces"). It decides a
 * creation whole from what the caller's lookups returned, admits the new
 * space under its parent's lock, and decides each step of the two walks
 * that visit a tree, the stop walk and the deletion walk. It reads no
 * hardware and takes no lock; each function names the lock its caller
 * holds. It never dereferences an object handle.
 *
 * Every space but the first names its parent at creation, the creator's
 * own space or a space below it, and nothing changes the parent, the
 * depth, the flags, the capability limit, the fault gate or the label
 * afterwards; the fault gate only goes, when the gate is destroyed. A
 * space's run state only advances:
 *
 *   LIVE      not stopped: takes children, threads and mappings;
 *   STOPPED   stopped once, with the first stop's status and stopper; its
 *             stop walk has not found every thread killed and every child
 *             walked;
 *   WALKED    a stop walk found every thread of it killed and every child
 *             walked, and moved it to the end of its parent's list;
 *   DELETING  a deletion walk has begun its deletion and took it off its
 *             parent's list.
 *
 * Closing is a separate fact that is set by the space's own destroy, in
 * any run state, or by the deletion walk that reaches it, and never
 * unset; a space's destroy then drains it and stops it with
 * ERX_EXIT_RELEASED unless it had stopped. A closed space takes nothing
 * (ERX_ESTALE); a stopped one takes no child and no thread (ERX_EDEAD).
 *
 * Each space's list of children holds the children whose deletion has not
 * begun, and in every list the children that are not walked come first: a
 * creation adds a child at the front of a parent that is not stopped, a
 * stop walk moves a child to the end when it marks it walked, and a
 * deletion walk unlinks a child when it begins its deletion, and sets it
 * closed. Only this core changes a list, so the order holds by
 * construction, and since no list below a stopped space grows, every walk
 * ends.
 *
 * A space dies with its parent: a space's destroy runs the deletion walk
 * over the spaces below it, and the walk that takes a space off its parent's
 * list owns that space's deletion, whoever closed it first. So once the walks
 * have ended, on their calls' time, no capability keeps a space whose parent
 * is deleted, and a space's record waits for its children's only through the
 * deletion's own bounds.
 *
 * A space's record is freed only after every child's record, as a dead
 * budget's tombstone is. Each record counts its holds: one for each child
 * whose record is not freed, and one for itself, which the caller drops
 * with erx_space_free_ready once the record is otherwise ready to free.
 * The drop that takes the count to zero frees the record. So a space's
 * parent pointer is valid for its record's whole life, and a record held
 * counted keeps every record above it. A chain is freed one level at a
 * time: erx_space_unhold_parent hands back the parent whose last hold it
 * dropped, and the caller queues that parent's free rather than freeing it
 * in the same call, so no free recurses and a chain is at most
 * ERX_SPACE_DEPTH_MAX long. Once a space is ready to free, no call takes a
 * new path to it; only a walk already below it reaches it, by its cursor. No
 * counted reference is ever taken through a parent pointer or a cursor that
 * went back up: it would not keep the record, whose free waits only for its
 * children.
 *
 * The records are opaque: struct erx_space is defined only in
 * kernel/core/space.c. A caller allocates a record of
 * erx_space_record_size() bytes and erx_space_record_align() alignment,
 * and the core initialises it.
 */

typedef struct erx_space erx_space_t;
typedef struct erx_space_facts erx_space_facts_t;
typedef struct erx_space_plan erx_space_plan_t;
typedef struct erx_space_request erx_space_request_t;
typedef struct erx_space_source erx_space_source_t;
typedef struct erx_stop_walk erx_stop_walk_t;
typedef struct erx_delete_walk erx_delete_walk_t;

typedef enum erx_space_run {
	ERX_SPACE_LIVE = 1,
	ERX_SPACE_STOPPED,
	ERX_SPACE_WALKED,
	ERX_SPACE_DELETING
} erx_space_run_t;

/* What a caller asks a space to take. */
typedef enum erx_space_admit {
	ERX_SPACE_ADMIT_CHILD = 1,
	ERX_SPACE_ADMIT_THREAD,
	ERX_SPACE_ADMIT_MAPPING
} erx_space_admit_t;

/* What the one lookup returned for one capability argument. */
struct erx_space_source {
	erx_status_t	 status;	/* erx_cap_read's, with any type and no rights */
	erx_cap_view_t	 view;		/* valid when status is ERX_OK */
};

/*
 * A creation as erx_space_create's arguments name it. The caller reads
 * each capability with erx_cap_read, any type and no rights, and resolves
 * the parent capability's object to its record; for ERX_CAP_SELF it sets
 * parent_self and names its own record as parent. self is the calling
 * thread's space.
 */
struct erx_space_request {
	const erx_space_t *self;
	erx_space_t	*parent;
	erx_space_source_t budget;	/* needs ALLOC and SPACES */
	erx_space_source_t parent_cap;	/* needs CAPS; ignored when parent_self */
	erx_space_source_t fault;	/* a gate, with SERVE */
	uint64_t	 label;
	uint32_t	 flags;		/* ERX_SPACE_JIT */
	uint32_t	 cap_limit;	/* table slots, slot 0 included */
	bool		 parent_self;
};

/*
 * A plan is attached at most once: erx_space_attach accepts only a
 * PLANNED plan and spends it whatever it decides.
 */
typedef enum erx_space_stage {
	ERX_SPACE_REFUSED = 0,	/* erx_space_plan refused it, or never ran */
	ERX_SPACE_PLANNED,
	ERX_SPACE_SPENT		/* attached, or refused by the parent */
} erx_space_stage_t;

/* An accepted creation: what the caller charges and what attach records. */
struct erx_space_plan {
	erx_space_stage_t stage;
	erx_space_t	*parent;
	uint64_t	 budget;	/* the budget object that pays */
	uint64_t	 fault_gate;	/* the gate object; fixed */
	uint64_t	 label;
	uint32_t	 depth;		/* the parent's depth plus one */
	uint32_t	 flags;
	uint32_t	 cap_limit;
};

/* A snapshot of one space, as inspection reports it. */
struct erx_space_facts {
	uint64_t	 object;
	uint64_t	 parent;	/* the parent's object; 0 for the first space */
	uint64_t	 fault_gate;	/* 0 once the gate is destroyed, and for the first */
	uint64_t	 label;
	uint64_t	 stopper;	/* the first stop's; 0 while live */
	int64_t		 status;	/* the first stop's; 0 while live */
	uint32_t	 depth;
	uint32_t	 flags;
	uint32_t	 cap_limit;
	erx_space_run_t	 run;
	bool		 closed;
};

size_t	erx_space_record_size(void);
size_t	erx_space_record_align(void);

/*
 * The first space, the system domain's: depth 0, no parent, no fault gate
 * and no flags, so its faults have nowhere to go but the machine's end and
 * it makes no code. No other call makes a space without a parent.
 * ERX_EINVAL for object 0 or a capability limit outside 2 to ERX_CAPS_MAX.
 */
erx_status_t	erx_space_init_first(erx_space_t *space, uint64_t object,
		    uint32_t cap_limit) ERX_WARN_UNUSED_RESULT;

/*
 * Decide a creation whole: a pure function of the request, reading only
 * fields that never change (each space's parent, depth, flags and object)
 * and the parent's closed and run state, so it needs no lock. The caller
 * runs it in a read section of the grace period, which keeps the parent's
 * record, found by a lookup, from being freed while it runs, and every
 * record above it outlives it, so the walk up its chain reads only live
 * records.
 *
 * The refusals, in the order they are checked:
 *
 *   1. ERX_EINVAL for a NULL self or parent, an unknown flag, or a
 *      capability limit outside 2 to ERX_CAPS_MAX;
 *   2. the budget's lookup status, ERX_ETYPE for a non-budget and
 *      ERX_ERIGHTS without ALLOC and SPACES;
 *   3. the same for the parent (a space, with CAPS), and ERX_EINVAL when
 *      the parent record is not the one the capability names, or
 *      parent_self names another record than self;
 *   4. the same for the fault gate (a gate, with SERVE);
 *   5. ERX_ERIGHTS for ERX_SPACE_JIT when the budget lacks CODE and self
 *      does not allow JIT objects;
 *   6. ERX_ESTALE for a closed parent and ERX_EDEAD for a stopped one;
 *   7. ERX_ERIGHTS for a parent that is not self or a space below it;
 *   8. ERX_ELIMIT for a parent at depth ERX_SPACE_DEPTH_MAX.
 *
 * The plan is written on every outcome; it is PLANNED only on ERX_OK.
 */
erx_status_t	erx_space_plan(const erx_space_request_t *request,
		    erx_space_plan_t *plan) ERX_WARN_UNUSED_RESULT;

/*
 * Admit a planned space under its parent's lock: ERX_EINVAL, changing
 * nothing, for a plan not PLANNED, a NULL record or object 0; otherwise
 * the plan is spent, and ERX_ESTALE for a closed parent, ERX_EDEAD for a
 * stopped one, or ERX_OK: the record is initialised from the plan, live,
 * and linked at the front of its parent's list. The record is the
 * caller's, from erx_space_record_init, unreachable until this returns;
 * one refused stays at that start and goes by the free steps below. The
 * plan names the parent's record, so the caller takes a counted
 * reference to the parent inside the plan's read section and holds it
 * until this returns.
 */
erx_status_t	erx_space_attach(erx_space_plan_t *plan, erx_space_t *space,
		    uint64_t object) ERX_WARN_UNUSED_RESULT;

/*
 * Whether the space takes a child, a thread or a mapping, under its lock:
 * ERX_ESTALE when closed; ERX_EDEAD for a child or a thread once stopped;
 * ERX_EINVAL for an unknown kind.
 */
erx_status_t	erx_space_admit(const erx_space_t *space, erx_space_admit_t what);

/*
 * Stop a space, under its lock: the first stop records its status and
 * stopper and makes the space STOPPED; a later stop changes nothing.
 * True when this call stopped it. Its threads and its children are the
 * stop walk's, and its exit record goes by erx_space_exit_post.
 */
bool		erx_space_stop(erx_space_t *space, int64_t status,
		    uint64_t stopper);

/*
 * Close a space for its destroy, under its lock: from now on it takes
 * nothing. ERX_ESTALE for a space already closed, by another destroy or by
 * the deletion walk that reached it: this destroy stops there, since the
 * one that closed it goes on. Otherwise the destroy drains the space next,
 * then stops it with ERX_EXIT_RELEASED.
 */
erx_status_t	erx_space_close(erx_space_t *space)
		    ERX_WARN_UNUSED_RESULT;

/* Whether the space has stopped, with no lock: one acquire load. */
bool		erx_space_stopped(const erx_space_t *space);
/*
 * The parent record, valid for the space's record's whole life, since a
 * record is freed only after every child's.
 */
erx_space_t    *erx_space_parent(const erx_space_t *space);
/*
 * Inspection of a space's list: the child after child, or the first for
 * NULL; NULL after the last. The caller holds the space's lock across the
 * whole listing, so child is on the list: the list holds no counted
 * reference, and a child that left it may be freed.
 */
erx_space_t    *erx_space_child_after(const erx_space_t *space,
		    const erx_space_t *child);
void		erx_space_read(const erx_space_t *space, erx_space_facts_t *facts);

/*
 * The two steps of a space's record free, on the reaper's path alone. Each
 * drop is one atomic subtraction, so neither takes a lock and a space's
 * readiness cannot race its children's frees.
 *
 * erx_space_record_init gives a record its defined start, straight after
 * its allocation and before anything can refuse the creation: no parent
 * and its own hold. So a record whose attach never ran is freed as any
 * other: its readiness says now, and it has no parent to drop.
 *
 * erx_space_free_ready is the readiness step, made once per record, when
 * its deletion has begun or it was never attached, its exit record is
 * delivered or dropped, its put has run and its last counted reference has
 * gone. It drops the record's own hold: true when no child's record
 * remains, so the caller frees the record now; false when the free of its
 * last child's record hands it on. A queued free skips this step.
 *
 * erx_space_unhold_parent is the free step's one call into the core, made
 * for each record the caller frees, before its memory goes. It drops the
 * hold the record has on its parent, and returns the parent when that was
 * the parent's last, whose free the caller queues for its next round; NULL
 * otherwise, and for a record without a parent.
 *
 * erx_space_holds reads the count, for tests: it counts children other
 * parties pay for and moves with their references, so inspection does not
 * report it.
 */
void		erx_space_record_init(erx_space_t *space);
bool		erx_space_free_ready(erx_space_t *space);
erx_space_t    *erx_space_unhold_parent(erx_space_t *space);
uint64_t	erx_space_holds(const erx_space_t *space);

/*
 * The fault gate's object, with no lock (0 once detached, and for the
 * first space), and its detach when the gate is destroyed: the gate goes
 * only if it is still gate, and no call sets another. True when it went.
 */
uint64_t	erx_space_fault_gate(const erx_space_t *space);
bool		erx_space_fault_detach(erx_space_t *space, uint64_t gate);

/*
 * The stop walk over the tree below root, which its caller has stopped:
 * iterative and stackless, its position being the cursor and the root.
 * The caller holds two counted references: the root, and the held space,
 * the last space the walk descended into (none before the first descent).
 * The cursor is the held space or above it, below the root or the root,
 * so the held space's record keeps the cursor's, and going back up takes
 * no reference. The caller holds the root across this walk and the deletion
 * walk that may follow it, and drops it after the last walk's first DONE.
 * Each erx_stop_step is made under the cursor's lock, and erx_stop_finish
 * under the lock of the cursor's parent (no lock for the first space), the
 * cursor's own lock dropped first: a walk holds one space's lock at a time.
 *
 *   ERX_STOP_STOPPED  the cursor, which the walk descended into, was live
 *                     and this step stopped it, with ERX_EXIT_PARENT and
 *                     its parent's stopper: carry out the stop's effects
 *                     (the fence, the interrupts, the exit record when no
 *                     thread is active), then step again;
 *   ERX_STOP_KILL     the cursor has a thread with no kill posted: post
 *                     the kills of a part of its threads, moving each to
 *                     the end of its list, then step again;
 *   ERX_STOP_DESCEND  the cursor's first child was not walked: it is the
 *                     cursor now;
 *   ERX_STOP_FINISH   every thread of the cursor is killed and every
 *                     child walked: call erx_stop_finish;
 *   ERX_STOP_ASCEND   (from finish) the cursor was marked walked and moved
 *                     to the end of its parent's list, and the parent is
 *                     the cursor now;
 *   ERX_STOP_DONE     the root is walked; the walk is over;
 *   ERX_STOP_INVALID  a step out of order: nothing changed.
 *
 * At a DESCEND the caller takes a counted reference to the new held
 * space under the lock the step was made under, while the list names it.
 * Every step leaves in walk->drop the reference it ended (the space held
 * before, at a DESCEND or the first DONE; otherwise NULL), which the caller
 * drops after it releases that lock. Every
 * space a walk descends into is stopped before its list is read. A
 * stopped space takes no thread and no child, so a FINISH stays true
 * after the cursor's lock is dropped. Two walks may cross the same
 * subtree; whichever finishes a space first marks it walked and moves it,
 * and the other leaves it.
 */
typedef enum erx_stop_action {
	ERX_STOP_KILL = 1,
	ERX_STOP_DESCEND,
	ERX_STOP_FINISH,
	ERX_STOP_ASCEND,
	ERX_STOP_DONE,
	ERX_STOP_INVALID,
	ERX_STOP_STOPPED
} erx_stop_action_t;

struct erx_stop_walk {
	erx_space_t	*root;
	erx_space_t	*cursor;	/* NULL once the walk is done */
	erx_space_t	*held;		/* the last space descended into; NULL
					 * before the first and once done */
	erx_space_t	*drop;		/* the reference this step ended, or NULL */
	bool		 finishing;	/* a FINISH awaits erx_stop_finish */
};

/* ERX_EINVAL for a root that has not stopped. */
erx_status_t	erx_stop_walk_begin(erx_stop_walk_t *walk, erx_space_t *root)
		    ERX_WARN_UNUSED_RESULT;
/* unkilled: the cursor's first thread has no kill posted. */
erx_stop_action_t erx_stop_step(erx_stop_walk_t *walk, bool unkilled);
erx_stop_action_t erx_stop_finish(erx_stop_walk_t *walk);

/*
 * The deletion walk over the tree below root, begun once root is closed
 * and the caller's stop walk of it is done. It deletes every space it
 * unlinks, whatever capabilities name them, so every space below root is
 * deleted by this walk or by the walk that unlinked it first, each on its
 * own call's time. erx_delete_walk_begin is made
 * under the lock of root's parent (no lock for the first space) and each
 * erx_delete_walk_step under the cursor's lock. Its counted references are the
 * stop walk's: the root, and the held space, the last child whose
 * deletion it began, which the caller counts at that DELETE under the lock
 * the step was made under. Every step leaves in walk->drop the reference
 * it ended, which the caller drops after it releases that lock:
 *
 *   ERX_DELETE_SPACE   the cursor's deletion has begun: it is DELETING,
 *                      closed and off its parent's list, so no other walk
 *                      reaches it and this walk owns its deletion, whoever
 *                      closed it. The caller runs two parts. Its close,
 *                      still holding the lock of the cursor's parent (none
 *                      for the first space): invalidate the cursor's
 *                      existence lock, whatever that returns, take the
 *                      cursor's table's lock (a space's lock comes before
 *                      a table's in the lock order), set the table's
 *                      emptied flag and drop both. Then, with the cursor
 *                      held, its own deletion, in bounded parts: drain it,
 *                      empty its table, detach its mapping records, ask
 *                      for the withdrawal of its exit record when
 *                      walk->withdraw says it was posted, and queue its
 *                      put. Then step;
 *   ERX_DELETE_ASCEND  the cursor's list is empty and it is not the root:
 *                      its parent is the cursor now;
 *   ERX_DELETE_DONE    the walk is over: every space it unlinked is
 *                      deleted, or another walk had begun root's deletion,
 *                      which owns root and everything below it, so the
 *                      caller does nothing more for root; every later step
 *                      says DONE again;
 *   ERX_DELETE_INVALID a listed child that is not walked, which no call can
 *                      make: a broken tree, on which the caller traps;
 *                      nothing changed.
 *
 * An empty list means that each child's deletion is done or is being run
 * by the walk that unlinked it, which runs to its end. The caller's parts
 * start no walk: a descendant is deleted by this walk alone, so the walk
 * stays iterative and stackless.
 *
 */
typedef enum erx_delete_walk_action {
	ERX_DELETE_SPACE = 1,
	ERX_DELETE_ASCEND,
	ERX_DELETE_DONE,
	ERX_DELETE_INVALID
} erx_delete_walk_action_t;

struct erx_delete_walk {
	erx_space_t	*root;
	erx_space_t	*cursor;	/* NULL once the walk is done */
	erx_space_t	*held;		/* the last child whose deletion it began;
					 * NULL before the first and once done */
	erx_space_t	*drop;		/* the reference this step ended, or NULL */
	bool		 withdraw;	/* at a DELETE_SPACE: its exit record was
					 * posted, so ask for its withdrawal */
};

/*
 * ERX_EINVAL, changing nothing, unless root is closed and its stop walk is
 * done (root is WALKED or DELETING); otherwise ERX_OK with *action
 * ERX_DELETE_SPACE for root, or ERX_DELETE_DONE when another walk had begun
 * its deletion, in which case the caller does nothing more for root: in
 * particular it queues no put.
 */
erx_status_t	erx_delete_walk_begin(erx_delete_walk_t *walk, erx_space_t *root,
		    erx_delete_walk_action_t *action) ERX_WARN_UNUSED_RESULT;
erx_delete_walk_action_t erx_delete_walk_step(erx_delete_walk_t *walk);

/*
 * A space's exit record, which its deletion takes with it. The post and
 * the deletion's begin each set one bit of one word by one fetch-or, so of
 * the two the second sees the first. A post that finds the deletion begun
 * drops the record; a deletion that finds the record posted says so in
 * walk->withdraw.
 *
 * A record waits in one place, at one thread's queue, which belongs to that
 * thread's home CPU, or on its gate's att_blocked list. Every placement is
 * made under the gate's lock, which orders it with the withdrawal: the post's
 * and each later move of a waiting record, when its receiver dies. A placement
 * asks erx_space_exit_waits there, drops the record when that says false, and
 * otherwise records the place. The withdrawal, under the same lock, reads the
 * place: it takes the record off att_blocked, or sends the thread's home CPU
 * a request, which removes the record if it is still there. Queueing requests
 * are sent under that lock too, so a withdrawal follows them. One refused
 * because the thread is dying needs nothing more, since its drain's placement
 * finds the deletion begun.
 *
 * erx_space_exit_post is the post, made once the space has stopped and every
 * child has posted, by the CPU that takes the space's active count to zero or
 * by a stopper that finds it there, at most once in effect:
 *
 *   ERX_SPACE_POST_QUEUE  place the record;
 *   ERX_SPACE_POST_DROP   the deletion began first: drop the record;
 *   ERX_SPACE_POST_NONE   another post came first: nothing to do.
 *
 * Whoever removes a record, or drops it, counts one in its fault gate's
 * exits_dropped, or, when the gate is gone, in the space's own count of
 * dropped records. QUEUE and DROP each count as posted for the parent's record.
 *
 * erx_space_exit_waits says whether a placement keeps the record, made under
 * the gate's lock: false once the deletion has begun.
 */
typedef enum erx_space_post {
	ERX_SPACE_POST_NONE = 0,
	ERX_SPACE_POST_QUEUE,
	ERX_SPACE_POST_DROP
} erx_space_post_t;

erx_space_post_t erx_space_exit_post(erx_space_t *space);
bool		erx_space_exit_waits(const erx_space_t *space);

#endif /* ERX_SPACE_H */
