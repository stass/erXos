/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ADMIT_H
#define ERX_ADMIT_H

#include <stdint.h>

#include "erx/abi.h"
#include "abi_calls.h"

/*
 * The admission of one kernel call's capabilities (docs/design-kernel.md,
 * "System-call dispatch"), as a pure state machine. erx_sys_decode_shape
 * has already decoded every argument, and the call's generated plan lists
 * its capability arguments in the order the dispatch takes them: those
 * whose existence lock the call holds, then the rest. The machine returns
 * one action at a time and the dispatch performs it and reports its
 * status, so the order of lookups and locks, and their release on every
 * path, is decided here and nowhere else:
 *
 *   1. look up each existence-locked capability, with no preemption point
 *      between the lookups, then take their locks in one step, LOCK2 when
 *      there are two; taking an existence lock is a preemption point, which
 *      ends every uncounted reference a lookup returned (K1);
 *   2. look up every other capability, so the references the handler
 *      receives are fresh;
 *   3. run the handler;
 *   4. release the existence locks, the highest position first, and finish
 *      with the status of the handler. The order of releases carries no
 *      meaning: the locks themselves are taken in address order.
 *
 * A failure finishes the call with the failing status. A failed lookup of
 * an existence-locked capability, or a failed lock, holds nothing, since
 * the lock functions drop their references on failure; a failed lookup
 * after the locks releases them first. So whatever fails, the call ends
 * holding no lock it took. A shape with no plan, an unknown call, finishes
 * at once with ERX_ENOTSUP, and nothing runs.
 *
 * What the dispatch still does around these actions: the window checks and
 * the installation report through LOOKUP's and RUN's statuses, as
 * erx_sys_admit_next says; the lookup itself resolves ERX_CAP_SELF and
 * ERX_CAP_SELF_THREAD; a retry starts a new admission of the same shape
 * once the first has finished; a wait follows DONE, so it holds nothing.
 *
 * Every enum starts at 1, so a zeroed value is outside its enum.
 */

typedef enum erx_sys_admit_op {
	ERX_SYS_ADMIT_LOOKUP = 1,	/* look up cap for type and rights */
	ERX_SYS_ADMIT_LOCK,		/* take position 0's existence lock */
	ERX_SYS_ADMIT_LOCK2,		/* take positions 0's and 1's together */
	ERX_SYS_ADMIT_RUN,		/* every capability is admitted */
	ERX_SYS_ADMIT_UNLOCK,		/* release position's existence lock */
	ERX_SYS_ADMIT_DONE		/* return status; nothing is held */
} erx_sys_admit_op_t;

/* What the dispatch does next; only the fields its op names are set. */
typedef struct erx_sys_admit_action {
	erx_sys_admit_op_t	 op;
	uint32_t		 position;	/* LOOKUP, UNLOCK: in the plan */
	erx_cap_t		 cap;		/* LOOKUP */
	uint32_t		 type;		/* LOOKUP: ERX_K_* */
	uint32_t		 rights;	/* LOOKUP: the rights required */
	erx_status_t		 status;	/* DONE */
} erx_sys_admit_action_t;

/*
 * Where an admission stands, which fixes what it holds: only LOOKING and
 * RUNNING hold the plan's existence locks, and RELEASING the first cursor
 * of them; the others hold nothing. So no state can record a lock apart
 * from the step that took it.
 */
typedef enum erx_sys_admit_phase {
	ERX_SYS_ADMIT_FINDING = 1,	/* cursor: a locked capability's lookup */
	ERX_SYS_ADMIT_LOCKING,		/* the one lock step */
	ERX_SYS_ADMIT_LOOKING,		/* cursor: another capability's lookup */
	ERX_SYS_ADMIT_RUNNING,		/* the handler runs */
	ERX_SYS_ADMIT_RELEASING,	/* cursor - 1 is being released */
	ERX_SYS_ADMIT_FINISHED		/* status is the call's */
} erx_sys_admit_phase_t;

/* One admission's state, owned by the dispatch for the call's duration. */
typedef struct erx_sys_admission {
	erx_sys_admit_plan_t	 plan;
	erx_sys_admit_phase_t	 phase;
	uint32_t		 cursor;
	erx_status_t		 status;	/* RELEASING, FINISHED */
} erx_sys_admission_t;

/*
 * Start an admission of a decoded shape and return its first action. The
 * plan comes from the shape here, so no dispatch can run a handler on a
 * plan it did not check or on another call's.
 */
erx_sys_admit_action_t	erx_sys_admit_first(erx_sys_admission_t *admission,
			    const erx_sys_shape_t *shape);

/*
 * Report the status of the action last returned, and return the next.
 * LOOKUP's status is the lookup's, and for a window's capability also that
 * of the checks of its offset and length against the object. LOCK's and
 * LOCK2's is the lock function's. RUN's is the handler's or, for a call
 * that creates an object, the installation's, which happens before the
 * locks go; that status is what the call returns. UNLOCK's is ignored,
 * since a release cannot fail. Once finished, every report returns DONE
 * with the same status. A phase outside its enum, a kernel bug, finishes
 * with ERX_EINVAL without trusting the record any further.
 */
erx_sys_admit_action_t	erx_sys_admit_next(erx_sys_admission_t *admission,
			    erx_status_t result);

#endif /* ERX_ADMIT_H */
