/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the lane port's decisions (otp/erts/emulator/sys/erxos/erx_lane_core.c),
 * for test/host/erx_lane_core_test.rb: it prints erx_lane_port_decide's answer for every
 * state, event and combination of the facts an event is decided on, one line each,
 *
 *   STATE EVENT ENTRY ACTION OP FULL CUT -> NEXT WHAT DROP
 *
 * every field a number, and then erx_lane_port_answered for every operation, as
 *
 *   answered OP YES
 *
 * The test compares both with a model of its own.
 */

#include <stdio.h>

#include "erx_lane_core.h"

/* The operations of the grammar, and 0, the operation of a verdict whose control term failed. */
static const erx_funnel_op_t ops[] = {
	(erx_funnel_op_t)0, ERX_FUNNEL_LINK, ERX_FUNNEL_GROUP_LEADER, ERX_FUNNEL_MONITOR_P,
	ERX_FUNNEL_DEMONITOR_P, ERX_FUNNEL_SEND_SENDER, ERX_FUNNEL_PAYLOAD_EXIT, ERX_FUNNEL_PAYLOAD_EXIT2,
	ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT, ERX_FUNNEL_SPAWN_REQUEST, ERX_FUNNEL_SPAWN_REPLY,
	ERX_FUNNEL_ALIAS_SEND, ERX_FUNNEL_UNLINK_ID, ERX_FUNNEL_UNLINK_ID_ACK
};

int
main(void)
{
	for (int state = ERX_LANE_PORT_RUNNING; state <= ERX_LANE_PORT_FINISHED; state++)
	for (int event = ERX_LANE_PORT_FINISH; event <= ERX_LANE_PORT_EMPTY; event++)
	for (int entry = 0; entry <= 1; entry++)
	for (int action = ERX_FUNNEL_MALFORMED; action <= ERX_FUNNEL_TOO_LARGE; action++)
	for (size_t op = 0; op < sizeof(ops) / sizeof(ops[0]); op++)
	for (int full = 0; full <= 1; full++)
	for (int cut = 0; cut <= 1; cut++) {
		const erx_lane_port_input_t input = {
			.event = (erx_lane_port_event_t)event, .entry = entry, .action = (erx_funnel_action_t)action,
			.op = ops[op], .answers_full = full, .cut = cut
		};
		const erx_lane_port_next_t next = erx_lane_port_decide((erx_lane_port_state_t)state, &input);

		printf("%d %d %d %d %d %d %d -> %d %d %d\n", state, event, entry, action, (int)ops[op], full, cut,
		    (int)next.state, (int)next.what, (int)next.drop);
	}
	for (size_t op = 0; op < sizeof(ops) / sizeof(ops[0]); op++)
		printf("answered %d %d\n", (int)ops[op], (int)erx_lane_port_answered(ops[op]));
	return (0);
}
