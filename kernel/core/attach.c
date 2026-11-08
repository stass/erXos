/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The insert functions: see erx/attach.h for the contract. Each one
 * checks the object's state first and then writes its field through the
 * owning core's setter; nothing else writes an attachment field forward.
 */

#include <stddef.h>

#include "erx/abi.h"
#include "erx/attach.h"
#include "erx/budget.h"
#include "erx/object.h"

erx_status_t
erx_attach_object_slots(erx_object_t *object, erx_cap_slot_t *slot,
    erx_cap_slot_t **nextp)
{
	if (erx_object_state(object) != ERX_OBJ_LIVE)
		return (ERX_ESTALE);
	*nextp = erx_object_slots(object);
	erx_object_set_slots(object, slot);
	return (ERX_OK);
}

erx_status_t
erx_attach_budget_charged(erx_object_t *object)
{
	if (erx_object_state(object) != ERX_OBJ_LIVE ||
	    erx_budget_dead(erx_object_budget(object)))
		return (ERX_ESTALE);
	erx_object_charged_append(erx_budget_charged(erx_object_budget(object)),
	    object);
	return (ERX_OK);
}
