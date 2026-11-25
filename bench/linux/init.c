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
 *
 * Built with ERX_INIT_BOARD, it is process 1 of Linux on the Raspberry Pi 4
 * (docs/design-bench.md, "Linux on the same board"). The netboot entry appends its boot
 * name to the command line as a last word "erx.arg=NAME", which reaches init after
 * "--"; init takes it off the program's arguments and prints the naming line
 * "erx: bench: boot NAME" before the run and its end line after, as erXos's bench root
 * does, so the board's log ties the console's lines to the entry. A board is not
 * powered off, which would halt it until a person cycles its power: once the end line
 * has left the console, init restarts the board, which then boots the queue's next
 * entry, as erXos's bench boots do.
 */

#define _XOPEN_SOURCE 700

#include <string.h>

#include <sys/mount.h>

#include "launch.h"

#define PEER		"/erx_peer_bench"
#define EXEC_FAILED	127
#define BOOT_WORD	"erx.arg="

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

/*
 * Whether status is the end of a program a deadline stopped: the program's own alarm at
 * its run deadline, or init's kill at ERX_INIT_DEADLINE_S.
 */
static bool
timed_out(int status)
{
	return (WIFSIGNALED(status) &&
	    (WTERMSIG(status) == SIGALRM || WTERMSIG(status) == SIGKILL));
}

/*
 * Runs the program with argv under the deadline and reports its end. Answers whether a
 * deadline ended it.
 */
static bool
run(char **argv)
{
	int status;
	const int64_t deadline = monotonic_s() + ERX_INIT_DEADLINE_S;
	sigset_t chld, before;
	pid_t peer;

	if (!catch_children(&chld, &before)) {
		printf("erx: init: SIGCHLD could not be caught\n");
		return (false);
	}
	fflush(stdout);
	peer = fork();
	if (peer < 0) {
		printf("erx: init: %s could not be started\n", PEER);
		return (false);
	}
	if (peer == 0)
		start(argv, &before);
	status = await(peer, PEER, &chld, deadline);
	report(PEER, status);
	return (timed_out(status));
}

#ifdef ERX_INIT_BOARD
/*
 * The boot name of the last of the argc words of argv when it is the netboot entry's
 * "erx.arg=NAME", taken off argv; NULL when there is none.
 */
static const char *
boot_name(int argc, char **argv)
{
	const size_t word = sizeof(BOOT_WORD) - 1;
	char *last;

	if (argc < 2)
		return (NULL);
	last = argv[argc - 1];
	if (strncmp(last, BOOT_WORD, word) != 0)
		return (NULL);
	argv[argc - 1] = NULL;
	return (last + word);
}

/*
 * Restarts the board once what init printed has left the console, so the end line is
 * not cut off by the restart. Answers only when the restart is refused; process 1 then
 * returns, and the kernel's panic=-1 restarts the board.
 */
static void
restart(void)
{
	fflush(stdout);
	tcdrain(STDOUT_FILENO);
	sync();
	reboot(RB_AUTOBOOT);
	printf("erx: init: the restart was refused\n");
	fflush(stdout);
}
#endif

int
main(int argc ERX_UNUSED, char **argv)
{
#ifdef ERX_INIT_BOARD
	const char *name = boot_name(argc, argv);

	if (name != NULL)
		printf("erx: bench: boot %s\n", name);
#endif
	bool late = false;

	if (mount("proc", "/proc", "proc", 0, NULL) == 0)
		late = run(argv);
	else
		printf("erx: init: /proc did not mount\n");
#ifdef ERX_INIT_BOARD
	/* The end line's deadline form marks the cells the run did not report timed out. */
	if (name != NULL)
		printf("erx: bench: boot %s %s\n", name, late ? "deadline" : "done");
	restart();
#else
	power_off();
#endif
	return (1);
}
