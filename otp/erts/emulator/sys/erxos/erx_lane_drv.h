/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lane port driver's allowance and counts (erx_lane_drv.c).
 */

#ifndef ERX_LANE_DRV_H
#define ERX_LANE_DRV_H

#include <stdbool.h>
#include <stdint.h>

/*
 * The frames one run of a connection port's input task takes before it reschedules itself,
 * -erx lane_batch; the default keeps a run of small frames within a scheduler's reduction slice
 * (docs/design-runtime.md, "Risks and open questions": E-D1 measures it).
 */
#define ERX_LANE_BATCH_DEFAULT	64u
extern uint32_t erx_lane_batch;

/*
 * -erx test_lane_hold, a test's switch, off by default: port_control 4 may then hold the
 * ring of one of this domain's lane ports (erx_lane_drv.c, control_hold).
 */
extern bool erx_lane_test_hold;

/*
 * The runtime's -erx flags among the emulator flags, before "--": "-erx lane_batch N" and
 * "-erx test_lane_hold". Takes each from argv, which keeps the rest in order and ends in
 * NULL. false for an -erx flag it does not know or a value out of range, and the runtime
 * does not start.
 */
bool erx_lane_flags(int *argc, char **argv);

/*
 * The bytes of answers a connection's entry may hold unsent (exits, DOWNs, unlink acks and
 * spawn replies it sends with no sending process, which ignore the busy limit) before a
 * frame that can be answered ends the port with erx_lane_answers_unread: a peer that asks
 * and never reads its answers. As much as ERTS's busy limit lets senders queue.
 */
#define ERX_LANE_ANSWERS_MAX	(1u << 20)

/* What port_control(Port, 0, []) reports, one 64-bit word each, in this order. */
typedef enum erx_lane_count {
	ERX_LANE_COUNT_SENT,		/* frames written whole into the lane */
	ERX_LANE_COUNT_PAUSED,		/* times the output waited for room */
	ERX_LANE_COUNT_RESUMED,		/* times the bell let it go on */
	ERX_LANE_COUNT_DELIVERED,	/* frames handed to distribution input */
	ERX_LANE_COUNT_ANSWERED,	/* frames answered as for an absent target */
	ERX_LANE_COUNT_DROPPED,		/* frames dropped by the verdict, and records the finish cut */
	ERX_LANE_COUNT_MALFORMED,	/* lanes ended by a failed check */
	ERX_LANE_COUNT_OUT_DROPPED,	/* frames of ERTS's no lane carries, or sent while finishing */
	ERX_LANE_COUNT_OUT_REFUSED,	/* outputs the lane refused, ending the port */
	ERX_LANE_COUNT_RING_FAILED,	/* bell triggers that failed */
	ERX_LANE_COUNT_CTL_TAKEN,	/* control-table records taken */
	ERX_LANE_COUNT_CTL_REWRITTEN,	/* of those, slots whose seq moved by anything but one */
	ERX_LANE_COUNTS
} erx_lane_count_t;

#endif /* ERX_LANE_DRV_H */
