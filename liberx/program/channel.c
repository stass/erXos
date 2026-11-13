/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The channel's send (channel.h).  The lane's writer state is guarded by
 * one mutex, which a sender holds from its first look at the room to the
 * record's last byte and lets go of before every wait.  The items it puts
 * are marked whole, so a put writes all of a frame or none of it, and the
 * writer is never left inside a record that another sender would find.
 *
 * The wait for room is a wait on an object (wake.h): a sender reads its
 * wake word, puts itself on the channel's waiters and puts armed, which
 * publishes the room it needs, fences and looks once more, all under the
 * lock.  Once the session's read crosses that need it rings the doorbell,
 * and the executor takes the label and wakes the waiters under the same
 * lock, so it finds the sender on the list and bumps the word the sender
 * read, and the sender's sleep returns.  A woken sender takes the lock
 * and puts again, so a wake that brought too little room only sends it
 * back to wait.
 *
 * The lane has one need word, and each armed put overwrites it, so it
 * holds the need of the sender that published last.  While that sender
 * waits, its need's crossing wakes every waiter.  A sender that leaves
 * the lane, its frame written or the lane broken, may be the one whose
 * need is published, and the need of a sender still waiting then stands
 * nowhere; so a sender that leaves while others wait wakes them itself,
 * and each of them publishes its need again.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"
#include "liberx/program/wake.h"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
/* Under lock, once erx_prog_channel_open has readied it. */
static erx_lane_writer_t outbound;
/* Set by erx_prog_channel_open before any thread sends. */
static uint64_t doorbell;
/* The senders waiting for room, under lock. */
static erx_prog_waitq_t room_waiters;

bool
erx_prog_channel_open(void *own_side, const void *peer_side, uint64_t bell)
{
	doorbell = bell;
	return (erx_lane_writer_init(&outbound, own_side, peer_side, ERX_PROGRAM_LANE));
}

/*
 * Puts the item under the lock until the lane takes it whole or refuses it,
 * letting go of the lock while it waits for room, and returns DONE, REFUSED
 * or MALFORMED, never SHORT. What the last put did is in *put.
 */
static erx_lane_put_status_t
whole_put(const erx_lane_item_t *item, erx_lane_put_t *put)
{
	erx_lane_put_status_t status;

	(void)pthread_mutex_lock(&lock);
	/* A lane with room takes the frame without publishing a need, which would cost a ring. */
	status = erx_lane_put(&outbound, item, put);
	while (status == ERX_LANE_PUT_SHORT) {
		const uint32_t seen = erx_prog_wake_seen();
		erx_prog_waiter_t me;

		erx_prog_waitq_join(&room_waiters, &me);
		status = erx_lane_put_armed(&outbound, item, put);
		if (status == ERX_LANE_PUT_SHORT) {
			(void)pthread_mutex_unlock(&lock);
			/* The open wait: the sender holds nothing of the channel's here. */
			erx_prog_wake_sleep(seen, ERX_WAIT_FOREVER);
			(void)pthread_mutex_lock(&lock);
		}
		erx_prog_waitq_leave(&room_waiters, &me);
	}
	/* This sender leaves: a need it published stands for none of those still waiting. */
	erx_prog_waitq_wake(&room_waiters);
	(void)pthread_mutex_unlock(&lock);
	return (status);
}

int
erx_prog_channel_send(const erx_lane_iov_t *iov, size_t iovcnt)
{
	const erx_lane_item_t item = { .iov = iov, .iovcnt = iovcnt, .kind = ERX_REC_FRAME, .whole = true };
	erx_lane_put_t put;

	switch (whole_put(&item, &put)) {
	case ERX_LANE_PUT_DONE:
		/* The session may wait for this frame; a failed ring is the session's to miss. */
		if (put.ring)
			(void)erx_irq_trigger(doorbell);
		return (ERX_OK);
	case ERX_LANE_PUT_REFUSED:
		return (ERX_ERANGE);
	case ERX_LANE_PUT_SHORT:	/* whole_put never returns it */
	case ERX_LANE_PUT_MALFORMED:
		break;
	}
	return (ERX_EDEAD);
}

void
erx_prog_channel_room(void)
{
	(void)pthread_mutex_lock(&lock);
	erx_prog_waitq_wake(&room_waiters);
	(void)pthread_mutex_unlock(&lock);
}
