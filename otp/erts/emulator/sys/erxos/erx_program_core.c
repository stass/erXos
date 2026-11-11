/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The erx_program port's core: the spec check, the start's run and the end's decisions
 * (erx_program_core.h). Pure: it reads and writes only what it is given.
 */

#include <stdbool.h>

#include "erx_program_core.h"

/* A step that made nothing of its own: a map dies with its space, and the start is last. */
#define NO_UNDO	ERX_PROGRAM_DONE

/*
 * The start's one order, and what undoes each step. A release is this table read
 * backwards, so a failed start and a program's end free the same things the same way.
 */
static const struct {
	erx_program_act_t	step;
	erx_program_act_t	undo;
} plan[] = {
	{ ERX_PROGRAM_BUDGET_CREATE, ERX_PROGRAM_BUDGET_DESTROY },
	{ ERX_PROGRAM_GROUP_CREATE, ERX_PROGRAM_GROUP_CLOSE },
	{ ERX_PROGRAM_IRQ_CREATE, ERX_PROGRAM_IRQ_CLOSE },
	{ ERX_PROGRAM_SINK_REGISTER, ERX_PROGRAM_SINK_UNREGISTER },
	{ ERX_PROGRAM_IRQ_BIND, ERX_PROGRAM_IRQ_UNBIND },
	{ ERX_PROGRAM_GATE_REGISTER, ERX_PROGRAM_GATE_UNREGISTER },
	{ ERX_PROGRAM_ANCHOR_CREATE, ERX_PROGRAM_ANCHOR_DESTROY },
	{ ERX_PROGRAM_IMAGE_CREATE, ERX_PROGRAM_IMAGE_CLOSE },
	{ ERX_PROGRAM_IMAGE_MAP, NO_UNDO },
	{ ERX_PROGRAM_THREAD_CREATE, ERX_PROGRAM_THREAD_CLOSE },
	{ ERX_PROGRAM_THREAD_START, NO_UNDO },
};
#define PLAN_STEPS	((uint32_t)(sizeof(plan) / sizeof(plan[0])))
_Static_assert(PLAN_STEPS + 2 <= ERX_PROGRAM_ACTIONS_MAX, "an end's stop, release and close fit its actions");

/* No control byte, and every component, the bytes between slashes, is neither empty, "." nor "..". */
static bool
image_path_valid(const uint8_t *path, size_t len)
{
	size_t start = 0;

	if (len == 0 || len > ERX_PACK_PATH_MAX)
		return (false);
	for (size_t at = 0; at <= len; at++) {
		size_t component;

		if (at < len && path[at] != '/') {
			if (path[at] < 0x20 || path[at] == 0x7f)
				return (false);
			continue;
		}
		component = at - start;
		if (component == 0 || (path[start] == '.' && (component == 1 ||
		    (component == 2 && path[start + 1] == '.'))))
			return (false);
		start = at + 1;
	}
	return (true);
}

int
erx_program_spec_check(const erx_program_spec_t *spec, uint64_t pool)
{
	if (!image_path_valid(spec->image, spec->image_len))
		return (ERX_EINVAL);
	if (spec->pid < ERX_PROGRAM_PID_MIN || spec->pid > ERX_PROGRAM_PID_MAX)
		return (ERX_ERANGE);
	if (spec->guarantee > spec->cap)
		return (ERX_EINVAL);
	if (spec->cap > pool)
		return (ERX_ELIMIT);
	return (ERX_OK);
}

void
erx_program_start_begin(erx_program_start_t *run, const erx_program_spec_t *spec, uint64_t pool)
{
	run->applied = 0;
	run->undoing = 0;
	run->error = erx_program_spec_check(spec, pool);
	/* A refused spec ends the run before any step. */
	run->over = run->error != ERX_OK;
}

erx_program_act_t
erx_program_start_next(erx_program_start_t *run, int result)
{
	if (run->over)
		return (ERX_PROGRAM_DONE);
	if (!run->undoing && result == ERX_OK && run->applied < PLAN_STEPS)
		return (plan[run->applied++].step);
	if (!run->undoing && result != ERX_OK) {
		/* The step last returned, if any, failed and made nothing: undo the ones before it. */
		run->error = result;
		run->undoing = 1;
		if (run->applied > 0)
			run->applied--;
	}
	while (run->undoing && run->applied > 0) {
		const erx_program_act_t undo = plan[--run->applied].undo;

		if (undo != NO_UNDO)
			return (undo);
	}
	run->over = 1;
	return (ERX_PROGRAM_DONE);
}

erx_program_end_t
erx_program_end_begin(void)
{
	return ((erx_program_end_t){ .phase = ERX_PROGRAM_RUNNING });
}

erx_program_input_t
erx_program_input_of(const erx_fault_t *record)
{
	if (record->kind == ERX_FAULT_EXIT)
		return ((erx_program_input_t){ .kind = ERX_PROGRAM_EXIT, .status = record->status });
	return ((erx_program_input_t){ .kind = ERX_PROGRAM_FAULT, .fault = (uint32_t)record->kind });
}

/*
 * The status a fault ends the program with: its kind's signal from the fault table, and
 * SIGKILL's for a kind the table does not hold, so a fault always ends the program.
 */
static int64_t
fault_status(uint32_t kind)
{
	const int signal = erx_fault_signal(kind);

	return (ERX_EXIT_SIGNAL + (signal != 0 ? signal : ERX_SIGKILL));
}

/*
 * What the anchor is stopped with after the image ended with status: the same status, as
 * the design says, unless it is one of the kernel's own, which erx_space_stop refuses.
 */
static int64_t
anchor_status(int64_t status)
{
	if (status == ERX_EXIT_PARENT || status == ERX_EXIT_RELEASED || status == ERX_EXIT_NOTHREAD)
		return (ERX_PROGRAM_KILLED);
	return (status);
}

static size_t
put(erx_program_action_t actions[], size_t at, erx_program_act_t act, int64_t status)
{
	actions[at] = (erx_program_action_t){ .act = act, .status = status };
	return (at + 1);
}

/*
 * Ends the program's hold on everything the start made, after the actions already in
 * actions[0..at): every undo, last step first, then the port's close while it is open.
 */
static size_t
release(erx_program_end_t *end, erx_program_action_t actions[], size_t at, bool port_open)
{
	for (uint32_t step = PLAN_STEPS; step > 0; step--) {
		if (plan[step - 1].undo != NO_UNDO)
			at = put(actions, at, plan[step - 1].undo, 0);
	}
	if (port_open)
		at = put(actions, at, ERX_PROGRAM_CLOSE_PORT, 0);
	*end = (erx_program_end_t){ .phase = ERX_PROGRAM_RELEASED };
	return (at);
}

size_t
erx_program_end_next(erx_program_end_t *end, erx_program_input_t input,
    erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX])
{
	size_t at = 0;

	if (end->phase == ERX_PROGRAM_RELEASED)
		return (0);
	switch (input.kind) {
	case ERX_PROGRAM_EXIT:
		/* The first exit record is the image's, the second the anchor's (erx_program_core.h). */
		if (end->phase == ERX_PROGRAM_ENDED)
			return (release(end, actions, 0, true));
		if (end->phase == ERX_PROGRAM_FAULTED) {
			/*
			 * The anchor is stopping already. An image ended by that stop reports the
			 * fault's status; one that halted on its own first reports its own.
			 */
			at = put(actions, at, ERX_PROGRAM_REPORT,
			    input.status == ERX_EXIT_PARENT ? end->status : input.status);
		} else {
			at = put(actions, at, ERX_PROGRAM_REPORT, input.status);
			at = put(actions, at, ERX_PROGRAM_STOP_ANCHOR, anchor_status(input.status));
		}
		*end = (erx_program_end_t){ .phase = ERX_PROGRAM_ENDED };
		return (at);
	case ERX_PROGRAM_FAULT:
		/* Only the first fault decides; the image's exit record reports it. */
		if (end->phase != ERX_PROGRAM_RUNNING)
			return (0);
		*end = (erx_program_end_t){ .phase = ERX_PROGRAM_FAULTED, .status = fault_status(input.fault) };
		return (put(actions, 0, ERX_PROGRAM_STOP_ANCHOR, end->status));
	case ERX_PROGRAM_CLOSE:
	case ERX_PROGRAM_LOST: {
		const bool port_open = input.kind == ERX_PROGRAM_LOST;

		/* No status is reported: the port is closing, or a record of the end may be lost. */
		if (end->phase == ERX_PROGRAM_RUNNING)
			at = put(actions, 0, ERX_PROGRAM_STOP_ANCHOR, ERX_PROGRAM_KILLED);
		return (release(end, actions, at, port_open));
	}
	}
	return (0);
}
