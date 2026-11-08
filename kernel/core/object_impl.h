/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_OBJECT_IMPL_H
#define ERX_OBJECT_IMPL_H

/*
 * The object store's records. Only kernel/core/object.c includes this file
 * (and the core's host tests), which the object-records-private chokepoint
 * enforces, so every write of a header's field is in object.c.
 *
 * The header holds what the object store owns. The capability lock and
 * the existence lock, the grace period's queue item and the link on the
 * budget's list of charged objects join it with the cores that use them.
 */

#include <stdatomic.h>

#include "erx/object.h"

struct erx_object {
	erx_ktype_t	 type;		/* fixed for its life */
	_Atomic uint32_t state;		/* an erx_obj_state_t; only advances */
	_Atomic uint32_t refs;		/* its own until its put, and the
					 * threads' that keep it across a
					 * preemption point */
	uint32_t	 ncaps;		/* slots naming it; under its
					 * capability lock */
	erx_cap_slot_t	*att_slots;	/* the slots that name it, in no order;
					 * under its capability lock */
	struct erx_budget *budget;	/* pays for this object; fixed */
	uint64_t	 oid;		/* unique for the boot; correlation,
					 * never authority */
	char		 name[16];	/* ASCII; may be empty */
};

/*
 * The counter value that is never issued: once the counter reaches it,
 * creation fails, so the counter never wraps.
 */
#define ERX_OID_COUNTER_END	UINT64_MAX

struct erx_object_store {
	erx_oid_key_t	 key;		/* fixed by erx_object_store_init */
	_Atomic uint64_t next;		/* the creation counter's next value */
};

#endif /* ERX_OBJECT_IMPL_H */
