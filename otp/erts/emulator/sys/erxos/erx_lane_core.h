/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lane port's decisions (docs/design-runtime.md, "Connections in ERTS"): where the port
 * is in its finish, and, for each event the driver sees, what it does next. The driver,
 * erx_lane_drv.c, gathers an event's facts and asks through its one funnel, port_decide,
 * which stores the next state and counts a drop, and then does the one action. The core
 * reads no hardware, no ERTS state and no global state, and builds for the host, where
 * test/host/erx_lane_core_test.rb checks these rules over every state, event and fact:
 *
 *   - an event does only what it may (its actions are named below);
 *   - only a running port writes into the outbound lane or resumes a kept frame;
 *   - a finished port takes, acts on and tells nothing;
 *   - a frame is acted on only through an entry;
 *   - a finishing port takes, and acts on no answer-only frame, whose answer it would never
 *     send, so what a finish queues is bounded by what it takes;
 *   - the answers bound ends only a running port;
 *   - the agent is told on the empty take that moves the port from finishing to finished,
 *     and only then, with a record the stop cut short counted as dropped, never judged;
 *   - the state only moves forward, at the finish and at its end.
 */

#ifndef ERX_LANE_CORE_H
#define ERX_LANE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/funnel.h"

/* Where the port is in its finish (port_control 2); a port that never finishes stays running. */
typedef enum erx_lane_port_state {
	ERX_LANE_PORT_RUNNING = 0,	/* both lanes carry frames */
	ERX_LANE_PORT_FINISHING,	/* the reader is stopped; input takes what is before the stop */
	ERX_LANE_PORT_FINISHED		/* the agent is told; nothing more is taken or written */
} erx_lane_port_state_t;

/* What happened to the port. */
typedef enum erx_lane_port_event {
	ERX_LANE_PORT_FINISH,		/* port_control 2 */
	ERX_LANE_PORT_OUTPUT,		/* ERTS hands the port a frame for the peer */
	ERX_LANE_PORT_KEPT,		/* the input task finds a frame kept for want of room */
	ERX_LANE_PORT_RUN,		/* the input task starts */
	ERX_LANE_PORT_FRAME,		/* a whole frame came in, judged by the funnel */
	ERX_LANE_PORT_EMPTY		/* a take found nothing more: none published, or none before the stop */
} erx_lane_port_event_t;

/* An event and the facts it is decided on; a field an event does not name is ignored. */
typedef struct erx_lane_port_input {
	erx_lane_port_event_t	 event;
	bool			 entry;		/* RUN, FRAME: the port controls a distribution entry */
	erx_funnel_action_t	 action;	/* FRAME: the funnel's verdict */
	erx_funnel_op_t		 op;		/* FRAME: the verdict's operation, once its control term passed */
	bool			 answers_full;	/* FRAME: the entry's unsent answers reach ERX_LANE_ANSWERS_MAX */
	bool			 cut;		/* EMPTY: a record is open, cut short by the stop */
} erx_lane_port_input_t;

/* The one thing the driver does for an event. */
typedef enum erx_lane_port_do {
	ERX_LANE_DO_NOTHING,		/* nothing: idle, the frame stays kept, or the take's wait is published */
	ERX_LANE_DO_REFUSE,		/* FINISH: port_control answers badarg */
	ERX_LANE_DO_STOP,		/* FINISH: stop the reader and schedule the input task */
	ERX_LANE_DO_WRITE,		/* OUTPUT: write the frame into the outbound lane */
	ERX_LANE_DO_RESUME,		/* KEPT: go on writing the kept frame */
	ERX_LANE_DO_TAKE,		/* RUN: take records, up to the allowance */
	ERX_LANE_DO_ACT,		/* FRAME: do what the verdict says, through the entry */
	ERX_LANE_DO_END_MALFORMED,	/* FRAME: end the port, erx_lane_malformed */
	ERX_LANE_DO_END_ANSWERS,	/* FRAME: end the port, erx_lane_answers_unread */
	ERX_LANE_DO_TELL		/* EMPTY: send the finisher {Port, erx_lane_finished} */
} erx_lane_port_do_t;

typedef struct erx_lane_port_next {
	erx_lane_port_state_t	 state;		/* where the port is once the event is applied */
	erx_lane_port_do_t	 what;
	bool			 drop;		/* the event's frame or record is dropped: count it */
} erx_lane_port_next_t;

/* The port's next state and action for an event in state. */
erx_lane_port_next_t	erx_lane_port_decide(erx_lane_port_state_t state, const erx_lane_port_input_t *input);

/*
 * Whether a frame of op can make this domain answer the peer with a send that has no
 * sending process: an exit or DOWN noproc, an unlink ack, or a spawn reply. Such sends
 * ignore the busy limit (dist.c, erts_dsig_prepare), so these are the frames the answers
 * bound holds back.
 */
bool	erx_lane_port_answered(erx_funnel_op_t op);

/*
 * The funnel's scratch: one block the connection keeps at its largest size. It starts at
 * ERX_FUNNEL_CTL_SCRATCH, so a control term is always judged whole, and grows before a
 * frame is judged to what erx_funnel_check_scratch_bytes says the frame's held bytes need.
 */
typedef struct erx_lane_scratch {
	uint8_t		*block;
	size_t		 len;
} erx_lane_scratch_t;

/*
 * Grows scratch to want bytes, which is SIZE_MAX when the size overflows. Returns false when that cannot
 * be allocated, with scratch unchanged: the receiver is short of memory, which is not the
 * frame's fault, so the caller ends the connection as it does when its record buffer cannot
 * grow, and does not judge the frame against a smaller scratch. The block is a fresh one,
 * as nothing in the scratch outlives a judgment; alloc returns NULL when it cannot.
 */
bool	erx_lane_scratch_grow(erx_lane_scratch_t *scratch, size_t want, void *(*alloc)(size_t),
	    void (*release)(void *));

#endif /* !ERX_LANE_CORE_H */
