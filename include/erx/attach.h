/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ATTACH_H
#define ERX_ATTACH_H

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/object.h"

/*
 * The insert functions (docs/design-kernel.md, "Objects and
 * capabilities"): whatever attaches to an object does so through an
 * attachment field of the object's record, a member whose name begins
 * with att_, and each such field has exactly one insert function, here.
 * Each insert reads the object's state under the lock that guards its
 * field and links nothing, returning ERX_ESTALE, once the state forbids
 * it, so nothing attaches to an object a destroy has closed (K26), and
 * the deletion core's teardown, which empties every attachment field,
 * finds everything that attached before the close.
 *
 * The attachment-fields check (test/host/attach_fields_test.rb) reads
 * every object record's att_ members and requires, field by field, an
 * insert here named erx_attach_<record>_<field> whose first call is
 * erx_object_state, and the field's walk in the deletion core's teardown,
 * so a field added without its insert or its teardown fails the build.
 *
 * Locks are the caller's, as everywhere in the cores: each function names
 * the lock its caller holds.
 */

/*
 * The insert of att_slots, the object's slot list: under the object's
 * capability lock, make slot the list's head and return the previous head
 * in *nextp, which the capability core links after slot (the links are
 * the slots' own fields, private to it). ERX_ESTALE, changing nothing,
 * unless the object is LIVE: no capability is made to a released or
 * closed object. Only the capability core's install and a pass's fill
 * call it, each after counting the slot on the object.
 */
erx_status_t	erx_attach_object_slots(erx_object_t *object, erx_cap_slot_t *slot,
		    erx_cap_slot_t **nextp) ERX_WARN_UNUSED_RESULT;

/*
 * The insert of att_charged, the list of charged objects of the object's
 * own budget: under that budget's lock, append object. ERX_ESTALE,
 * changing nothing, unless the object is LIVE, so a closed object never
 * rejoins the list, or when the budget is dead, which takes no new object
 * (K3). A creation calls it once it has charged the object's record, and
 * a carve's caller once it has made the child budget's header; on
 * ERX_ESTALE the caller tears down what it made and refunds it.
 */
erx_status_t	erx_attach_budget_charged(erx_object_t *object)
		    ERX_WARN_UNUSED_RESULT;

#endif /* ERX_ATTACH_H */
