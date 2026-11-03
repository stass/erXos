/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The admission state machine of include/erx/admit.h. The phases run in
 * the order they are declared, and each failure leaves for RELEASING if
 * the phase holds the plan's existence locks and for FINISHED if not.
 */

#include <stdint.h>

#include "erx/admit.h"

static erx_sys_admit_action_t erx_sys_admit_finish(erx_sys_admission_t *,
    erx_status_t);
static erx_sys_admit_action_t erx_sys_admit_find(erx_sys_admission_t *);
static erx_sys_admit_action_t erx_sys_admit_look(erx_sys_admission_t *);
static erx_sys_admit_action_t erx_sys_admit_lookup(erx_sys_admission_t *,
    erx_sys_admit_phase_t);
static erx_sys_admit_action_t erx_sys_admit_release(erx_sys_admission_t *,
    erx_status_t);
static erx_sys_admit_action_t erx_sys_admit_unlock(erx_sys_admission_t *);

erx_sys_admit_action_t
erx_sys_admit_first(erx_sys_admission_t *admission,
    const erx_sys_shape_t *shape)
{
	erx_status_t status;

	admission->cursor = 0;
	admission->status = ERX_OK;
	status = erx_sys_admit_plan(shape, &admission->plan);
	if (status != ERX_OK)
		return (erx_sys_admit_finish(admission, status));
	if (admission->plan.exists > 0)
		return (erx_sys_admit_find(admission));
	return (erx_sys_admit_look(admission));
}

erx_sys_admit_action_t
erx_sys_admit_next(erx_sys_admission_t *admission, erx_status_t result)
{
	switch (admission->phase) {
	case ERX_SYS_ADMIT_FINDING:
		if (result != ERX_OK)
			return (erx_sys_admit_finish(admission, result));
		admission->cursor++;
		return (erx_sys_admit_find(admission));
	case ERX_SYS_ADMIT_LOCKING:
		if (result != ERX_OK)
			return (erx_sys_admit_finish(admission, result));
		return (erx_sys_admit_look(admission));
	case ERX_SYS_ADMIT_LOOKING:
		if (result != ERX_OK)
			return (erx_sys_admit_release(admission, result));
		admission->cursor++;
		return (erx_sys_admit_look(admission));
	case ERX_SYS_ADMIT_RUNNING:
		return (erx_sys_admit_release(admission, result));
	case ERX_SYS_ADMIT_RELEASING:
		if (admission->cursor <= 1)
			return (erx_sys_admit_finish(admission, admission->status));
		admission->cursor--;
		return (erx_sys_admit_unlock(admission));
	case ERX_SYS_ADMIT_FINISHED:
		return (erx_sys_admit_finish(admission, admission->status));
	}
	return (erx_sys_admit_finish(admission, ERX_EINVAL));
}

/* The next existence-locked capability's lookup, or the lock step. */
static erx_sys_admit_action_t
erx_sys_admit_find(erx_sys_admission_t *admission)
{
	erx_sys_admit_action_t action = {0};

	if (admission->cursor < admission->plan.exists)
		return (erx_sys_admit_lookup(admission, ERX_SYS_ADMIT_FINDING));
	admission->phase = ERX_SYS_ADMIT_LOCKING;
	action.op = admission->plan.exists == 2 ? ERX_SYS_ADMIT_LOCK2 :
	    ERX_SYS_ADMIT_LOCK;
	return (action);
}

/* The next other capability's lookup, or RUN once there is none. */
static erx_sys_admit_action_t
erx_sys_admit_look(erx_sys_admission_t *admission)
{
	erx_sys_admit_action_t action = {0};

	if (admission->cursor < admission->plan.count)
		return (erx_sys_admit_lookup(admission, ERX_SYS_ADMIT_LOOKING));
	admission->phase = ERX_SYS_ADMIT_RUNNING;
	action.op = ERX_SYS_ADMIT_RUN;
	return (action);
}

static erx_sys_admit_action_t
erx_sys_admit_lookup(erx_sys_admission_t *admission,
    erx_sys_admit_phase_t phase)
{
	const erx_sys_admit_plan_t *plan = &admission->plan;
	erx_sys_admit_action_t action = {0};
	uint32_t position = admission->cursor;

	admission->phase = phase;
	action.op = ERX_SYS_ADMIT_LOOKUP;
	action.position = position;
	action.cap = plan->caps[position];
	action.type = plan->types[position];
	action.rights = plan->rights[position];
	return (action);
}

/* Leave a phase that holds the plan's existence locks, if it has any. */
static erx_sys_admit_action_t
erx_sys_admit_release(erx_sys_admission_t *admission, erx_status_t status)
{
	if (admission->plan.exists == 0)
		return (erx_sys_admit_finish(admission, status));
	admission->phase = ERX_SYS_ADMIT_RELEASING;
	admission->status = status;
	admission->cursor = admission->plan.exists;
	return (erx_sys_admit_unlock(admission));
}

static erx_sys_admit_action_t
erx_sys_admit_unlock(erx_sys_admission_t *admission)
{
	erx_sys_admit_action_t action = {0};

	action.op = ERX_SYS_ADMIT_UNLOCK;
	action.position = admission->cursor - 1;
	return (action);
}

static erx_sys_admit_action_t
erx_sys_admit_finish(erx_sys_admission_t *admission, erx_status_t status)
{
	erx_sys_admit_action_t action = {0};

	admission->phase = ERX_SYS_ADMIT_FINISHED;
	admission->status = status;
	action.op = ERX_SYS_ADMIT_DONE;
	action.status = status;
	return (action);
}
