/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Hosted mode's console device (docs/design-runtime.md, "The console and standard I/O"),
 * and the one source in the runtime that touches a host file descriptor for it. A reader
 * thread blocks in poll on standard input and on a pipe that SIGWINCH writes to, gathers
 * what it finds in a buffer and triggers a software IRQ object bound to the group. The
 * label's sink is the erx_stdio process, so input travels a device interrupt's path and
 * every executor can park while the terminal is idle.
 *
 * A terminal on standard input is raw, as cfmakeraw sets it, from start_nif until the
 * runtime's exit path runs sys_tty_reset. A fatal signal does not take that path.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#define STATIC_ERLANG_NIF 1

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "erl_driver.h"
#include "erl_nif.h"
#include "erx_event.h"
#include "erx_stdio.h"

#define INPUT_CAPACITY	4096
#define READ_CHUNK	1024

/* What the reader gathered and erx_stdio has not taken. The lock guards it. */
static ErlNifMutex *input_lock;
static ErlNifCond *input_room;
static uint8_t input_bytes[INPUT_CAPACITY];
static size_t input_used;
static bool input_ended;
static int input_error;
static bool input_resized;

static bool started;
static uint64_t input_irq;
static int winch_pipe[2];

static bool stdin_is_terminal;
static struct termios initial_mode;

static void
terminal_restore(void)
{
	if (stdin_is_terminal)
		(void)tcsetattr(STDIN_FILENO, TCSANOW, &initial_mode);
}

static void
winch_handler(int signal_number)
{
	const int saved_errno = errno;

	(void)signal_number;
	(void)!write(winch_pipe[1], "", 1);
	errno = saved_errno;
}

/* The object lives as long as the process, so a trigger cannot fail on a good handle. */
static void
input_publish(void)
{
	(void)erx_irq_trigger(input_irq);
}

static void
input_end(int error)
{
	enif_mutex_lock(input_lock);
	input_ended = true;
	input_error = error;
	enif_mutex_unlock(input_lock);
	input_publish();
}

/* Waits for room and returns how much a read may take. Only this thread adds bytes. */
static size_t
input_wait_for_room(void)
{
	size_t room;

	enif_mutex_lock(input_lock);
	while (input_used == INPUT_CAPACITY)
		enif_cond_wait(input_room, input_lock);
	room = INPUT_CAPACITY - input_used;
	enif_mutex_unlock(input_lock);
	return (room < READ_CHUNK ? room : READ_CHUNK);
}

/* False once standard input has ended. */
static bool
input_read(void)
{
	uint8_t chunk[READ_CHUNK];
	const size_t room = input_wait_for_room();
	const ssize_t got = read(STDIN_FILENO, chunk, room);

	if (got < 0 && (errno == EINTR || errno == EAGAIN))
		return (true);
	if (got <= 0) {
		input_end(got == 0 ? 0 : errno);
		return (false);
	}
	enif_mutex_lock(input_lock);
	memcpy(input_bytes + input_used, chunk, (size_t)got);
	input_used += (size_t)got;
	enif_mutex_unlock(input_lock);
	input_publish();
	return (true);
}

static void
input_note_resize(void)
{
	uint8_t drained[16];

	(void)!read(winch_pipe[0], drained, sizeof(drained));
	enif_mutex_lock(input_lock);
	input_resized = true;
	enif_mutex_unlock(input_lock);
	input_publish();
}

static void *
reader_thread(void *arg)
{
	struct pollfd watched[2] = {
		{ .fd = STDIN_FILENO, .events = POLLIN },
		{ .fd = winch_pipe[0], .events = POLLIN },
	};

	(void)arg;
	for (;;) {
		if (poll(watched, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			input_end(errno);
			return (NULL);
		}
		if (watched[1].revents != 0)
			input_note_resize();
		if (watched[0].revents != 0 && !input_read())
			return (NULL);
	}
}

static ERL_NIF_TERM
make_error(ErlNifEnv *env, const char *step, int error)
{
	return (enif_make_tuple2(env, enif_make_atom(env, "error"),
	    enif_make_tuple2(env, enif_make_atom(env, step), enif_make_atom(env, erl_errno_id(error)))));
}

static ERL_NIF_TERM
window_size_term(ErlNifEnv *env)
{
	struct winsize size;

	/* A pty nobody has sized reports zero, which is no size at all. */
	if ((ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0 && ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0)
	    || size.ws_col == 0 || size.ws_row == 0)
		return (enif_make_atom(env, "unchanged"));
	return (enif_make_tuple2(env, enif_make_uint(env, size.ws_col), enif_make_uint(env, size.ws_row)));
}

static int
irq_start(const ErlNifPid *owner, ErlNifEnv *env)
{
	uint32_t label;
	int status = erx_event_register_process(owner, enif_make_atom(env, "erx_stdio_ready"), &label);

	if (status == ERX_OK)
		status = erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &input_irq);
	if (status == ERX_OK)
		status = erx_irq_bind(input_irq, ERX_CAP_SELF, label);
	return (status);
}

static int
winch_start(void)
{
	struct sigaction action;

	memset(&action, 0, sizeof(action));
	action.sa_handler = winch_handler;
	action.sa_flags = SA_RESTART;
	if (pipe(winch_pipe) != 0
	    || fcntl(winch_pipe[0], F_SETFL, O_NONBLOCK) != 0
	    || fcntl(winch_pipe[1], F_SETFL, O_NONBLOCK) != 0
	    || sigaction(SIGWINCH, &action, NULL) != 0)
		return (errno);
	return (0);
}

static int
terminal_start(void)
{
	struct termios raw;

	if (tcgetattr(STDIN_FILENO, &initial_mode) != 0)
		return (0);	/* Not a terminal: nothing to set or restore. */
	raw = initial_mode;
	cfmakeraw(&raw);
	if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0)
		return (errno);
	stdin_is_terminal = true;
	erx_sys_set_tty_reset(terminal_restore);
	return (0);
}

/* Called once, from the process that will take the input. {ok, IsTerminal}, or {error, {Step, Reason}}. */
static ERL_NIF_TERM
start_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifPid self;
	ErlNifTid tid;
	int error;

	(void)argc;
	(void)argv;
	if (started || enif_self(env, &self) == NULL)
		return (enif_make_badarg(env));
	input_lock = enif_mutex_create("erx_stdio_input");
	input_room = enif_cond_create("erx_stdio_room");
	if (input_lock == NULL || input_room == NULL)
		return (make_error(env, "lock", ENOMEM));
	if (irq_start(&self, env) != ERX_OK)
		return (make_error(env, "irq", EAGAIN));
	if ((error = winch_start()) != 0)
		return (make_error(env, "window_signal", error));
	if ((error = terminal_start()) != 0)
		return (make_error(env, "terminal", error));
	if ((error = enif_thread_create("erx_stdio_reader", &tid, reader_thread, NULL, NULL)) != 0)
		return (make_error(env, "reader", error));
	started = true;
	input_note_resize();
	return (enif_make_tuple2(env, enif_make_atom(env, "ok"),
	    enif_make_atom(env, stdin_is_terminal ? "true" : "false")));
}

/* {Bytes, unchanged | {Columns, Rows}, none | eof | {error, Reason}} */
static ERL_NIF_TERM
take_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ERL_NIF_TERM bytes;
	ERL_NIF_TERM end = enif_make_atom(env, "none");
	bool resized;
	uint8_t *copy;

	(void)argc;
	(void)argv;
	enif_mutex_lock(input_lock);
	copy = enif_make_new_binary(env, input_used, &bytes);
	memcpy(copy, input_bytes, input_used);
	input_used = 0;
	resized = input_resized;
	input_resized = false;
	if (input_ended) {
		input_ended = false;
		end = input_error == 0 ? enif_make_atom(env, "eof") :
		    enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, erl_errno_id(input_error)));
	}
	enif_cond_signal(input_room);
	enif_mutex_unlock(input_lock);
	return (enif_make_tuple3(env, bytes,
	    resized ? window_size_term(env) : enif_make_atom(env, "unchanged"), end));
}

/* ok, or {error, {write, Reason}}. Runs on a dirty I/O scheduler: a terminal can make it wait. */
static ERL_NIF_TERM
write_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifBinary bytes;
	size_t written = 0;

	(void)argc;
	if (!enif_inspect_iolist_as_binary(env, argv[0], &bytes))
		return (enif_make_badarg(env));
	while (written < bytes.size) {
		const ssize_t wrote = write(STDOUT_FILENO, bytes.data + written, bytes.size - written);

		if (wrote >= 0) {
			written += (size_t)wrote;
		} else if (errno == EAGAIN) {
			struct pollfd out = { .fd = STDOUT_FILENO, .events = POLLOUT };

			(void)poll(&out, 1, -1);
		} else if (errno != EINTR) {
			return (make_error(env, "write", errno));
		}
	}
	return (enif_make_atom(env, "ok"));
}

static ErlNifFunc nif_funcs[] = {
	{ "start_nif", 0, start_nif, 0 },
	{ "take_nif", 0, take_nif, 0 },
	{ "write_nif", 1, write_nif, ERL_NIF_DIRTY_JOB_IO_BOUND },
};

ERL_NIF_INIT(erx_stdio, nif_funcs, NULL, NULL, NULL, NULL)
