/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The deletion core and the release rule: see erx/delete.h for the
 * contract.
 *
 * The teardown walks every attachment field the object's record declares,
 * one entry per part. The object header's one field is att_slots, the
 * slot list; the walk takes its head each time, since erx_cap_slot_clear
 * unlinks the slot it clears, and nothing is linked after the close,
 * because every insert refuses a DELETED object. So the walk ends after
 * at most as many parts as the list held slots at the close, and each
 * part is bounded. A budget's att_charged is walked by the budget-death
 * walk below, which takes each head off the list as it destroys it. The
 * attachment-fields check (test/host/attach_fields_test.rb) requires a
 * walk here for every att_ field, by its reader's name.
 */

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "erx/budget.h"
#include "erx/cap.h"
#include "erx/delete.h"
#include "erx/object.h"

/*
 * The types that live on after their release while attached (K21): a
 * memory object while a mapping of it remains, a group while it has
 * member threads or child groups. Every other type is destroyed at its
 * release.
 */
static const bool delete_lives_on[] = {
	[ERX_K_MEMORY] = true,
	[ERX_K_GROUP] = true,
};

#define DELETE_NTYPES	(sizeof(delete_lives_on) / sizeof(delete_lives_on[0]))

void
erx_delete_begin(erx_delete_t *destroy, erx_object_t *object)
{
	destroy->object = object;
	destroy->stage = ERX_DELETE_BEGUN;
}

/*
 * The teardown's next part: the head of the slot list, or the put once
 * every attachment field is empty. It decides only; the step writes the
 * stage.
 */
static erx_delete_part_t
delete_teardown_part(const erx_object_t *object)
{
	erx_delete_part_t part = { .action = ERX_DELETE_PUT, .table = NULL,
	    .cap = { 0 } };
	const erx_cap_slot_t *slot = erx_object_slots(object);

	if (slot != NULL) {
		part.action = ERX_DELETE_CLEAR;
		erx_cap_slot_name(slot, &part.table, &part.cap);
	}
	return (part);
}

/*
 * The close is made here, not in a helper, so that the close chokepoint
 * sees erx_delete_step itself as erx_object_close's caller.
 */
erx_delete_part_t
erx_delete_step(erx_delete_t *destroy)
{
	erx_delete_part_t part = { .action = ERX_DELETE_STOP, .table = NULL,
	    .cap = { 0 } };

	switch (destroy->stage) {
	case ERX_DELETE_BEGUN:
		if (!erx_object_close(destroy->object)) {
			destroy->stage = ERX_DELETE_STOPPED;
			return (part);
		}
		destroy->stage = ERX_DELETE_CLOSED;
		part.action = ERX_DELETE_DRAIN;
		return (part);
	case ERX_DELETE_CLOSED:
	case ERX_DELETE_TEARING:
		part = delete_teardown_part(destroy->object);
		destroy->stage = part.action == ERX_DELETE_PUT ?
		    ERX_DELETE_OVER : ERX_DELETE_TEARING;
		return (part);
	default:
		__builtin_trap();
	}
}

erx_release_action_t
erx_release_rule(const erx_object_t *object, bool attached)
{
	erx_ktype_t type = erx_object_type(object);

	if (erx_object_state(object) == ERX_OBJ_DELETED)
		return (ERX_RELEASE_NONE);
	if ((size_t)type < DELETE_NTYPES && delete_lives_on[type] && attached)
		return (ERX_RELEASE_LIVES_ON);
	return (ERX_RELEASE_DESTROY);
}

void
erx_delete_uncharge(erx_object_t *object)
{
	erx_budget_t *budget = erx_object_budget(object);

	erx_effect_budget_lock(budget);
	(void)erx_object_charged_unlink(erx_budget_charged(budget), object);
	erx_effect_budget_unlock(budget);
}

void
erx_delete_budget_walk_begin(erx_delete_budget_walk_t *walk, erx_budget_t *top)
{
	*walk = (erx_delete_budget_walk_t){ .top = top, .cursor = top };
}

/*
 * What follows the destroy of a head the walk took: a child budget is
 * closed and walked next; anything else gives back the walk's reference.
 */
static erx_delete_budget_walk_action_t
delete_walk_after(erx_delete_budget_walk_t *walk, erx_budget_effects_t *effects)
{
	erx_object_t *object = walk->destroy.object;
	erx_budget_t *child;

	walk->destroy.object = NULL;
	if (walk->destroy.stage != ERX_DELETE_OVER &&
	    walk->destroy.stage != ERX_DELETE_STOPPED)
		__builtin_trap();
	/*
	 * A child budget is closed and walked whoever won its object's close:
	 * a racing destroy that won it may not run again before this destroy
	 * returns, and the tree must be dead by then. A close that finds the
	 * child dead already (ERX_ESTALE) is that destroy's, and both walk the
	 * list, each take unlinking what it takes.
	 */
	if (erx_object_type(object) == ERX_K_BUDGET) {
		child = erx_object_body(object);
		if (erx_budget_parent(child) != walk->cursor)
			__builtin_trap();
		switch (erx_budget_close(child, effects)) {
		case 0:
		case ERX_ESTALE:
			break;
		default:
			__builtin_trap();
		}
		walk->cursor = child;
		return (ERX_DELETE_BUDGET_WALK_CLOSED);
	}
	walk->put = object;
	return (ERX_DELETE_BUDGET_WALK_PUT);
}

erx_delete_budget_walk_action_t
erx_delete_budget_walk_next(erx_delete_budget_walk_t *walk,
    erx_budget_effects_t *effects)
{
	erx_charged_list_t *list;
	erx_object_t *head;

	__builtin_memset(effects, 0, sizeof(*effects));
	walk->put = NULL;
	if (walk->destroy.object != NULL)
		return (delete_walk_after(walk, effects));
	/*
	 * The take, under the cursor's lock: the head leaves the list and
	 * gains the walk's counted reference. While an object is on the list
	 * its own reference is held, since its destroy unlinks it at its drain,
	 * before its put, so the reference never rises from zero.
	 */
	erx_effect_budget_lock(walk->cursor);
	list = erx_budget_charged(walk->cursor);
	head = erx_object_charged_head(list);
	if (head != NULL) {
		(void)erx_object_charged_unlink(list, head);
		(void)erx_object_ref(erx_uref_make(head));
	}
	erx_effect_budget_unlock(walk->cursor);
	if (head != NULL) {
		erx_delete_begin(&walk->destroy, head);
		return (ERX_DELETE_BUDGET_WALK_DESTROY);
	}
	if (walk->cursor == walk->top)
		return (ERX_DELETE_BUDGET_WALK_DONE);
	walk->put = erx_object_of(walk->cursor);
	walk->cursor = erx_budget_parent(walk->cursor);
	return (ERX_DELETE_BUDGET_WALK_PUT);
}
