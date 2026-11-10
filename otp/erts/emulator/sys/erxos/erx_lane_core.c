/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lane port's decisions; erx_lane_core.h says what they guarantee.
 */

#include "erx_lane_core.h"

static erx_lane_port_next_t
decided(erx_lane_port_state_t state, erx_lane_port_do_t what, bool drop)
{
	return ((erx_lane_port_next_t){ .state = state, .what = what, .drop = drop });
}

/* The finish is asked once: a second ask is refused and changes nothing. */
static erx_lane_port_next_t
decide_finish(erx_lane_port_state_t state)
{
	if (state != ERX_LANE_PORT_RUNNING)
		return (decided(state, ERX_LANE_DO_REFUSE, false));
	return (decided(ERX_LANE_PORT_FINISHING, ERX_LANE_DO_STOP, false));
}

/*
 * Once the finish starts the port writes nothing more into the outbound lane: a frame from
 * ERTS is dropped and counted, lost with the connection as the frames still in the entry's
 * queue are, and a kept frame is never resumed; the driver frees it at the port's stop.
 */
static erx_lane_port_next_t
decide_output(erx_lane_port_state_t state)
{
	if (state != ERX_LANE_PORT_RUNNING)
		return (decided(state, ERX_LANE_DO_NOTHING, true));
	return (decided(state, ERX_LANE_DO_WRITE, false));
}

static erx_lane_port_next_t
decide_kept(erx_lane_port_state_t state)
{
	if (state != ERX_LANE_PORT_RUNNING)
		return (decided(state, ERX_LANE_DO_NOTHING, false));
	return (decided(state, ERX_LANE_DO_RESUME, false));
}

/*
 * A running port takes nothing before it controls an entry: erx_dist runs the input task
 * again after setnode/3. A finishing port takes what is before the stop, entry or not.
 */
static erx_lane_port_next_t
decide_run(erx_lane_port_state_t state, bool entry)
{
	if (state == ERX_LANE_PORT_FINISHING || (state == ERX_LANE_PORT_RUNNING && entry))
		return (decided(state, ERX_LANE_DO_TAKE, false));
	return (decided(state, ERX_LANE_DO_NOTHING, false));
}

/* A verdict whose only effect is a send to the peer: an answer of noproc or a spawn error. */
static bool
answer_only(erx_funnel_action_t action)
{
	return (action == ERX_FUNNEL_ANSWER_NOPROC || action == ERX_FUNNEL_ANSWER_SPAWN ||
	    action == ERX_FUNNEL_DELIVER_IF_LINKED);
}

/*
 * A whole frame. A malformed one ends the port in any state that takes. Without an entry
 * there is nothing to act through, and a finishing port sends nothing more, so an
 * answer-only frame has no effect left: either is dropped and counted. The answers bound
 * holds input back only while the port can still send the answers; a finishing port takes at
 * most what is before the stop, one data area.
 * ERX_FUNNEL_DELIVER_IF_LINKED is answer-only too: a LINK it keeps creates nothing
 * (erx/funnel.h), and one it does not keep is answered as for an absent target.
 */
static erx_lane_port_next_t
decide_frame(erx_lane_port_state_t state, const erx_lane_port_input_t *input)
{
	if (state == ERX_LANE_PORT_FINISHED)
		return (decided(state, ERX_LANE_DO_NOTHING, true));
	if (input->action == ERX_FUNNEL_MALFORMED)
		return (decided(state, ERX_LANE_DO_END_MALFORMED, false));
	if (!input->entry || (state == ERX_LANE_PORT_FINISHING && answer_only(input->action)))
		return (decided(state, ERX_LANE_DO_NOTHING, true));
	if (state == ERX_LANE_PORT_RUNNING && input->answers_full && input->action != ERX_FUNNEL_DROP &&
	    erx_lane_port_answered(input->op))
		return (decided(state, ERX_LANE_DO_END_ANSWERS, false));
	return (decided(state, ERX_LANE_DO_ACT, false));
}

/*
 * A stopped reader is empty only once it has taken every byte before its stop, so a
 * finishing port's empty take is its finish's end: a record the stop cut short is dropped
 * and counted, never judged, and the agent is told. A running port's empty take has
 * published its wait.
 */
static erx_lane_port_next_t
decide_empty(erx_lane_port_state_t state, bool cut)
{
	if (state != ERX_LANE_PORT_FINISHING)
		return (decided(state, ERX_LANE_DO_NOTHING, false));
	return (decided(ERX_LANE_PORT_FINISHED, ERX_LANE_DO_TELL, cut));
}

erx_lane_port_next_t
erx_lane_port_decide(erx_lane_port_state_t state, const erx_lane_port_input_t *input)
{
	switch (input->event) {
	case ERX_LANE_PORT_FINISH:
		return (decide_finish(state));
	case ERX_LANE_PORT_OUTPUT:
		return (decide_output(state));
	case ERX_LANE_PORT_KEPT:
		return (decide_kept(state));
	case ERX_LANE_PORT_RUN:
		return (decide_run(state, input->entry));
	case ERX_LANE_PORT_FRAME:
		return (decide_frame(state, input));
	case ERX_LANE_PORT_EMPTY:
		return (decide_empty(state, input->cut));
	}
	return (decided(state, ERX_LANE_DO_NOTHING, false));
}

bool
erx_lane_port_answered(erx_funnel_op_t op)
{
	return (op == ERX_FUNNEL_LINK || op == ERX_FUNNEL_MONITOR_P || op == ERX_FUNNEL_UNLINK_ID ||
	    op == ERX_FUNNEL_SPAWN_REQUEST);
}
