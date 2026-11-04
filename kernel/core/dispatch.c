/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel call's one funnel: decode the registers, follow the admission
 * state machine of erx/admit.h, run the handler, and turn its status into the
 * result words (docs/design-kernel.md, "System-call dispatch"). The caller
 * supplies the snapshot and writes the words back, so this file reads no trap
 * frame and is the same on every kernel.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/admit.h"
#include "erx/core/dispatch.h"
#include "abi_calls.h"
#include "dispatch_impl.h"

static erx_status_t erx_dispatch_admit(erx_sys_context_t *,
    const erx_sys_shape_t *);
static erx_status_t erx_dispatch_perform(erx_sys_context_t *,
    const erx_sys_shape_t *, erx_sys_admit_op_t);

_Static_assert(ERX_TRAP_RESULT_COUNT >= 1, "the status needs a register");

/*
 * One action of an admission. No capability table is reachable from here, so
 * a call that names a capability fails its lookup with ERX_ENOTSUP and never
 * reaches its handler; only a call with no capability argument runs. The
 * admission's own failure path still decides what happens next.
 */
static erx_status_t
erx_dispatch_perform(erx_sys_context_t *context, const erx_sys_shape_t *shape,
    erx_sys_admit_op_t op)
{
	switch (op) {
	case ERX_SYS_ADMIT_LOOKUP:
	case ERX_SYS_ADMIT_LOCK:
		return (ERX_ENOTSUP);
	case ERX_SYS_ADMIT_RUN:
		return (erx_sys_run(context, shape));
	case ERX_SYS_ADMIT_UNLOCK:
	case ERX_SYS_ADMIT_DONE:
		return (ERX_OK);
	}
	return (ERX_EINVAL);
}

/* The admission of a decoded shape, from its first action to its status. */
static erx_status_t
erx_dispatch_admit(erx_sys_context_t *context, const erx_sys_shape_t *shape)
{
	erx_sys_admission_t admission;
	erx_sys_admit_action_t action;

	action = erx_sys_admit_first(&admission, shape);
	while (action.op != ERX_SYS_ADMIT_DONE) {
		action = erx_sys_admit_next(&admission,
		    erx_dispatch_perform(context, shape, action.op));
	}
	return (action.status);
}

void
erx_dispatch(const erx_sys_caller_t *caller, uint64_t number,
    const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_sys_context_t context = { .caller = caller };
	erx_sys_shape_t shape;
	erx_status_t status;
	size_t index;

	status = erx_sys_decode_shape(number, args,
	    (const erx_utcb_t *)caller->utcb, caller->executor, &shape);
	if (status == ERX_OK)
		status = erx_dispatch_admit(&context, &shape);
	results[0] = (uint64_t)(uint32_t)status;
	for (index = 1; index < ERX_TRAP_RESULT_COUNT; index++)
		results[index] = 0;
}
