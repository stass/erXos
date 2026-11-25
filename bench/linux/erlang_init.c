/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erlang_init: process 1 of Linux's Erlang guest (docs/design-bench.md, "Linux's Erlang
 * guest"), which sets stock OTP's two nodes beside erXos's xdomain cells. It mounts /proc
 * and /sys, brings the loopback interface up, starts epmd on the loopback and waits until
 * it accepts a connection, then starts the echo node and the client node, each by
 * executing erlexec with the environment the erl script would give it, since the guest has
 * no shell. It waits for the client under its deadline, ERX_INIT_DEADLINE_S, says how the
 * client ended unless it exited with 0, prints the end line the host waits for and powers
 * the machine off (launch.h).
 *
 * The console carries only the client's lines and init's own: epmd's and the echo node's
 * output go to /dev/null. The client's one argument, the benchmark's guest modules and
 * their arguments as an Erlang term (XdomainBench.guests), is what the kernel hands init
 * from after "--" on its command line, followed by the number of ERTS schedulers each
 * node runs (+S). Where the build puts the export's ERTS, the
 * bench modules' directory and, for the seeded fault, the echo node's other cookie, come
 * from tools/lib/erx/linux_erlang_guest.rb.
 */

#define _DEFAULT_SOURCE

#include <fcntl.h>
#include <string.h>

#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>

#include "launch.h"

#if !defined(ERX_INIT_ROOTDIR) || !defined(ERX_INIT_BINDIR) || !defined(ERX_INIT_BEAMS) || \
    !defined(ERX_INIT_BOOT)
#error "the build passes the export's directories, its boot's name and the bench modules' directory"
#endif

#define CLIENT		"bench_client"
#define EPMD_PORT	4369
#define EPMD_POLL_NS	10000000L
#define EPMD_WAIT_S	10
#define EXEC_FAILED	127
#define EVAL_MAX	1024
#define SCHEDULERS_MAX	3
/* The guest has no network device, so the cookie guards nothing but the seeded fault. */
#define COOKIE		"erx_bench"
#ifdef ERX_INIT_SEED_ECHO_COOKIE
#define ECHO_COOKIE	"erx_bench_seeded"
#else
#define ECHO_COOKIE	COOKIE
#endif

/* What the erl script would set before it executes erlexec, and nothing else. */
static char *environment[] = {
	"ROOTDIR=" ERX_INIT_ROOTDIR, "BINDIR=" ERX_INIT_BINDIR, "EMU=beam", "PROGNAME=erl", NULL
};

/* Brings lo up; the kernel gives it 127.0.0.1 (unverified). Answers whether it is up. */
static bool
loopback_up(void)
{
	struct ifreq request = { 0 };
	bool up;
	int s;

	if ((s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)) < 0)
		return (false);
	strlcpy(request.ifr_name, "lo", sizeof(request.ifr_name));
	up = ioctl(s, SIOCGIFFLAGS, &request) == 0;
	request.ifr_flags |= IFF_UP;
	up = up && ioctl(s, SIOCSIFFLAGS, &request) == 0;
	close(s);
	return (up);
}

/* Answers whether epmd accepts a connection on the loopback. */
static bool
epmd_answers(void)
{
	struct sockaddr_in epmd = { .sin_family = AF_INET, .sin_port = htons(EPMD_PORT),
				    .sin_addr = { .s_addr = htonl(INADDR_LOOPBACK) } };
	bool answered;
	int s;

	if ((s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)) < 0)
		return (false);
	answered = connect(s, (const struct sockaddr *)&epmd, sizeof(epmd)) == 0;
	close(s);
	return (answered);
}

/*
 * Starts argv[0] with argv and the erl environment, the signal mask init was given,
 * before, and, when quiet, its output on /dev/null. A program that does not run says so
 * on the console, through a descriptor its exec would have closed. Answers its pid, or -1.
 */
static pid_t
spawn(char *const argv[], bool quiet, const sigset_t *before)
{
	pid_t child;
	int console, null;

	fflush(stdout);
	if ((child = fork()) != 0)
		return (child);
	sigprocmask(SIG_SETMASK, before, NULL);
	if ((console = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 0)) < 0)
		_exit(EXEC_FAILED);
	if (quiet && ((null = open("/dev/null", O_WRONLY | O_CLOEXEC)) < 0 || dup2(null, STDOUT_FILENO) < 0 ||
	    dup2(null, STDERR_FILENO) < 0))
		_exit(EXEC_FAILED);
	execve(argv[0], argv, environment);
	dprintf(console, "erx: init: %s did not run: %s\n", argv[0], strerror(errno));
	_exit(EXEC_FAILED);
}

/* Waits until the epmd started as pid epmd answers, for at most EPMD_WAIT_S and while it runs. */
static bool
epmd_ready(pid_t epmd)
{
	const struct timespec poll = { .tv_nsec = EPMD_POLL_NS };
	const int64_t deadline = monotonic_s() + EPMD_WAIT_S;

	while (!epmd_answers()) {
		int status;

		if (waitpid(epmd, &status, WNOHANG) == epmd) {
			report("epmd", status);
			return (false);
		}
		if (monotonic_s() >= deadline)
			return (false);
		nanosleep(&poll, NULL);
	}
	return (true);
}

/*
 * A node's command line: its schedulers, name on the loopback alone with cookie, the
 * epmd init started, the bench modules on its path, and eval.
 */
#define NODE(name, cookie, eval) {						\
	ERX_INIT_BINDIR "/erlexec", "+S", schedulers, "-noshell", "-boot", ERX_INIT_BOOT,	\
	"-name", name "@127.0.0.1", "-setcookie", cookie, "-start_epmd", "false",	\
	"-kernel", "inet_dist_use_interface", "{127,0,0,1}", "-pa", ERX_INIT_BEAMS,	\
	"-eval", eval, NULL }

/*
 * Starts epmd, the echo node and the client with guests, the nodes with count schedulers
 * each; answers the client's pid.
 */
static pid_t
start(char *guests, const char *count, const sigset_t *before)
{
	static char eval[EVAL_MAX], schedulers[2 * SCHEDULERS_MAX + 2];
	char *const epmd[] = { ERX_INIT_BINDIR "/epmd", "-address", "127.0.0.1", NULL };
	char *const echo[] = NODE("bench_echo", ECHO_COOKIE, "erx_xdomain_bench:serve(erx_xdomain_echo)");
	char *const client[] = NODE(CLIENT, COOKIE, eval);
	const int length = snprintf(eval, sizeof(eval), "erx_bench_hist:main(%s)", guests);
	const size_t digits = strspn(count, "0123456789");
	pid_t listener;

	if (digits == 0 || digits > SCHEDULERS_MAX || count[digits] != '\0' || count[0] == '0') {
		printf("erx: init: the scheduler count is not a positive number of at most %d digits\n", SCHEDULERS_MAX);
		return (-1);
	}
	snprintf(schedulers, sizeof(schedulers), "%s:%s", count, count);
	if (length < 0 || (size_t)length >= sizeof(eval)) {
		printf("erx: init: the guests' term does not fit the client's %d-byte -eval\n", EVAL_MAX);
		return (-1);
	}
	if ((listener = spawn(epmd, true, before)) < 0) {
		printf("erx: init: epmd could not be started\n");
		return (-1);
	}
	if (!epmd_ready(listener)) {
		printf("erx: init: epmd did not answer\n");
		return (-1);
	}
	if (spawn(echo, true, before) < 0) {
		printf("erx: init: the echo node could not be started\n");
		return (-1);
	}
	return (spawn(client, false, before));
}

/* Starts the nodes and waits for the client under the deadline; reports its end. */
static void
run(char *guests, const char *count)
{
	const int64_t deadline = monotonic_s() + ERX_INIT_DEADLINE_S;
	sigset_t chld, before;
	pid_t client;

	if (!catch_children(&chld, &before)) {
		printf("erx: init: SIGCHLD could not be caught\n");
		return;
	}
	if ((client = start(guests, count, &before)) < 0)
		return;
	report(CLIENT, await(client, CLIENT, &chld, deadline));
}

int
main(int argc, char **argv)
{
	if (argc != 3)
		printf("erx: init: expected the guests' term and the scheduler count, got %d arguments\n", argc - 1);
	else if (mount("proc", "/proc", "proc", 0, NULL) != 0 || mount("sysfs", "/sys", "sysfs", 0, NULL) != 0)
		printf("erx: init: /proc or /sys did not mount: %s\n", strerror(errno));
	else if (!loopback_up())
		printf("erx: init: the loopback interface did not come up: %s\n", strerror(errno));
	else
		run(argv[1], argv[2]);
	printf("erx: bench: done\n");
	power_off();
	return (1);
}
