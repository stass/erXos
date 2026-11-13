/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program for poll and SIGPIPE (tools/lib/erx/programs.rb), given
 * descriptor 3, a pipe write end whose pipe has no read end. argv[1] names the check:
 *
 * - poll: poll answers POLLOUT|POLLHUP for the write end, as FreeBSD's pipe_poll does
 *   once no reader remains, POLLNVAL for a descriptor the table does not hold, EINVAL for
 *   more descriptors than the table has, and 0 once a timeout of 50 ms has passed;
 * - sigign: signal(SIGPIPE, SIG_IGN) succeeds, sigaction with a handler fails with
 *   EINVAL, and the write fails with EPIPE;
 * - sigdfl: the write raises SIGPIPE under its default action, which ends the program
 *   by the signal before the write returns.
 *
 * main returns 42 when every check of its mode held, else the number of the first that
 * failed, so the case's answer names it.
 */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PIPE_FD		3
#define TIMEOUT_MS	50
#define TOO_MANY	1025	/* one past ERX_PROG_FDS_MAX */

int	main(int, char **);

static void
caught(int signo)
{
	(void)signo;
}

static int64_t
now_ms(void)
{
	struct timespec ts;

	(void)clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int
poll_checks(void)
{
	static struct pollfd many[TOO_MANY];
	struct pollfd end = { .fd = PIPE_FD, .events = POLLIN | POLLOUT };
	struct pollfd none = { .fd = 9, .events = POLLIN };
	int64_t start;

	if (poll(&end, 1, 0) != 1 || end.revents != (POLLOUT | POLLHUP))
		return (1);
	if (poll(&none, 1, 0) != 1 || none.revents != POLLNVAL)
		return (2);
	for (int i = 0; i < TOO_MANY; i++)
		many[i] = (struct pollfd){ .fd = -1 };
	if (poll(many, TOO_MANY, 0) != -1 || errno != EINVAL)
		return (3);
	start = now_ms();
	if (poll(NULL, 0, TIMEOUT_MS) != 0 || now_ms() - start < TIMEOUT_MS)
		return (4);
	return (42);
}

static int
sigign_checks(void)
{
	struct sigaction handler = { .sa_handler = caught };

	if (signal(SIGPIPE, SIG_IGN) != SIG_DFL)
		return (1);
	if (sigaction(SIGTERM, &handler, NULL) != -1 || errno != EINVAL)
		return (2);
	if (write(PIPE_FD, "x", 1) != -1 || errno != EPIPE)
		return (3);
	return (42);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "poll") == 0)
		return (poll_checks());
	if (argc == 2 && strcmp(argv[1], "sigign") == 0)
		return (sigign_checks());
	if (argc == 2 && strcmp(argv[1], "sigdfl") == 0) {
		(void)write(PIPE_FD, "x", 1);
		return (1);
	}
	return (99);
}
