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
 * exited with 0, drains the console and powers the machine off, so QEMU exits; should the
 * power-off fail, init returns, and the kernel's panic=-1 ends the boot instead.
 *
 * The wait is sigtimedwait on SIGCHLD, blocked before the fork and given a handler so the
 * kernel keeps it pending, with the time left as its timeout: init sleeps until a child
 * ends (SA_NOCLDSTOP: not when one stops) or the deadline passes. A process the program
 * leaves behind becomes init's child, so each SIGCHLD reaps every ended child and the wait
 * goes on until the program is among them.
 */

#define _XOPEN_SOURCE 700

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "include/erx/cdefs.h"

#ifndef ERX_INIT_DEADLINE_S
#error "the build passes the deadline tools/lib/erx/linux_guest.rb derives from the program's"
#endif

#define PEER		"/erx_peer_bench"
#define EXEC_FAILED	127

/* The handler that makes SIGCHLD a signal init keeps pending; sigtimedwait takes it. */
static void
child_ended(int number ERX_UNUSED)
{
}

/* The CLOCK_MONOTONIC second; a clock that does not read ends the wait at once. */
static int64_t
monotonic_s(void)
{
	struct timespec now = { 0 };

	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		return (INT64_MAX);
	return ((int64_t)now.tv_sec);
}

/* Reaps every ended child; answers whether peer was one, with its status in *status. */
static bool
reaped(pid_t peer, int *status)
{
	bool found = false;
	pid_t child;
	int ended;

	while ((child = waitpid(-1, &ended, WNOHANG)) > 0)
		if (child == peer) {
			*status = ended;
			found = true;
		}
	return (found);
}

/*
 * Waits for peer until deadline, a CLOCK_MONOTONIC second, and kills it there. Answers
 * its wait status.
 */
static int
await(pid_t peer, const sigset_t *chld, int64_t deadline)
{
	int status = 0;

	while (!reaped(peer, &status)) {
		const int64_t left = deadline - monotonic_s();
		struct timespec timeout = { 0 };

		if (left <= 0) {
			printf("erx: init: %s's deadline of %u s passed\n", PEER, ERX_INIT_DEADLINE_S);
			kill(peer, SIGKILL);
			while (waitpid(peer, &status, 0) < 0 && errno == EINTR)
				continue;
			break;
		}
		timeout.tv_sec = left;
		sigtimedwait(chld, NULL, &timeout);
	}
	return (status);
}

/* Says how the program ended unless it exited with 0. */
static void
report(int status)
{
	if (WIFSIGNALED(status))
		printf("erx: init: %s ended by signal %d\n", PEER, WTERMSIG(status));
	else if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
		printf("erx: init: %s exited with %d\n", PEER, WEXITSTATUS(status));
}

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
	const struct sigaction handler = { .sa_handler = child_ended, .sa_flags = SA_NOCLDSTOP };
	const int64_t deadline = monotonic_s() + ERX_INIT_DEADLINE_S;
	sigset_t chld, before;
	pid_t peer;

	sigemptyset(&chld);
	sigaddset(&chld, SIGCHLD);
	if (sigaction(SIGCHLD, &handler, NULL) != 0 || sigprocmask(SIG_BLOCK, &chld, &before) != 0) {
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
	report(await(peer, &chld, deadline));
}

int
main(int argc ERX_UNUSED, char **argv)
{
	if (mount("proc", "/proc", "proc", 0, NULL) == 0)
		run(argv);
	else
		printf("erx: init: /proc did not mount\n");
	fflush(stdout);
	tcdrain(STDOUT_FILENO);
	sync();
	reboot(RB_POWER_OFF);
	printf("erx: init: the power-off was refused\n");
	return (1);
}
