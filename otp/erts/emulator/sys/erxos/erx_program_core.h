/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The erx_program port's core (docs/design-runtime.md, "Programs as ports"): every decision
 * the driver makes about a program's spaces, as two pure state machines that return the
 * driver's next action. The driver applies each action with the kernel call it names and
 * feeds the outcome back; it never chooses an order itself, so a start that fails partway
 * undoes exactly what it made, and a program ends with each status reported at most once
 * and everything it held released once. It knows nothing of ERTS and calls no kernel, so a
 * host test drives every path (test/host/erx_program_core_test.rb).
 *
 * The start is a spec checked whole, then the steps below in order. The IRQ object, its
 * event-table sink, its bind and the gate registration come before the spaces that carry
 * the label, as erx_gate.h and erx_event.h require; a release undoes the steps in reverse,
 * so the gate registration ends before the object closes and the bind before the sink.
 *
 * The end reads the records of the program's two spaces, which both carry the program's
 * pid as their label. Its image is the space its threads run in, and its anchor the space
 * above it; the kernel posts a child's exit record before its parent's, so the first exit
 * record is always the image's and the second the anchor's.
 */

#ifndef ERX_PROGRAM_CORE_H
#define ERX_PROGRAM_CORE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/* The pids a spec may name: 0 and 1 are not programs' (docs/design-programs.md). */
#define ERX_PROGRAM_PID_MIN	INT64_C(2)
#define ERX_PROGRAM_PID_MAX	INT64_C(0x7fffffff)
/* What closing the port stops a running program with: SIGKILL's end. */
#define ERX_PROGRAM_KILLED	(ERX_EXIT_SIGNAL + ERX_SIGKILL)

/*
 * The most actions one input of the end returns: a stop, the whole release (one undo per
 * step at most) and a close. erx_program_core.c asserts the plan fits.
 */
#define ERX_PROGRAM_ACTIONS_MAX	13

typedef enum {
	ERX_PROGRAM_DONE = 0,		/* the start's run is over; see erx_program_start_t.error */

	/* The start's steps, in the order they are applied. */
	ERX_PROGRAM_BUDGET_CREATE,	/* carve the program's budget from the session's pool */
	ERX_PROGRAM_GROUP_CREATE,	/* its group, a child of the session's programs group */
	ERX_PROGRAM_IRQ_CREATE,		/* the port's own IRQ object, from the session's budget */
	ERX_PROGRAM_SINK_REGISTER,	/* the port's sink in the event table, which gives the bind's label */
	ERX_PROGRAM_IRQ_BIND,		/* the object into the session's group under that label */
	ERX_PROGRAM_GATE_REGISTER,	/* the pid with the gate worker, for the object */
	ERX_PROGRAM_ANCHOR_CREATE,	/* parent the session's space, its fault gate, label the pid */
	ERX_PROGRAM_IMAGE_CREATE,	/* below the anchor, same gate and label */
	ERX_PROGRAM_IMAGE_MAP,		/* the boot image's program, with erx_image_map */
	ERX_PROGRAM_THREAD_CREATE,	/* the image's first thread, stopped, in the program's group */
	ERX_PROGRAM_THREAD_START,

	/* The undos of the steps that made something; a release is all of them in this order. */
	ERX_PROGRAM_THREAD_CLOSE,
	ERX_PROGRAM_IMAGE_CLOSE,
	ERX_PROGRAM_ANCHOR_DESTROY,	/* erx_object_destroy, which ends the tree, then close */
	ERX_PROGRAM_GATE_UNREGISTER,
	ERX_PROGRAM_IRQ_UNBIND,		/* a bind to ERX_CAP_NULL */
	ERX_PROGRAM_SINK_UNREGISTER,
	ERX_PROGRAM_IRQ_CLOSE,
	ERX_PROGRAM_GROUP_CLOSE,
	ERX_PROGRAM_BUDGET_DESTROY,	/* erx_object_destroy, which ends all charged to it, then close */

	/* The end's own. */
	ERX_PROGRAM_REPORT,		/* {Port, {exit_status, status}} to the owner */
	ERX_PROGRAM_STOP_ANCHOR,	/* erx_space_stop(anchor, status) */
	ERX_PROGRAM_CLOSE_PORT		/* the driver ends its port */
} erx_program_act_t;

typedef struct {
	erx_program_act_t	act;
	int64_t			status;	/* ERX_PROGRAM_REPORT's and ERX_PROGRAM_STOP_ANCHOR's only */
} erx_program_action_t;

/*
 * What a start asks for. image is the program's path in the session's release, as
 * "bin/exit42": 1 to ERX_PACK_PATH_MAX bytes, no control byte, and no empty, "." or ".."
 * component, as the packer allows. Bytes above 0x7f pass unchecked: a path that is not
 * UTF-8 names no entry, and the release lookup, the driver's, refuses it.
 */
typedef struct {
	const uint8_t	*image;
	size_t		image_len;
	int64_t		pid;		/* ERX_PROGRAM_PID_MIN..ERX_PROGRAM_PID_MAX; the label of both spaces */
	uint64_t	guarantee;	/* of the program's budget, at most cap */
	uint64_t	cap;		/* at most the session's pool for programs */
} erx_program_spec_t;

/*
 * ERX_OK; ERX_EINVAL for a malformed image path or a guarantee above the cap; ERX_ERANGE
 * for a pid outside its range; ERX_ELIMIT for a cap above pool.
 */
int	erx_program_spec_check(const erx_program_spec_t *spec, uint64_t pool);

/*
 * A start's run. Its fields are the core's; error is the run's answer once it returned
 * ERX_PROGRAM_DONE: ERX_OK when every step was applied and the program runs, else the
 * spec's refusal or the failed step's outcome, after the undos of the steps before it.
 */
typedef struct {
	uint32_t	applied;	/* steps returned so far; while undoing, those not yet undone */
	int		undoing;	/* a step failed: undos are returned */
	int		over;		/* DONE was returned, and is from then on */
	int		error;
} erx_program_start_t;

/*
 * Checks the spec whole (erx_program_spec_check) and begins the run, which applies nothing
 * when the spec is refused: its first action is then ERX_PROGRAM_DONE with that error.
 */
void	erx_program_start_begin(erx_program_start_t *run, const erx_program_spec_t *spec, uint64_t pool);
/*
 * The next action, given result, the outcome of the action the last call returned
 * (ERX_OK on the first call, where any other value is a failure with nothing to undo).
 * A step's failure turns the run to the undos of the steps applied before it, last first,
 * whose outcomes are not read: an undo releases what its
 * step made, and nothing better can be done if it fails.
 */
erx_program_act_t erx_program_start_next(erx_program_start_t *run, int result);

/*
 * The end, from a started program. Each phase is what is known: RUNNING, nothing; FAULTED,
 * a thread of the image faulted, which decided the status and stopped the anchor; ENDED,
 * the image's exit record arrived and its status was reported; RELEASED, everything the
 * start made is released and the port's end is asked for or under way, so the close the port's end then feeds asks
 * for nothing. In this package the driver applies at once what the design's handler would
 * decide (docs/design-runtime.md, "Ending"), since no handler exists yet.
 */
typedef enum {
	ERX_PROGRAM_RUNNING = 1,
	ERX_PROGRAM_FAULTED,
	ERX_PROGRAM_ENDED,
	ERX_PROGRAM_RELEASED
} erx_program_phase_t;

typedef struct {
	erx_program_phase_t	phase;
	int64_t			status;	/* FAULTED's: what the fault decided */
} erx_program_end_t;

typedef enum {
	ERX_PROGRAM_EXIT = 1,		/* an exit record of one of the two spaces, with its status */
	ERX_PROGRAM_FAULT,		/* a fault record of an image thread, with its kind */
	ERX_PROGRAM_CLOSE,		/* the port is closing: port_close/1 or its owner's exit */
	ERX_PROGRAM_LOST		/* a take found records lost (erx_gate.h) */
} erx_program_input_kind_t;

typedef struct {
	erx_program_input_kind_t	kind;
	int64_t				status;	/* EXIT's */
	uint32_t			fault;	/* FAULT's: the record's kind */
} erx_program_input_t;

/* A started program's end: RUNNING. */
erx_program_end_t erx_program_end_begin(void);
/*
 * The driver takes no record before the start's run returned DONE with ERX_OK; a start
 * that failed unregistered the pid, and the records kept for it went with it. The fault
 * record itself, which the design keeps for the shell, is the driver's to keep.
 */
/* A record the gate worker kept as an input: EXIT for ERX_FAULT_EXIT, FAULT for any other kind. */
erx_program_input_t erx_program_input_of(const erx_fault_t *record);
/*
 * Moves end on by input and writes what the driver does, in order, into actions: the
 * count written. A take that lost records is fed LOST before its records, so the program
 * ends as a close does and no status is reported (erx_gate.h). Guarantees, over every
 * sequence of inputs:
 *   - REPORT comes at most once, only from an image's exit record, and carries that
 *     record's status, or the fault's status when the record says the image ended by the
 *     anchor's stop the fault asked for (ERX_EXIT_PARENT);
 *   - the release (ERX_PROGRAM_THREAD_CLOSE to ERX_PROGRAM_BUDGET_DESTROY, in that order)
 *     comes exactly once, at the anchor's exit record, a close or a loss, and nothing
 *     comes after it;
 *   - the anchor is stopped at most once: at the first fault or the image's exit, or with
 *     ERX_PROGRAM_KILLED by a close or a loss while it runs;
 *   - CLOSE_PORT comes with the release, except at a close, where the port is already ending.
 */
size_t	erx_program_end_next(erx_program_end_t *end, erx_program_input_t input,
	    erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX]);

#endif /* ERX_PROGRAM_CORE_H */
