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
 * part is bounded. The attachment-fields check (test/host/attach_fields_test.rb)
 * requires a walk here for every att_ field, by its reader's name.
 */

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
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
			destroy->stage = ERX_DELETE_OVER;
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
