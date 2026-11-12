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
 * The start is a spec checked whole, then the steps below in order. What the session keeps
 * of a program's channel comes first, so a release, which undoes the steps in reverse,
 * deletes it only after the program's budget. The session's doorbell, its event-table
 * sink, its bind and the gate registrations come before the spaces that carry the labels,
 * as erx_gate.h and erx_event.h require, so the gate registrations end before the doorbell
 * closes and the bind before the sink.
 *
 * The end reads the records of the program's two spaces: its image, the space its threads
 * run in, and its anchor, the space above it. Each space carries a label of its own, which
 * the driver allocates and never reuses, so a record names the space it is from and the
 * input says which; the end relies on no order between the two spaces' records.
 *
 * The port closes only after erx_program:start/1 read the start's answer: a port that
 * closed before would make that read fail for a program that ran, so a program that ends
 * first has its close held until the answer is read.
 */

#ifndef ERX_PROGRAM_CORE_H
#define ERX_PROGRAM_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/* The pids a spec may name: 0 and 1 are not programs' (docs/design-programs.md). */
#define ERX_PROGRAM_PID_MIN	INT64_C(2)
#define ERX_PROGRAM_PID_MAX	INT64_C(0x7fffffff)
/* What closing the port stops a running program with: SIGKILL's end. */
#define ERX_PROGRAM_KILLED	(ERX_EXIT_SIGNAL + ERX_SIGKILL)

/*
 * A bound on the actions one input of the end returns: a report, a stop, the whole release
 * (one undo per step at most) and a close. erx_program_core.c asserts the plan fits.
 */
#define ERX_PROGRAM_ACTIONS_MAX	21

typedef enum {
	ERX_PROGRAM_DONE = 0,		/* the start's run is over; see erx_program_start_t.error */

	/*
	 * The start's steps, in the order they are applied. What the session keeps and maps, the
	 * channel, both doorbells and the data area, all from its own budget, comes before the
	 * program's budget, so every release, last step first, deletes it after that budget is
	 * destroyed and the program never faults on its own channel (docs/design-programs.md,
	 * "The channel").
	 */
	ERX_PROGRAM_CHANNEL_CREATE,	/* the channel's two sides, the session's and the program's */
	ERX_PROGRAM_CHANNEL_MAP,	/* both into the session's space, as erx_program_session_prot says */
	ERX_PROGRAM_BELL_CREATE,	/* the program's doorbell, which the driver triggers */
	ERX_PROGRAM_DATA_CREATE,	/* the program's data area */
	ERX_PROGRAM_IRQ_CREATE,		/* the session's doorbell, the port's own IRQ object, which the program triggers */
	ERX_PROGRAM_SINK_REGISTER,	/* the port's sink in the event table, which gives the bind's label */
	ERX_PROGRAM_IRQ_BIND,		/* the session's doorbell into the session's group under that label */
	ERX_PROGRAM_BUDGET_CREATE,	/* carve the program's budget from the session's pool */
	ERX_PROGRAM_GROUP_CREATE,	/* its group, a child of the session's programs group */
	ERX_PROGRAM_GATE_REGISTER_ANCHOR, /* the anchor's label with the gate worker, for the session's doorbell */
	ERX_PROGRAM_GATE_REGISTER_IMAGE, /* the image's label, likewise */
	ERX_PROGRAM_ANCHOR_CREATE,	/* parent the session's space, its fault gate, the anchor's label */
	ERX_PROGRAM_IMAGE_CREATE,	/* below the anchor, the same gate, the image's label */
	ERX_PROGRAM_IMAGE_MAP,		/* the boot image's program, with erx_image_map */
	ERX_PROGRAM_INSTALL,		/* the program's copies into the image's table (erx_program_install_rights) */
	ERX_PROGRAM_BELL_BIND,		/* the program's doorbell into its group, labelled with the session's side's value */
	ERX_PROGRAM_THREAD_CREATE,	/* the image's first thread, stopped, in the program's group */
	ERX_PROGRAM_THREAD_START,

	/* The undos of the steps that made something; a release is all of them in this order. */
	ERX_PROGRAM_THREAD_CLOSE,
	ERX_PROGRAM_BELL_UNBIND,	/* a bind to ERX_CAP_NULL */
	ERX_PROGRAM_IMAGE_CLOSE,
	ERX_PROGRAM_ANCHOR_DESTROY,	/* erx_object_destroy, which ends the tree, then close */
	ERX_PROGRAM_GATE_UNREGISTER_IMAGE,
	ERX_PROGRAM_GATE_UNREGISTER_ANCHOR,
	ERX_PROGRAM_GROUP_CLOSE,
	ERX_PROGRAM_BUDGET_DESTROY,	/* erx_object_destroy, which ends all charged to it, then close */
	ERX_PROGRAM_IRQ_UNBIND,		/* a bind to ERX_CAP_NULL */
	ERX_PROGRAM_SINK_UNREGISTER,
	ERX_PROGRAM_IRQ_CLOSE,
	ERX_PROGRAM_DATA_DESTROY,
	ERX_PROGRAM_BELL_DESTROY,
	ERX_PROGRAM_CHANNEL_UNMAP,	/* erx_vm_release of the session's four mappings */
	ERX_PROGRAM_CHANNEL_DESTROY,

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
	int64_t		pid;		/* ERX_PROGRAM_PID_MIN..ERX_PROGRAM_PID_MAX */
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
 * The end, from a started program. Each phase is what is known of the image: RUNNING,
 * nothing; FAULTED, a thread of the image faulted, which decided the status and stopped the
 * anchor unless it had ended; ENDED, the image's exit record arrived and its status was
 * reported; RELEASED, everything the start made is released and the port is closing, or
 * waits to close until the start's answer is read (close_held). In this package the driver
 * applies at once what the design's handler would decide (docs/design-runtime.md,
 * "Ending"), since no handler exists yet.
 */
typedef enum {
	ERX_PROGRAM_RUNNING = 1,
	ERX_PROGRAM_FAULTED,
	ERX_PROGRAM_ENDED,
	ERX_PROGRAM_RELEASED
} erx_program_phase_t;

typedef struct {
	erx_program_phase_t	phase;
	int64_t			status;		/* FAULTED's: what the fault decided */
	bool			anchor_ended;	/* the anchor's exit record arrived */
	bool			answered;	/* erx_program:start/1 read the start's answer */
	bool			close_held;	/* RELEASED's: the port's close waits for the answer */
} erx_program_end_t;

typedef enum {
	ERX_PROGRAM_IMAGE_EXIT = 1,	/* the image's exit record, with its status */
	ERX_PROGRAM_ANCHOR_EXIT,	/* the anchor's exit record */
	ERX_PROGRAM_FAULT,		/* a fault record of a thread of the program, with its kind */
	ERX_PROGRAM_CLOSE,		/* the port is closing: port_close/1 or its owner's exit */
	ERX_PROGRAM_LOST,		/* a take found records lost (erx_gate.h) */
	ERX_PROGRAM_ANSWERED		/* the start's answer was read (port_control) */
} erx_program_input_kind_t;

/* Which of the program's spaces a record is from: the driver knows it by the record's label. */
typedef enum {
	ERX_PROGRAM_SPACE_IMAGE = 1,
	ERX_PROGRAM_SPACE_ANCHOR
} erx_program_space_t;

typedef struct {
	erx_program_input_kind_t	kind;
	int64_t				status;	/* IMAGE_EXIT's and ANCHOR_EXIT's */
	uint32_t			fault;	/* FAULT's: the record's kind */
} erx_program_input_t;

/* A started program's end: RUNNING, its anchor running and the start's answer not read. */
erx_program_end_t erx_program_end_begin(void);
/*
 * A record the gate worker kept for space's label as an input: that space's exit for
 * ERX_FAULT_EXIT, FAULT for any other kind. The driver takes no record before the start's
 * run returned DONE with ERX_OK; a start that failed unregistered both labels, and the
 * records kept for them went with them. The fault record itself, which the design keeps
 * for the shell, is the driver's to keep.
 */
erx_program_input_t erx_program_input_of(const erx_fault_t *record, erx_program_space_t space);
/*
 * Moves end on by input and writes what the driver does, in order, into actions: the
 * count written. A take that lost records is fed LOST before its records, so the program
 * ends as a close does and no status is reported (erx_gate.h). Guarantees, over every
 * sequence of inputs, in whatever order the two spaces' records come:
 *   - REPORT comes at most once, only from the image's exit record, and carries that
 *     record's status, or the fault's status when the record says the image ended by the
 *     anchor's stop the fault asked for (ERX_EXIT_PARENT);
 *   - the release (ERX_PROGRAM_THREAD_CLOSE to ERX_PROGRAM_CHANNEL_DESTROY, in that order)
 *     comes exactly once: once both spaces' exit records arrived, at a close, or at a
 *     loss; after it comes nothing but the port's held close;
 *   - the anchor is stopped at most once, and never after its exit record arrived: at the
 *     first fault or the image's exit, or with ERX_PROGRAM_KILLED by a close or a loss
 *     while the image runs;
 *   - CLOSE_PORT comes at most once, never at a close, where the port is already ending,
 *     and never before ANSWERED: with the release once the answer was read, else at the
 *     answer.
 */
size_t	erx_program_end_next(erx_program_end_t *end, erx_program_input_t input,
	    erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX]);

/*
 * What ERX_PROGRAM_INSTALL passes into the image's table, by index: at each of program_arg's
 * indices the object whose value the first thread's argument register of that index carries
 * (abi/erx_abi.txt), then the data area, whose value the startup message carries. The
 * session keeps the only DESTROY, and no copy carries DUP or GIVE, so on erXos's kernel the
 * program cannot end, copy or hand on what the session made; on the stopgap the rights are
 * the session's discipline only (docs/design-programs.md, "A program is a port" and "The
 * channel"; docs/design-stopgap.md).
 */
#define ERX_PROGRAM_INSTALL_DATA	((uint32_t)ERX_PROGRAM_ARG_DOORBELL + 1)
#define ERX_PROGRAM_INSTALLS		(ERX_PROGRAM_INSTALL_DATA + 1)

/* The rights the program's copy at index carries: 0 past the last index. */
uint32_t	erx_program_install_rights(uint32_t index);
/*
 * How the session maps the channel's side at index: read-only the side the program's copy
 * may write, its own, and read-write the side it may only read, the session's, so each
 * side has exactly one writer by the rights above. 0, no mapping, at any other index.
 */
uint32_t	erx_program_session_prot(uint32_t index);
/*
 * How many copies the install's erx_cap_pass from index first passes: at most ERX_MSG_CAPS,
 * and 0 once first is past the last, so passes from 0, each starting where the last ended,
 * pass every index once.
 */
uint32_t	erx_program_install_batch(uint32_t first);

#endif /* ERX_PROGRAM_CORE_H */
