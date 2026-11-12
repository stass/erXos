/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pure core of a program's start-up (liberx/program/startup.h).  One
 * pass: the generated check over the whole startup message, then a walk of
 * the struct it filled, each step reading only what the check accepted.
 */

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "liberx/program/startup.h"

_Static_assert(ERX_SIGRTMAX >= 1 &&
    ERX_SIGRTMAX <= sizeof(((erx_prog_sigset_t *)0)->bits) * CHAR_BIT,
    "a signal set holds every signal number of the ABI");

static int
refuse(erx_prog_startup_t *out, erx_prog_startup_cause_t cause)
{
	out->status = ERX_PROG_STATUS_REFUSED;
	out->cause = cause;
	return (out->status);
}

/*
 * Counts a list of texts and sums their lengths with one NUL each.  The
 * check bounds the count by the frame's bytes and the sum by the args total,
 * so neither overflows; the sum is still checked.
 */
static bool
count_argv(erx_prog_argv_iter_t it, uint32_t *count, size_t *bytes)
{
	erx_profile_text_t text;

	*count = 0;
	*bytes = 0;
	while (erx_prog_argv_next(&it, &text)) {
		if (*count == UINT32_MAX ||
		    __builtin_add_overflow(*bytes, text.len + 1, bytes))
			return (false);
		(*count)++;
	}
	return (true);
}

static bool
count_env(erx_prog_env_iter_t it, uint32_t *count, size_t *bytes)
{
	erx_profile_text_t text;

	*count = 0;
	*bytes = 0;
	while (erx_prog_env_next(&it, &text)) {
		if (*count == UINT32_MAX ||
		    __builtin_add_overflow(*bytes, text.len + 1, bytes))
			return (false);
		(*count)++;
	}
	return (true);
}

/* Reads a list of signals into a set; false on a number the set cannot hold. */
static bool
read_signals(erx_prog_signals_iter_t it, erx_prog_sigset_t *set)
{
	int32_t signo;
	uint32_t bit;

	memset(set, 0, sizeof(*set));
	while (erx_prog_signals_next(&it, &signo)) {
		if (signo < 1 || signo > ERX_SIGRTMAX)
			return (false);
		bit = (uint32_t)signo - 1;
		set->bits[bit / 64] |= UINT64_C(1) << (bit % 64);
	}
	return (true);
}

/*
 * The first descriptor liberx cannot set up, or false when every one is null
 * or a pipe's read or write end (fd.h).
 */
static bool
find_unsupported_fd(erx_prog_fds_iter_t it, uint16_t *fd)
{
	erx_prog_fd_entry_t entry;

	while (erx_prog_fds_next(&it, &entry)) {
		switch (entry.descriptor.which) {
		case ERX_PROG_DESCRIPTOR_NULL:
		case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
		case ERX_PROG_DESCRIPTOR_PIPE_READ:
			break;
		default:
			*fd = entry.fd;
			return (true);
		}
	}
	return (false);
}

int
erx_prog_startup_plan(const uint8_t *frame, size_t len, void *scratch,
    size_t scratch_len, erx_prog_startup_t *out)
{
	erx_prog_start_t start;

	memset(out, 0, sizeof(*out));
	memset(&start, 0, sizeof(start));
	if (!erx_prog_check_start(frame, len, scratch, scratch_len, &start,
	    &out->refusal))
		return (refuse(out, ERX_PROG_STARTUP_CHECK));

	if (find_unsupported_fd(start.fds, &out->fd))
		return (refuse(out, ERX_PROG_STARTUP_DESCRIPTOR));
	if (!read_signals(start.sigmask, &out->sigmask) ||
	    !read_signals(start.sigignore, &out->sigignore))
		return (refuse(out, ERX_PROG_STARTUP_BOUND));
	if (!count_argv(start.argv, &out->argc, &out->argv_bytes) ||
	    !count_env(start.env, &out->envc, &out->env_bytes))
		return (refuse(out, ERX_PROG_STARTUP_BOUND));

	/* The check bounds cwd by ERX_PROG_PATH_MAX; the copy adds its NUL. */
	if (start.cwd.len >= sizeof(out->cwd))
		return (refuse(out, ERX_PROG_STARTUP_BOUND));
	memcpy(out->cwd, start.cwd.bytes, start.cwd.len);
	out->cwd[start.cwd.len] = '\0';
	out->cwd_len = start.cwd.len;

	out->argv = start.argv;
	out->fds = start.fds;
	out->env = start.env;
	out->pid = start.pid;
	out->ppid = start.ppid;
	out->pgid = start.pgid;
	out->spawn = start.spawn;
	out->umask = start.umask;
	out->data_area = start.data_area.cap;
	out->data_slots = start.data_area.data_slots;
	out->has_image = start.has_image;
	if (start.has_image)
		out->image = start.image.u.object.cap;
	out->status = 0;
	out->cause = ERX_PROG_STARTUP_GO;
	return (out->status);
}
