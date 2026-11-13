/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_POLL_H
#define LIBERX_PROGRAM_POLL_H

/*
 * poll and ppoll over a program's descriptor table (docs/design-programs.md,
 * "The POSIX-lite personality", waiting on several descriptors, and
 * docs/design-pipes.md, "Readiness, poll and select").  Two pure decisions,
 * the wait's deadline and one descriptor's revents, and the wait at the
 * edge: erx_prog_poll watches every pipe end it polls before it polls any,
 * reads the thread's wake word, polls each descriptor, and sleeps on the
 * word until a doorbell or a report bumps it or the deadline passes.
 */

#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

/*
 * The deadline a ppoll timeout gives on erx_clock_ns's clock, from now:
 * none (ERX_WAIT_FOREVER) for a NULL timeout or one too far to add, else
 * now plus the timeout.  0, or -EINVAL for a timeout with a negative
 * second or a nanosecond outside [0, 1e9), as ppoll answers it.
 */
int	erx_prog_poll_deadline(uint64_t now, const struct timespec *timeout, uint64_t *deadline);

/*
 * One descriptor's revents from what its object reports ready (POLLIN,
 * POLLOUT, POLLHUP, POLLERR or POLLNVAL, as erx_pipe_poll answers them):
 * the ready bits the caller asked for in events, with each one's NORM twin
 * when asked for, and POLLHUP, POLLERR and POLLNVAL always, as POSIX says.
 */
short	erx_prog_poll_revents(short events, short ready);

/*
 * poll of nfds descriptors until one is ready or the deadline passes: the
 * count of descriptors with revents, 0 at the deadline, -EINVAL for nfds
 * past the table's size (ERX_PROG_FDS_MAX), or -ENOMEM when the pages a
 * large poll keeps its registrations in cannot be had.  A negative fd is
 * skipped with revents 0, and a descriptor the table does not hold reports
 * POLLNVAL.  fds is the caller's own memory, which it reads and writes as
 * read(2) does its buffer.
 */
int	erx_prog_poll(struct pollfd *fds, size_t nfds, uint64_t deadline);

#endif /* !LIBERX_PROGRAM_POLL_H */
