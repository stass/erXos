/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * launch.h: what process 1 of each of Linux's guests (docs/design-bench.md, "Linux's
 * guest" and "Linux's Erlang guest") does the same way: waiting for the program the
 * guest exists for under a deadline, saying how it ended, and powering the machine off.
 * Private to bench/linux/init.c and bench/linux/erlang_init.c, each of which includes it
 * once.
 *
 * The wait is sigtimedwait on SIGCHLD, blocked before the first fork and given a handler
 * so the kernel keeps it pending, with the time left as its timeout: process 1 sleeps
 * until a child ends (SA_NOCLDSTOP: not when one stops) or the deadline passes. A
 * process a program leaves behind becomes process 1's child, so each SIGCHLD reaps every
 * ended child and the wait goes on until the awaited program is among them.
 */

#ifndef ERX_BENCH_LINUX_LAUNCH_H
#define ERX_BENCH_LINUX_LAUNCH_H

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <sys/reboot.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "include/erx/cdefs.h"

#ifndef ERX_INIT_DEADLINE_S
#error "the build passes the deadline its guest's builder derives"
#endif

/* The handler that makes SIGCHLD a signal process 1 keeps pending; sigtimedwait takes it. */
static void
child_ended(int number ERX_UNUSED)
{
}

/*
 * Makes SIGCHLD pending rather than delivered: *chld holds it alone, and *before the
 * mask process 1 had, which each child restores. Answers whether both took effect.
 */
static bool
catch_children(sigset_t *chld, sigset_t *before)
{
	const struct sigaction handler = { .sa_handler = child_ended, .sa_flags = SA_NOCLDSTOP };

	sigemptyset(chld);
	sigaddset(chld, SIGCHLD);
	return (sigaction(SIGCHLD, &handler, NULL) == 0 && sigprocmask(SIG_BLOCK, chld, before) == 0);
}

/* The CLOCK_MONOTONIC second; a clock that does not read ends a wait at once. */
static int64_t
monotonic_s(void)
{
	struct timespec now = { 0 };

	if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
		return (INT64_MAX);
	return ((int64_t)now.tv_sec);
}

/* Reaps every ended child; answers whether program was one, with its status in *status. */
static bool
reaped(pid_t program, int *status)
{
	bool found = false;
	pid_t child;
	int ended;

	while ((child = waitpid(-1, &ended, WNOHANG)) > 0)
		if (child == program) {
			*status = ended;
			found = true;
		}
	return (found);
}

/*
 * Waits for program, named name, until deadline, a CLOCK_MONOTONIC second, and kills it
 * there. Answers its wait status.
 */
static int
await(pid_t program, const char *name, const sigset_t *chld, int64_t deadline)
{
	int status = 0;

	while (!reaped(program, &status)) {
		const int64_t left = deadline - monotonic_s();
		struct timespec timeout = { 0 };

		if (left <= 0) {
			printf("erx: init: %s's deadline of %u s passed\n", name, ERX_INIT_DEADLINE_S);
			kill(program, SIGKILL);
			while (waitpid(program, &status, 0) < 0 && errno == EINTR)
				continue;
			break;
		}
		timeout.tv_sec = left;
		sigtimedwait(chld, NULL, &timeout);
	}
	return (status);
}

/* Says how the program named name ended unless it exited with 0. */
static void
report(const char *name, int status)
{
	if (WIFSIGNALED(status))
		printf("erx: init: %s ended by signal %d\n", name, WTERMSIG(status));
	else if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
		printf("erx: init: %s exited with %d\n", name, WEXITSTATUS(status));
}

/*
 * Drains the console and powers the machine off, so QEMU exits. Answers only when the
 * power-off was refused; process 1 then returns, and the kernel's panic=-1 ends the boot.
 */
static void
power_off(void)
{
	fflush(stdout);
	tcdrain(STDOUT_FILENO);
	sync();
	reboot(RB_POWER_OFF);
	printf("erx: init: the power-off was refused\n");
}

#endif /* !ERX_BENCH_LINUX_LAUNCH_H */
