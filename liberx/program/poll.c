/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * poll over the descriptor table (poll.h).  The registrations a poll keeps
 * while it waits, a counted reference to each descriptor's object and a
 * waiter on each pipe end, live on the stack for a small poll and in pages
 * of the program's own for a large one, so a poll of any size the table
 * allows takes no allocator lock and no memory of anyone else's.
 */

#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/fd.h"
#include "liberx/program/pages.h"
#include "liberx/program/pipe.h"
#include "liberx/program/poll.h"
#include "liberx/program/wake.h"

#define NS_PER_SEC	UINT64_C(1000000000)
/*
 * The events every object understands, FreeBSD's POLLSTANDARD (sys/sys/poll.h): an
 * object with no poll of its own answers POLLNVAL to any other, as poll_no_poll does
 * (sys/kern/sys_generic.c), so a program can tell an extension is missing.
 */
#define POLL_STANDARD	(POLLIN | POLLPRI | POLLOUT | POLLRDNORM | POLLRDBAND | POLLWRNORM | \
			 POLLWRBAND | POLLERR | POLLHUP | POLLNVAL)
/* Registrations a poll keeps on its stack; a larger poll takes pages. */
#define POLL_INLINE	16

/* What a poll holds of one descriptor while it waits. */
typedef struct poll_slot {
	erx_prog_obj_t		*obj;		/* NULL for a negative fd or one the table does not hold */
	erx_prog_waiter_t	 waiter;	/* on the end's list, for a pipe end */
} poll_slot_t;

int
erx_prog_poll_deadline(uint64_t now, const struct timespec *timeout, uint64_t *deadline)
{
	uint64_t ns;

	if (timeout == NULL) {
		*deadline = ERX_WAIT_FOREVER;
		return (0);
	}
	if (timeout->tv_sec < 0 || timeout->tv_nsec < 0 || (uint64_t)timeout->tv_nsec >= NS_PER_SEC)
		return (-EINVAL);
	if (__builtin_mul_overflow((uint64_t)timeout->tv_sec, NS_PER_SEC, &ns) ||
	    __builtin_add_overflow(ns, (uint64_t)timeout->tv_nsec, &ns) ||
	    __builtin_add_overflow(now, ns, deadline))
		*deadline = ERX_WAIT_FOREVER;
	return (0);
}

short
erx_prog_poll_revents(short events, short ready)
{
	short asked = events & (POLLIN | POLLRDNORM | POLLOUT | POLLWRNORM);
	short have = ready & (POLLHUP | POLLERR | POLLNVAL);

	if (ready & POLLIN)
		have |= POLLIN | POLLRDNORM;
	if (ready & POLLOUT)
		have |= POLLOUT | POLLWRNORM;
	return ((short)(have & (asked | POLLHUP | POLLERR | POLLNVAL)));
}

/* What a descriptor's object reports ready now for events, as erx_pipe_poll answers. */
static short
ready_of(const poll_slot_t *slot, int fd, short events)
{
	if (fd < 0)
		return (0);
	if (slot->obj == NULL)
		return (POLLNVAL);
	switch (slot->obj->kind) {
	case ERX_PROG_OBJ_PIPE:
		return (erx_pipe_poll(erx_pipe_end_of(slot->obj)));
	case ERX_PROG_OBJ_NULL:
	case ERX_PROG_OBJ_MEM:
		/*
		 * Null and a mem range never wait, as FreeBSD's null device and shared
		 * memory answer through poll_no_poll (sys/kern/kern_conf.c no_poll,
		 * sys/kern/uipc_shm.c invfo_poll).
		 */
		return ((events & ~POLL_STANDARD) != 0 ? POLLNVAL : (POLLIN | POLLOUT));
	}
	return (POLLNVAL);
}

/* Takes each descriptor's object, and watches each pipe end, before anything is polled. */
static void
watch_all(const struct pollfd *fds, poll_slot_t *slots, size_t nfds)
{
	for (size_t i = 0; i < nfds; i++) {
		slots[i].obj = fds[i].fd < 0 ? NULL : erx_prog_fd_get(fds[i].fd);
		if (slots[i].obj != NULL && slots[i].obj->kind == ERX_PROG_OBJ_PIPE)
			erx_pipe_watch(erx_pipe_end_of(slots[i].obj), &slots[i].waiter);
	}
}

/* Undoes watch_all: the unwatch gives up what the polls published (pipe.h). */
static void
unwatch_all(poll_slot_t *slots, size_t nfds)
{
	for (size_t i = 0; i < nfds; i++) {
		if (slots[i].obj == NULL)
			continue;
		if (slots[i].obj->kind == ERX_PROG_OBJ_PIPE)
			erx_pipe_unwatch(erx_pipe_end_of(slots[i].obj), &slots[i].waiter);
		erx_prog_obj_put(slots[i].obj);
	}
}

int
erx_prog_poll(struct pollfd *fds, size_t nfds, uint64_t deadline)
{
	poll_slot_t inline_slots[POLL_INLINE], *slots = inline_slots;
	uint64_t bytes;
	int count;

	if (nfds > ERX_PROG_FDS_MAX)
		return (-EINVAL);
	bytes = (uint64_t)nfds * sizeof(poll_slot_t);
	if (nfds > POLL_INLINE && (slots = erx_prog_pages_take(bytes)) == NULL)
		return (-ENOMEM);
	watch_all(fds, slots, nfds);
	for (;;) {
		/* Read before the polls, so a ring after any of them bumps what the sleep holds. */
		const uint32_t seen = erx_prog_wake_seen();

		count = 0;
		for (size_t i = 0; i < nfds; i++) {
			const short events = fds[i].events;

			fds[i].revents = erx_prog_poll_revents(events,
			    ready_of(&slots[i], fds[i].fd, events));
			if (fds[i].revents != 0)
				count++;
		}
		if (count > 0 || erx_clock_ns() >= deadline)
			break;
		erx_prog_wake_sleep(seen, deadline);
	}
	unwatch_all(slots, nfds);
	if (slots != inline_slots)
		erx_prog_pages_give(slots, bytes);
	return (count);
}
