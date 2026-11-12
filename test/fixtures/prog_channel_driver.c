/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host driver of the channel's send (liberx/program/channel.h,
 * test/host/prog_channel_test.rb).  It plays the session, the outbound
 * lane's reader, over two sides in its own memory, and the backend calls
 * the send makes: erx_irq_trigger counts rings, and erx_umtx_wait and
 * erx_umtx_wake are a futex over one mutex and condition variable, which
 * count the sleeps they start.  argv[1] names one case, which prints
 * "ok CASE" and exits 0, or prints "FAIL CASE: why" and exits 1:
 *   whole	one frame is written whole, as one frame record
 *   wait	a send without room for its whole frame writes nothing and
 *		sleeps; a room bump that brought too little sends it back to
 *		sleep; the reader's freeing of the room wakes it and the frame
 *		arrives whole
 *   two	two senders' frames, of sizes up to most of the ring, arrive
 *		whole and in each sender's order, never interleaved
 *   waiters	two senders wait, the smaller frame's need published last;
 *		its crossing wakes both, the larger sender publishes its need
 *		again and sleeps, then the smaller one publishes its own, takes
 *		the room and leaves: the larger is still woken once the reader
 *		frees its room
 *   large	a frame whose record is larger than the ring is refused with
 *		ERX_ERANGE and writes nothing; one that fills the ring exactly
 *		is written
 * Every case ends within its deadline: alarm stops a driver whose send
 * never returns.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"

#define DEADLINE_S	60
#define HEADER		16	/* a frame record's header, as lane.h lays it out */
#define WAIT_FRAME	5000
#define TWO_FRAMES	300

static pthread_mutex_t futex_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t futex_cond = PTHREAD_COND_INITIALIZER;
static _Atomic uint32_t sleeps;
static _Atomic uint32_t rings;
/* A sender's pause after each wake, so a case can order two woken senders. */
static _Thread_local unsigned wake_delay_us;

static unsigned char *own_side, *peer_side;
static erx_lane_reader_t session;
static const char *running;

int
erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline)
{
	_Atomic uint32_t *const word = (_Atomic uint32_t *)(uintptr_t)addr;

	(void)deadline;
	pthread_mutex_lock(&futex_lock);
	if (atomic_load(word) == expected) {
		atomic_fetch_add(&sleeps, 1);
		while (atomic_load(word) == expected)
			pthread_cond_wait(&futex_cond, &futex_lock);
	}
	pthread_mutex_unlock(&futex_lock);
	if (wake_delay_us != 0)
		usleep(wake_delay_us);
	return (ERX_OK);
}

int
erx_umtx_wake(uint64_t addr, uint32_t count)
{
	(void)addr;
	(void)count;
	pthread_mutex_lock(&futex_lock);
	pthread_cond_broadcast(&futex_cond);
	pthread_mutex_unlock(&futex_lock);
	return (0);
}

int
erx_irq_trigger(uint64_t irq)
{
	(void)irq;
	atomic_fetch_add(&rings, 1);
	return (ERX_OK);
}

static _Noreturn void
fail(const char *why)
{
	printf("FAIL %s: %s\n", running, why);
	exit(1);
}

static void
pause_briefly(void)
{
	const struct timespec ts = { .tv_sec = 0, .tv_nsec = 200000 };

	nanosleep(&ts, NULL);
}

/* The byte at offset of the frame seq of sender: each frame's bytes say whose it is and where. */
static unsigned char
pattern(unsigned sender, unsigned seq, size_t offset)
{
	return ((unsigned char)(sender * 131 + seq * 7 + offset * 13 + (offset >> 8)));
}

static size_t
frame_fill(unsigned char *frame, unsigned sender, unsigned seq, size_t len)
{
	for (size_t at = 0; at < len; at++)
		frame[at] = pattern(sender, seq, at);
	return (len);
}

/*
 * Reads the next whole record into buf, in takes of at most chunk bytes, and
 * announces room, as the executor does on the channel's label, whenever a
 * take crosses the need a sender published. False when nothing is published.
 */
static bool
record_read(unsigned char *buf, size_t room, size_t chunk, uint32_t *len)
{
	erx_lane_part_t part;
	size_t have = 0;
	erx_lane_status_t got;

	got = erx_lane_take(&session, NULL, 0, &part);
	if (got == ERX_LANE_EMPTY)
		return (false);
	if (got != ERX_LANE_TOOK || !part.opened || part.kind != ERX_REC_FRAME || part.zero != 0 || part.len > room)
		fail("a record header that is not a frame's");
	if (part.ring)
		erx_prog_channel_room();
	*len = part.len;
	while (!part.closed) {
		const size_t want = part.len - have < chunk ? part.len - have : chunk;

		got = erx_lane_take(&session, buf + have, want, &part);
		if (got == ERX_LANE_EMPTY) {
			pause_briefly();
			continue;
		}
		if (got != ERX_LANE_TOOK || part.opened)
			fail("a record cut by another");
		have += part.copied;
		if (part.ring)
			erx_prog_channel_room();
	}
	return (true);
}

static void
check_frame(const unsigned char *buf, uint32_t len, unsigned sender, unsigned seq, size_t want)
{
	if (len != want)
		fail("a frame of the wrong length");
	for (size_t at = 0; at < len; at++) {
		if (buf[at] != pattern(sender, seq, at))
			fail("a frame's bytes are not its own");
	}
}

static int
send_one(unsigned sender, unsigned seq, size_t len)
{
	static _Thread_local unsigned char frame[ERX_PROGRAM_LANE + 1];
	const erx_lane_iov_t iov[] = {
		{ .base = frame, .len = len / 3 },
		{ .base = frame + len / 3, .len = len - len / 3 },
	};

	frame_fill(frame, sender, seq, len);
	return (erx_prog_channel_send(iov, 2));
}

static void
case_whole(void)
{
	static unsigned char buf[ERX_PROGRAM_LANE];
	uint32_t len;

	if (send_one(1, 1, 100) != ERX_OK)
		fail("the send failed");
	if (!record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("nothing was written");
	check_frame(buf, len, 1, 1, 100);
	if (record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("more than one record was written");
}

static _Atomic int wait_status = 1;
static _Atomic bool wait_done;

static void *
wait_sender(void *unused)
{
	(void)unused;
	atomic_store(&wait_status, send_one(1, 4, WAIT_FRAME));
	atomic_store(&wait_done, true);
	return (NULL);
}

static void
sleeps_reach(uint32_t count)
{
	for (unsigned tries = 0; atomic_load(&sleeps) < count; tries++) {
		if (atomic_load(&wait_done))
			fail("the send returned without room for its frame");
		if (tries == 50000)
			fail("the send never slept");
		pause_briefly();
	}
}

static void
case_wait(void)
{
	static unsigned char buf[ERX_PROGRAM_LANE];
	pthread_t sender;
	uint32_t len;

	/* Three frames leave less room than a fourth's record. */
	for (unsigned seq = 1; seq <= 3; seq++) {
		if (send_one(1, seq, WAIT_FRAME) != ERX_OK)
			fail("a send into room failed");
	}
	pthread_create(&sender, NULL, wait_sender, NULL);
	sleeps_reach(1);
	/* A bump that brought no room: the sender looks again and sleeps again. */
	erx_prog_channel_room();
	sleeps_reach(2);
	if (atomic_load(&wait_done))
		fail("the send returned after a bump that brought no room");
	/* The reader frees room in small takes and announces it only when a take crosses the need. */
	for (unsigned seq = 1; seq <= 3; seq++) {
		if (!record_read(buf, sizeof(buf), 512, &len))
			fail("a written frame is missing");
		check_frame(buf, len, 1, seq, WAIT_FRAME);
	}
	pthread_join(sender, NULL);
	if (atomic_load(&wait_status) != ERX_OK)
		fail("the woken send failed");
	if (!record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("the woken send wrote nothing");
	check_frame(buf, len, 1, 4, WAIT_FRAME);
}

#define BIG_FRAME	8000
#define SMALL_FRAME	2000

static _Atomic bool small_done;
static unsigned announced;

static void *
big_sender(void *unused)
{
	(void)unused;
	if (send_one(2, 1, BIG_FRAME) != ERX_OK)
		fail("the larger send failed");
	return (NULL);
}

static void *
small_sender(void *unused)
{
	(void)unused;
	/* Woken with the larger sender, it reaches the lock after that one has slept again. */
	wake_delay_us = 100000;
	if (send_one(3, 1, SMALL_FRAME) != ERX_OK)
		fail("the smaller send failed");
	atomic_store(&small_done, true);
	return (NULL);
}

/*
 * Takes the next part of the lane, at most 512 body bytes, into the record
 * being assembled in buf, and announces room, counting it, when the take
 * crossed a need.  The closed record's length, or 0 when none closed;
 * *empty when nothing was published.
 */
static uint32_t
part_take(unsigned char *buf, bool *empty)
{
	static size_t have;
	static uint32_t len;
	erx_lane_part_t part;
	erx_lane_status_t got;

	if (session.phase != ERX_LANE_IN_BODY)
		got = erx_lane_take(&session, NULL, 0, &part);
	else
		got = erx_lane_take(&session, buf + have, len - have < 512 ? len - have : 512, &part);
	*empty = got == ERX_LANE_EMPTY;
	if (*empty)
		return (0);
	if (got != ERX_LANE_TOOK)
		fail("the lane failed");
	if (part.ring) {
		announced++;
		erx_prog_channel_room();
	}
	if (part.opened) {
		if (part.kind != ERX_REC_FRAME || part.len > ERX_PROGRAM_LANE)
			fail("a record header that is not a frame's");
		len = part.len;
		have = 0;
	}
	have += part.copied;
	return (part.closed ? len : 0);
}

static void
case_waiters(void)
{
	static unsigned char buf[ERX_PROGRAM_LANE];
	pthread_t big, small;
	unsigned seq = 1, idle = 0;
	bool empty, big_read = false, small_read = false;

	for (unsigned at = 1; at <= 3; at++) {
		if (send_one(1, at, WAIT_FRAME) != ERX_OK)
			fail("a send into room failed");
	}
	pthread_create(&big, NULL, big_sender, NULL);
	sleeps_reach(1);
	pthread_create(&small, NULL, small_sender, NULL);
	sleeps_reach(2);
	/* Frees room only up to the first announcement, the smaller need's crossing, and lets the smaller send leave. */
	while (announced == 0) {
		(void)part_take(buf, &empty);
		if (empty)
			fail("the lane ran dry before the smaller need was crossed");
	}
	for (unsigned tries = 0; !atomic_load(&small_done); tries++) {
		if (tries == 50000)
			fail("the smaller send never finished");
		pause_briefly();
	}
	while (!big_read || !small_read) {
		const uint32_t len = part_take(buf, &empty);

		if (empty) {
			if (++idle == 10000)
				fail("a waiting sender was never woken");
			pause_briefly();
			continue;
		}
		idle = 0;
		if (len == WAIT_FRAME) {
			check_frame(buf, len, 1, seq++, WAIT_FRAME);
		} else if (len == BIG_FRAME) {
			check_frame(buf, len, 2, 1, BIG_FRAME);
			big_read = true;
		} else if (len == SMALL_FRAME) {
			check_frame(buf, len, 3, 1, SMALL_FRAME);
			small_read = true;
		} else if (len != 0) {
			fail("a frame no sender sent");
		}
	}
	pthread_join(big, NULL);
	pthread_join(small, NULL);
}

/* The size of frame seq of sender: up to three quarters of the ring, so senders often wait. */
static size_t
two_size(unsigned sender, unsigned seq)
{
	return (1 + (sender * 7919u + seq * 104729u) % (ERX_PROGRAM_LANE * 3 / 4));
}

static void *
two_sender(void *arg)
{
	const unsigned sender = (unsigned)(uintptr_t)arg;

	for (unsigned seq = 0; seq < TWO_FRAMES; seq++) {
		if (send_one(sender, seq, two_size(sender, seq)) != ERX_OK) {
			printf("FAIL two: sender %u's send %u failed\n", sender, seq);
			exit(1);
		}
	}
	return (NULL);
}

/* Whether buf holds, whole, the frame seq of sender, which the sender has not finished yet. */
static bool
frame_is(const unsigned char *buf, uint32_t len, unsigned sender, unsigned seq)
{
	if (seq >= TWO_FRAMES || len != two_size(sender, seq))
		return (false);
	for (size_t at = 0; at < len; at++) {
		if (buf[at] != pattern(sender, seq, at))
			return (false);
	}
	return (true);
}

static void
case_two(void)
{
	static unsigned char buf[ERX_PROGRAM_LANE];
	unsigned next[3] = { 0, 0, 0 };
	pthread_t senders[2];
	uint32_t len;

	for (unsigned at = 0; at < 2; at++)
		pthread_create(&senders[at], NULL, two_sender, (void *)(uintptr_t)(at + 1));
	while (next[1] < TWO_FRAMES || next[2] < TWO_FRAMES) {
		unsigned sender;

		if (!record_read(buf, sizeof(buf), 1000, &len)) {
			pause_briefly();
			continue;
		}
		if (frame_is(buf, len, 1, next[1]))
			sender = 1;
		else if (frame_is(buf, len, 2, next[2]))
			sender = 2;
		else
			fail("a frame that is neither sender's next, whole");
		next[sender]++;
	}
	for (unsigned at = 0; at < 2; at++)
		pthread_join(senders[at], NULL);
	if (record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("a frame past the senders' last");
}

static void
case_large(void)
{
	static unsigned char buf[ERX_PROGRAM_LANE];
	const size_t fits = ERX_PROGRAM_LANE - HEADER;
	uint32_t len;

	if (send_one(1, 1, fits + 1) != ERX_ERANGE)
		fail("a frame larger than the ring was not refused with ERX_ERANGE");
	if (record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("a refused frame wrote a record");
	if (send_one(1, 2, fits) != ERX_OK)
		fail("a frame that fills the ring was not written");
	if (!record_read(buf, sizeof(buf), sizeof(buf), &len))
		fail("the frame that fills the ring is missing");
	check_frame(buf, len, 1, 2, fits);
}

int
main(int argc, char **argv)
{
	static const struct {
		const char	*name;
		void		(*run)(void);
	} cases[] = {
		{ "whole", case_whole }, { "wait", case_wait }, { "waiters", case_waiters },
		{ "two", case_two }, { "large", case_large },
	};
	const uint64_t bytes = erx_lane_side_bytes(ERX_PROGRAM_LANE);

	if (argc != 2)
		return (2);
	alarm(DEADLINE_S);
	own_side = aligned_alloc(ERX_PAGE_SIZE, bytes);
	peer_side = aligned_alloc(ERX_PAGE_SIZE, bytes);
	if (own_side == NULL || peer_side == NULL)
		return (2);
	memset(own_side, 0, bytes);
	memset(peer_side, 0, bytes);
	/* The program's side holds the ring the session reads; the session's, the reader page. */
	if (!erx_prog_channel_open(own_side, peer_side, 7) ||
	    !erx_lane_reader_init(&session, own_side, peer_side, ERX_PROGRAM_LANE))
		return (2);
	for (size_t at = 0; at < sizeof(cases) / sizeof(cases[0]); at++) {
		if (strcmp(argv[1], cases[at].name) != 0)
			continue;
		running = cases[at].name;
		cases[at].run();
		printf("ok %s\n", running);
		return (0);
	}
	return (2);
}
