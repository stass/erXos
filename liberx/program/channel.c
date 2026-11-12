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
 * The wait for room: a sender counts itself in waiters, reads the room
 * epoch, then puts armed, which publishes the room it needs, fences and
 * looks once more.  Once the session's read crosses that need it rings
 * the doorbell, the executor takes the label and bumps the epoch, so the
 * bump comes after the sender's read of it, and the sender's umtx wait on
 * the value it read returns.  The executor reads waiters after its bump,
 * and the sender counted itself before reading the epoch, so an executor
 * that finds no waiter bumped before any sender's read and owes no wake.
 * A woken sender takes the lock and puts again, so a bump that brought too
 * little room only sends it back to wait.
 *
 * The lane has one need word, and each armed put overwrites it, so it
 * holds the need of the sender that published last.  While that sender
 * waits, its need's crossing wakes every waiter.  A sender that leaves
 * the lane, its frame written or the lane broken, may be the one whose
 * need is published, and the need of a sender still waiting then stands
 * nowhere; so a sender that leaves while others wait bumps the epoch
 * itself, and each of them publishes its need again.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
/* Under lock, once erx_prog_channel_open has readied it. */
static erx_lane_writer_t outbound;
/* Set by erx_prog_channel_open before any thread sends. */
static uint64_t doorbell;
/* How many times room was announced; senders wait for it to move. */
static _Atomic uint32_t room_epoch;
/* Senders between counting themselves and the end of their wait. */
static _Atomic uint32_t waiters;

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
		uint32_t seen;

		atomic_fetch_add(&waiters, 1);
		seen = atomic_load(&room_epoch);
		status = erx_lane_put_armed(&outbound, item, put);
		if (status == ERX_LANE_PUT_SHORT) {
			(void)pthread_mutex_unlock(&lock);
			/* The open wait: the sender holds nothing of the channel's here. */
			(void)erx_umtx_wait((uint64_t)(uintptr_t)&room_epoch, seen, ERX_WAIT_FOREVER);
			(void)pthread_mutex_lock(&lock);
		}
		atomic_fetch_sub(&waiters, 1);
	}
	(void)pthread_mutex_unlock(&lock);
	/* This sender leaves: a need it published stands for none of those still waiting. */
	if (atomic_load(&waiters) != 0)
		erx_prog_channel_room();
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
	atomic_fetch_add(&room_epoch, 1);
	if (atomic_load(&waiters) != 0)
		(void)erx_umtx_wake((uint64_t)(uintptr_t)&room_epoch, UINT32_MAX);
}
