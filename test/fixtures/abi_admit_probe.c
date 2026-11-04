/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the admission plans generated from abi_call_marshal.txt through
 * kernel/core/admit.c with a model of the dispatch's effects that fails
 * one chosen action. Every expected trace comes from this file: the pinned
 * traces are written out by hand from the order docs/design-kernel.md
 * ("System-call dispatch") gives, and expected_trace is a separate statement
 * of that order, explored over every shape of plan and every failure point
 * (docs/style.md, "Functional core"), so neither the generator nor the
 * machine supplies its own answers. The model refuses a lock taken twice,
 * a release of a lock not held and a finish with the lock still held.
 *
 * Trace tokens: lN lookup of position N, k lock of position 0, r run,
 * u release of position 0, dS done with status S.
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "erx/admit.h"

#define CHECK(condition)						\
	do {								\
		if (!(condition)) {					\
			printf("failed at line %d: %s\n", __LINE__,	\
			    #condition);				\
			return (1);					\
		}							\
	} while (0)

#define TRACE_MAX	128
#define ACTIONS_MAX	32
#define NO_FAILURE	(-1)
#define FAILURE		(-77)

/* The model of the effects: whether position 0 is locked, and the trace. */
typedef struct model {
	const erx_sys_admit_plan_t *plan;
	int		 fail_at;	/* the action whose effect fails */
	erx_status_t	 failure;	/* its status */
	bool		 locked;
	bool		 broken;	/* a lock or release out of turn */
	char		 trace[TRACE_MAX];
} model_t;

static void
note(char *trace, const char *format, int value)
{
	size_t used = strlen(trace);

	if (used != 0)
		trace[used++] = ' ';
	(void)snprintf(trace + used, TRACE_MAX - used, format, value);
}

/* Perform one action and return the status the dispatch reports. */
static erx_status_t
perform(model_t *model, const erx_sys_admit_action_t *action, int number)
{
	const erx_sys_admit_plan_t *plan = model->plan;
	bool fails = number == model->fail_at;

	switch (action->op) {
	case ERX_SYS_ADMIT_LOOKUP:
		note(model->trace, "l%d", (int)action->position);
		if (action->position >= plan->count ||
		    action->cap.raw != plan->caps[action->position].raw ||
		    action->type != plan->types[action->position] ||
		    action->rights != plan->rights[action->position])
			model->broken = true;
		break;
	case ERX_SYS_ADMIT_LOCK:
		note(model->trace, "k", 0);
		if (model->locked)
			model->broken = true;
		model->locked = !fails;
		break;
	case ERX_SYS_ADMIT_RUN:
		note(model->trace, "r", 0);
		break;
	case ERX_SYS_ADMIT_UNLOCK:
		note(model->trace, "u", 0);
		if (!model->locked)
			model->broken = true;
		model->locked = false;
		/* A release cannot fail: the machine ignores what comes back. */
		return (ERX_EBUSY);
	case ERX_SYS_ADMIT_DONE:
	default:
		model->broken = true;
		return (ERX_OK);
	}
	return (fails ? model->failure : ERX_OK);
}

/*
 * Admit the shape, failing action fail_at with failure, and return whether
 * the trace is expected, nothing is held at the end and a finished
 * admission stays finished with the same status.
 */
static bool
admits(const erx_sys_shape_t *shape, int fail_at, erx_status_t failure,
    const char *expected)
{
	erx_sys_admission_t admission;
	erx_sys_admit_action_t action;
	erx_sys_admit_plan_t plan;
	model_t model = { .plan = &plan, .fail_at = fail_at, .failure = failure };
	erx_status_t status;

	if (erx_sys_admit_plan(shape, &plan) != ERX_OK)
		plan = (erx_sys_admit_plan_t){0};
	action = erx_sys_admit_first(&admission, shape);
	for (int number = 0; action.op != ERX_SYS_ADMIT_DONE; number++) {
		if (number == ACTIONS_MAX)
			return (false);
		action = erx_sys_admit_next(&admission,
		    perform(&model, &action, number));
	}
	status = action.status;
	note(model.trace, "d%d", (int)status);
	if (model.locked)
		return (false);
	if (strcmp(model.trace, expected) != 0) {
		printf("trace \"%s\", expected \"%s\"\n", model.trace, expected);
		return (false);
	}
	action = erx_sys_admit_next(&admission, ERX_EBUSY);
	return (!model.broken && action.op == ERX_SYS_ADMIT_DONE &&
	    action.status == status);
}

static int
decode(uint64_t number, const uint64_t registers[6], erx_sys_shape_t *shape)
{
	erx_utcb_t utcb = {0};

	/* The one capability a fixture call places in the UTCB. */
	CHECK(erx_utcb_mr_store(&utcb, 0, UINT64_C(0x77)));
	CHECK(erx_sys_decode_shape(number, registers, &utcb, false, shape) == ERX_OK);
	return (0);
}

/*
 * The order of docs/design-kernel.md, stated over a plan's two counts: the
 * locked lookup, the lock, the other lookups, the run, the release, the
 * end. An action at or past fail_at does not happen, except for the
 * release and the end that the failure itself calls for.
 */
static void
expected_trace(uint32_t count, uint32_t exists, int fail_at, char *trace)
{
	int number = 0;
	int status = 0;
	bool held = false;
	bool failed = false;

	trace[0] = '\0';
	if (exists > 0) {
		note(trace, "l%d", 0);
		failed = number++ == fail_at;
	}
	if (exists > 0 && !failed) {
		note(trace, "k", 0);
		failed = number++ == fail_at;
		held = !failed;
	}
	for (uint32_t position = exists; position < count && !failed; position++) {
		note(trace, "l%d", (int)position);
		failed = number++ == fail_at;
	}
	if (!failed) {
		note(trace, "r", 0);
		failed = number++ == fail_at;
	}
	if (failed)
		status = FAILURE;
	if (held)
		note(trace, "u", 0);
	note(trace, "d%d", status);
}

/*
 * Every shape of plan the bound allows, at every failure point: no action
 * sequence of the machine goes untried for any plan a call can declare.
 */
static int
check_every_shape(void)
{
	static const struct {
		uint64_t	number;
		uint32_t	count;
		uint32_t	exists;
	} shapes[] = {
		{ ERX_CALL_PARK, 0, 0 },
		{ ERX_CALL_SPACE_STOP, 1, 0 },
		{ ERX_CALL_ADMIT_1_1, 1, 1 },
		{ ERX_CALL_ADMIT_2_0, 2, 0 },
		{ ERX_CALL_SPACE_PAUSE, 2, 1 },
		{ ERX_CALL_ADMIT_3_0, 3, 0 },
		{ ERX_CALL_ADMIT_3_1, 3, 1 },
		{ ERX_CALL_SPACE_COPY, 2, 0 },
	};
	uint64_t registers[6] = { 0x11, 0x22, 0x33, 0x44 };
	char expected[TRACE_MAX];

	CHECK(ERX_SYS_ADMIT_CAPS_MAX == 3);
	for (size_t index = 0; index < sizeof(shapes) / sizeof(shapes[0]); index++) {
		erx_sys_shape_t shape;
		erx_sys_admit_plan_t plan;
		int actions = (int)(shapes[index].count +
		    (shapes[index].exists > 0 ? 1 : 0)) + 1;

		CHECK(decode(shapes[index].number, registers, &shape) == 0);
		CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_OK);
		CHECK(plan.count == shapes[index].count);
		CHECK(plan.exists == shapes[index].exists);
		for (int fail_at = NO_FAILURE; fail_at < actions; fail_at++) {
			expected_trace(shapes[index].count, shapes[index].exists,
			    fail_at, expected);
			CHECK(admits(&shape, fail_at, FAILURE, expected));
		}
	}
	return (0);
}

/*
 * erx_space_copy(from (MAP, STOP), to (MAP, CAPS), ticket), as
 * docs/design-kernel.md ("Copying a space") gives it, marks neither space
 * exists: the dispatch looks both up in declaration order and holds no lock,
 * and the handler takes both spaces' locks itself with
 * erx_object_lock_existence2, as its first act. So the machine has no lock
 * action for it, and a failure at either lookup or in the handler releases
 * nothing. Rights by bit: stop is bit 0, map bit 2, caps bit 3.
 */
static int
check_space_copy(void)
{
	uint64_t registers[6] = { 0x21, 0x32, 7 };
	erx_sys_shape_t shape;
	erx_sys_admit_plan_t plan;

	CHECK(decode(ERX_CALL_SPACE_COPY, registers, &shape) == 0);
	CHECK(shape.arguments.space_copy.from.raw == 0x21);
	CHECK(shape.arguments.space_copy.to.raw == 0x32);
	CHECK(shape.arguments.space_copy.ticket == 7);
	CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_OK);
	CHECK(plan.count == 2 && plan.exists == 0);
	CHECK(plan.caps[0].raw == 0x21 && plan.types[0] == 1 && plan.rights[0] == 5);
	CHECK(plan.caps[1].raw == 0x32 && plan.types[1] == 1 && plan.rights[1] == 12);
	CHECK(ERX_SYS_POSITION_SPACE_COPY_FROM == 0 && ERX_SYS_POSITION_SPACE_COPY_TO == 1);

	CHECK(admits(&shape, NO_FAILURE, ERX_OK, "l0 l1 r d0"));
	CHECK(admits(&shape, 0, ERX_ESTALE, "l0 d-2"));
	CHECK(admits(&shape, 1, ERX_ERIGHTS, "l0 l1 d-4"));

	/*
	 * The handler's status is the call's, whichever it is: here
	 * erx_object_lock_existence2's refusal of two values naming one
	 * object. The refusal itself is the object store's to test.
	 */
	registers[1] = registers[0];
	CHECK(decode(ERX_CALL_SPACE_COPY, registers, &shape) == 0);
	CHECK(admits(&shape, 2, ERX_EINVAL, "l0 l1 r d-1"));
	return (0);
}

/* One lock: taken after its own lookup, before the others, released last. */
static int
check_one_lock(void)
{
	uint64_t registers[6] = { 0x10, 0x21 };
	erx_sys_shape_t shape;

	CHECK(decode(ERX_CALL_SPACE_PAUSE, registers, &shape) == 0);
	CHECK(ERX_SYS_POSITION_SPACE_PAUSE_SPACE == 0 && ERX_SYS_POSITION_SPACE_PAUSE_GATE == 1);
	CHECK(admits(&shape, NO_FAILURE, ERX_OK, "l0 k l1 r u d0"));
	CHECK(admits(&shape, 0, ERX_ESTALE, "l0 d-2"));
	CHECK(admits(&shape, 1, ERX_ESTALE, "l0 k d-2"));
	CHECK(admits(&shape, 2, ERX_ERIGHTS, "l0 k l1 u d-4"));
	CHECK(admits(&shape, 3, ERX_EBUSY, "l0 k l1 r u d-8"));
	return (0);
}

/* A later declaration of several plain capabilities keeps its order. */
static int
check_declaration_order(void)
{
	uint64_t registers[6] = { 0x10, 0x21, 0x32 };
	erx_sys_shape_t shape;
	erx_sys_admit_plan_t plan;

	/* third is the locked one, so it comes first, then first and second. */
	CHECK(decode(ERX_CALL_ADMIT_3_1, registers, &shape) == 0);
	CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_OK);
	CHECK(plan.caps[0].raw == 0x32 && plan.types[0] == 2 && plan.rights[0] == 0);
	CHECK(plan.caps[1].raw == 0x10 && plan.types[1] == 2 && plan.rights[1] == 2);
	CHECK(plan.caps[2].raw == 0x21 && plan.types[2] == 1 && plan.rights[2] == 1);

	/* A capability in the UTCB enters the plan from the decoded copy. */
	CHECK(decode(ERX_CALL_ADMIT_3_0, registers, &shape) == 0);
	CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_OK);
	CHECK(plan.caps[0].raw == 0x10 && plan.caps[1].raw == 0x21);
	CHECK(plan.caps[2].raw == 0x77 && plan.types[2] == 1 && plan.rights[2] == 4);

	/* Two required rights are both required. */
	CHECK(decode(ERX_CALL_ADMIT_2_0, registers, &shape) == 0);
	CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_OK);
	CHECK(plan.types[0] == 1 && plan.rights[0] == 5);
	return (0);
}

/* A call nobody declared never reaches a lookup or a handler. */
static int
check_unsupported(void)
{
	erx_sys_shape_t shape = { .number = UINT64_MAX };
	erx_sys_admit_plan_t plan;
	erx_sys_admission_t admission = {0};
	erx_sys_admit_action_t action;

	CHECK(erx_sys_admit_plan(&shape, &plan) == ERX_ENOTSUP);
	CHECK(erx_sys_admit_plan(NULL, &plan) == ERX_EINVAL);
	CHECK(erx_sys_admit_plan(&shape, NULL) == ERX_EINVAL);
	action = erx_sys_admit_first(&admission, &shape);
	CHECK(action.op == ERX_SYS_ADMIT_DONE && action.status == ERX_ENOTSUP);
	action = erx_sys_admit_first(&admission, NULL);
	CHECK(action.op == ERX_SYS_ADMIT_DONE && action.status == ERX_EINVAL);

	/* A zeroed record's phase is outside its enum, and runs nothing. */
	admission = (erx_sys_admission_t){0};
	action = erx_sys_admit_next(&admission, ERX_OK);
	CHECK(action.op == ERX_SYS_ADMIT_DONE && action.status == ERX_EINVAL);
	return (0);
}

int
main(void)
{
	if (check_space_copy() != 0 || check_one_lock() != 0 ||
	    check_declaration_order() != 0 ||
	    check_every_shape() != 0 || check_unsupported() != 0)
		return (1);
	puts("admission checks passed");
	return (0);
}
