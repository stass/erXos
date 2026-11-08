/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DELETE_H
#define ERX_DELETE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/cdefs.h"
#include "erx/object.h"

/*
 * The deletion core and the release rule (docs/design-kernel.md, "Closing
 * and deleting"): Fiasco's two-phase destruction as a pure state machine
 * that returns the next bounded part, which its caller performs.
 *
 * A destroy, whoever starts it (a deletion with DESTROY, the destruction
 * of the object's budget, or the release), runs
 *
 *   close    erx_delete_step writes DELETED under the capability lock; from
 *            then on the one lookup, every insert of kernel/core/attach.c
 *            and every taker of the existence lock refuse the object. The
 *            close's result decides which destroy goes on: the first goes
 *            on, and every other stops at once and destroys nothing (K26).
 *   drain    the caller, holding no capability lock, first takes the
 *            object off its budget's att_charged (erx_delete_uncharge),
 *            then waits until the existence lock is free, helping its
 *            holder, so nothing that began before the close still
 *            changes the object.
 *   teardown one part per step: each clears one slot of the object's list
 *            through erx_cap_slot_clear, with a preemption point after it,
 *            until every attachment field the record declares is empty.
 *   put      the caller queues the put of the object's own reference
 *            behind the grace period that begins now (erx_grace_retire).
 *
 * The record of a destroy (erx_delete_t) is its caller's, and its stage
 * only advances. Two rules keep the object behind it valid by
 * construction:
 *
 *   erx_delete_begin and the first step run in the same hold of the
 *   object's capability lock as the decision to destroy (the release's
 *   slot clear, or the deletion's lookup of the object), so a record that
 *   lost the close is never kept, and only the winner's record, which owns
 *   the object's own reference until its put, outlives that hold;
 *   each CLEAR part is performed in the same hold of the capability lock
 *   as the step that named it, since only the slot's place on the list,
 *   which that lock keeps, keeps the slot's table alive.
 */

/* The part a step hands its caller. */
typedef enum erx_delete_action {
	ERX_DELETE_STOP = 1,	/* another destroy closed the object first:
				 * this one destroys nothing */
	ERX_DELETE_DRAIN,	/* with no capability lock held, take the
				 * object off its budget's list with
				 * erx_delete_uncharge, then wait until the
				 * existence lock is free, helping its
				 * holder; then step again */
	ERX_DELETE_CLEAR,	/* clear the slot named by table and cap with
				 * erx_cap_slot_clear, in the step's hold of
				 * the object's capability lock, then under the
				 * table's; pass a preemption point; then step
				 * again */
	ERX_DELETE_PUT		/* the teardown is complete: queue the put
				 * behind a grace period; the destroy is over */
} erx_delete_action_t;

typedef struct erx_delete_part {
	erx_delete_action_t	 action;
	erx_cap_table_t		*table;	/* ERX_DELETE_CLEAR only */
	erx_cap_t		 cap;	/* ERX_DELETE_CLEAR only */
} erx_delete_part_t;

/* A destroy's stage; the numeric order is the order of its steps. */
typedef enum erx_delete_stage {
	ERX_DELETE_BEGUN = 1,	/* nothing done yet */
	ERX_DELETE_CLOSED,	/* closed by this destroy; the drain is due */
	ERX_DELETE_TEARING,	/* drained; its teardown's parts are due */
	ERX_DELETE_OVER,	/* its put handed out */
	ERX_DELETE_STOPPED	/* another destroy closed the object first;
				 * reached from BEGUN alone */
} erx_delete_stage_t;

typedef struct erx_delete {
	erx_object_t	*object;
	uint32_t	 stage;		/* an erx_delete_stage_t */
} erx_delete_t;

/* Start a destroy of object; nothing is changed until the first step. */
void		erx_delete_begin(erx_delete_t *destroy, erx_object_t *object);

/*
 * The destroy's next part, under the object's capability lock: the close
 * at the first step, then the drain, then one slot per step, then the
 * put. A step after the destroy is over is a kernel bug and traps.
 */
erx_delete_part_t erx_delete_step(erx_delete_t *destroy);

/*
 * The first action of a destroy's drain: takes the object off its
 * budget's att_charged if it is still on it, under the budget's lock,
 * which it takes and drops through erx_effect_budget_lock. The caller
 * holds no capability lock, so the two locks never nest; the unlink is
 * idempotent, so whichever of the drain and the budget-death walk comes
 * first makes it and the other changes nothing.
 */
void		erx_delete_uncharge(erx_object_t *object);

/*
 * The budget-death walk: the teardown of a closed budget's att_charged
 * and, through each child budget on it, of the tree below, iterative and
 * with no stack, so its state is the record below whatever the depth.
 * Each call of erx_delete_budget_walk_next names the next part:
 *
 *   DESTROY  the walk took the cursor's head off its list, under the
 *            cursor's lock, with a counted reference the walk holds:
 *            run walk->destroy, begun on it, through erx_delete_step to
 *            its end, as a deletion does, then call next again;
 *   CLOSED   the destroy just run was of a child budget's object: the
 *            walk closed the child (erx_budget_close, whose effects are
 *            in *effects), unless the destroy that won the object's close
 *            had closed it already, and walks its list next, keeping its
 *            reference, so the tree is dead before the walk is done;
 *   PUT      drop the walk's counted reference to walk->put with
 *            erx_object_put, and on the last start the record's free:
 *            after the destroy of an object other than a budget, or when
 *            a child budget's list is empty and the walk climbs back to
 *            its parent;
 *   DONE     the top budget's list is empty.
 *
 * A head that another destroy closed first stops at its close and its
 * teardown is that destroy's; the walk waits on no one, and a closed
 * object is already refused by every lookup. The take never races the object's put, because a
 * destroy takes its object off the list at its drain, before its put.
 */
typedef enum erx_delete_budget_walk_action {
	ERX_DELETE_BUDGET_WALK_DESTROY = 1,
	ERX_DELETE_BUDGET_WALK_CLOSED,
	ERX_DELETE_BUDGET_WALK_PUT,
	ERX_DELETE_BUDGET_WALK_DONE
} erx_delete_budget_walk_action_t;

typedef struct erx_delete_budget_walk {
	erx_budget_t	*top;		/* the destroyed budget, closed */
	erx_budget_t	*cursor;	/* the budget whose list is walked */
	erx_object_t	*put;		/* PUT: the reference to drop */
	erx_delete_t	 destroy;	/* DESTROY: the head's destroy; its
					 * object is NULL between heads */
} erx_delete_budget_walk_t;

/*
 * Starts the walk of top, which its destroy has closed with
 * erx_budget_close; the caller keeps a counted reference to top's object
 * until DONE.
 */
void		erx_delete_budget_walk_begin(erx_delete_budget_walk_t *walk,
		    erx_budget_t *top);

/*
 * The walk's next part, holding no lock. A call while walk->destroy has
 * not reached its end, or a child budget whose close is refused, is a
 * kernel bug and traps.
 */
erx_delete_budget_walk_action_t erx_delete_budget_walk_next(
		    erx_delete_budget_walk_t *walk, erx_budget_effects_t *effects);

/* What the release of an object asks for. */
typedef enum erx_release_action {
	ERX_RELEASE_NONE = 1,	/* closed already: its destroy's teardown is
				 * under way, and it stays DELETED */
	ERX_RELEASE_DESTROY,	/* destroy it now, as a deletion does */
	ERX_RELEASE_LIVES_ON	/* a type that lives on while attached:
				 * destroyed when its last mapping, child or
				 * member goes */
} erx_release_action_t;

/*
 * The release rule (K21): what the slot clear that reported an object's
 * release must do, under the object's capability lock. attached says
 * whether the object still has a mapping, a child or a member, which only
 * the types that live on while attached read: every type but memory and
 * groups is destroyed at its release. The rule is data, a table by type.
 */
erx_release_action_t erx_release_rule(const erx_object_t *object,
		    bool attached);

#endif /* ERX_DELETE_H */
