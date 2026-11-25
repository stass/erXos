/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * init: process 1 of Linux's guest in the comparison under HVF (docs/design-bench.md,
 * "Linux's guest"). It mounts /proc, which erx_peer_bench's wake handshake reads, runs
 * /erx_peer_bench with the arguments the kernel hands it from after "--" on its command
 * line, and waits for the program under a deadline of its own, ERX_INIT_DEADLINE_S, at
 * which it kills it: a backstop, since the build sets it after the program's own alarm.
 * However the program ends, by its exit, a signal or that kill, init says how unless it
 * exited with 0 and powers the machine off (launch.h).
 */

#define _XOPEN_SOURCE 700

#include <string.h>

#include <sys/mount.h>

#include "launch.h"

#define PEER		"/erx_peer_bench"
#define EXEC_FAILED	127

/*
 * The child's side: it starts the program with the signal mask init was given, before,
 * and argv[0] naming the program.
 */
static _Noreturn void
start(char **argv, const sigset_t *before)
{
	static char name[] = PEER;

	sigprocmask(SIG_SETMASK, before, NULL);
	argv[0] = name;
	execv(PEER, argv);
	printf("erx: init: %s did not run: %s\n", PEER, strerror(errno));
	fflush(stdout);
	_exit(EXEC_FAILED);
}

/* Runs the program with argv under the deadline and reports its end. */
static void
run(char **argv)
{
	const int64_t deadline = monotonic_s() + ERX_INIT_DEADLINE_S;
	sigset_t chld, before;
	pid_t peer;

	if (!catch_children(&chld, &before)) {
		printf("erx: init: SIGCHLD could not be caught\n");
		return;
	}
	fflush(stdout);
	peer = fork();
	if (peer < 0) {
		printf("erx: init: %s could not be started\n", PEER);
		return;
	}
	if (peer == 0)
		start(argv, &before);
	report(PEER, await(peer, PEER, &chld, deadline));
}

int
main(int argc ERX_UNUSED, char **argv)
{
	if (mount("proc", "/proc", "proc", 0, NULL) == 0)
		run(argv);
	else
		printf("erx: init: /proc did not mount\n");
	power_off();
	return (1);
}
