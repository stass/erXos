/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * liberx's erx_prog check over hostile frames (docs/design-abi.md#program-protocol).
 * The first input byte chooses the frame: bit 0 clear a start frame, set a
 * request frame; bits 1-3 the scratch's offset from an aligned address.
 * The rest is the frame's bytes.
 *
 * For every input the harness checks the frame twice: with all the scratch
 * erx_prog_scratch_bytes promises, at the chosen offset, which never refuses
 * for scratch, and with one byte less, which refuses for scratch before it
 * walks the frame, or for size, which the check tests first.  A refusal
 * names a reason, a kind and an offset within the frame.  An accepted start
 * frame is read through every accessor: each list's iterator yields exactly
 * the elements its view counts and then stops, and every text lies within
 * the frame.
 *
 * The start-up plan of liberx/program/startup.h runs on every start frame
 * and must agree with the check: a refused frame is refused with status 127
 * for the check's own refusal; an accepted one runs unless a descriptor
 * other than null refuses it at that descriptor's fd; and a plan that runs
 * keeps only views inside the frame, counts and sums its texts as those
 * views hold them, copies cwd whole with its NUL and carries every scalar.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/prog_profile.h"
#include "liberx/program/startup.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const uint8_t *frame_start;
static size_t frame_len;

static void
check_text(erx_profile_text_t t)
{
	if (t.len > frame_len || t.bytes < frame_start ||
	    (size_t)(t.bytes - frame_start) > frame_len - t.len)
		abort();
}

/* An iterator that left elements remain in has read them all and stops. */
static void
check_end(uint32_t left, uint32_t read, bool more)
{
	if (more || read != left)
		abort();
}

static void
read_argv(erx_prog_argv_iter_t it)
{
	erx_profile_text_t t;
	uint32_t left, n;
	bool more;

	left = it.view.left;
	for (n = 0; (more = erx_prog_argv_next(&it, &t)) && n < left; n++)
		check_text(t);
	check_end(left, n, more);
}

static void
read_env(erx_prog_env_iter_t it)
{
	erx_profile_text_t t;
	uint32_t left, n;
	bool more;

	left = it.view.left;
	for (n = 0; (more = erx_prog_env_next(&it, &t)) && n < left; n++)
		check_text(t);
	check_end(left, n, more);
}

static void
read_signals(erx_prog_signals_iter_t it)
{
	int32_t number;
	uint32_t left, n;
	bool more;

	left = it.view.left;
	for (n = 0; (more = erx_prog_signals_next(&it, &number)) && n < left;
	    n++)
		;
	check_end(left, n, more);
}

static void
read_write_readers(erx_prog_write_readers_iter_t it)
{
	erx_prog_reader_t r;
	uint32_t left, n;
	bool more;

	left = it.view.left;
	for (n = 0; (more = erx_prog_write_readers_next(&it, &r)) && n < left;
	    n++)
		;
	check_end(left, n, more);
}

static void
read_read_readers(erx_prog_read_readers_iter_t it)
{
	erx_prog_reader_t r;
	uint32_t left, n;
	bool more;

	left = it.view.left;
	for (n = 0; (more = erx_prog_read_readers_next(&it, &r)) && n < left;
	    n++)
		;
	check_end(left, n, more);
}

static void
read_read_end(const erx_prog_read_end_t *e)
{
	erx_prog_writers_iter_t it;
	erx_prog_writer_t w;
	uint32_t left, n;
	bool more;

	it = e->writers;
	left = it.view.left;
	for (n = 0; (more = erx_prog_writers_next(&it, &w)) && n < left; n++)
		;
	check_end(left, n, more);
	read_read_readers(e->readers);
}

static void
read_descriptor(const erx_prog_descriptor_t *d)
{
	switch (d->which) {
	case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
		read_write_readers(d->u.pipe_write.write_end.readers);
		break;
	case ERX_PROG_DESCRIPTOR_PIPE_READ:
		read_read_end(&d->u.pipe_read.read_end);
		break;
	case ERX_PROG_DESCRIPTOR_SOCKETPAIR:
		read_read_end(&d->u.socketpair.read_end);
		read_write_readers(d->u.socketpair.write_end.readers);
		break;
	default:
		break;
	}
}

static void
read_start(const erx_prog_start_t *s)
{
	erx_prog_fds_iter_t it;
	erx_prog_fd_entry_t entry;
	uint32_t left, n;
	bool more;

	read_argv(s->argv);
	read_env(s->env);
	check_text(s->cwd);
	read_signals(s->sigmask);
	read_signals(s->sigignore);
	it = s->fds;
	left = it.view.left;
	for (n = 0; (more = erx_prog_fds_next(&it, &entry)) && n < left; n++)
		read_descriptor(&entry.descriptor);
	check_end(left, n, more);
}

/* The bytes a list of texts needs as C strings, each read inside the frame. */
static size_t
argv_bytes(erx_prog_argv_iter_t it)
{
	erx_profile_text_t t;
	size_t sum;

	read_argv(it);
	for (sum = 0; erx_prog_argv_next(&it, &t); sum += t.len + 1)
		;
	return (sum);
}

static size_t
env_bytes(erx_prog_env_iter_t it)
{
	erx_profile_text_t t;
	size_t sum;

	read_env(it);
	for (sum = 0; erx_prog_env_next(&it, &t); sum += t.len + 1)
		;
	return (sum);
}

/* The fd of the first descriptor other than null, or -1 when all are null. */
static int
first_unsupported_fd(erx_prog_fds_iter_t it)
{
	erx_prog_fd_entry_t entry;

	while (erx_prog_fds_next(&it, &entry))
		if (entry.descriptor.which != ERX_PROG_DESCRIPTOR_NULL)
			return (entry.fd);
	return (-1);
}

/* The set a list of signals holds, bit N - 1 for signal N. */
static erx_prog_sigset_t
signal_set(erx_prog_signals_iter_t it)
{
	erx_prog_sigset_t set;
	int32_t signo;

	memset(&set, 0, sizeof(set));
	while (erx_prog_signals_next(&it, &signo)) {
		if (signo < 1 || signo > ERX_SIGRTMAX)
			abort();
		set.bits[(signo - 1) / 64] |= UINT64_C(1) << ((signo - 1) % 64);
	}
	return (set);
}

static bool
same_set(erx_prog_sigset_t a, erx_prog_sigset_t b)
{
	return (a.bits[0] == b.bits[0] && a.bits[1] == b.bits[1]);
}

/* A plan that runs agrees with the check's struct s field by field. */
static void
check_go(const erx_prog_startup_t *p, const erx_prog_start_t *s)
{
	if (p->status != 0 || first_unsupported_fd(s->fds) != -1 ||
	    p->argc != s->argv.view.left || p->envc != s->env.view.left ||
	    p->argv_bytes != argv_bytes(p->argv) ||
	    p->env_bytes != env_bytes(p->env) ||
	    p->argv_bytes + p->env_bytes > ERX_PROG_ARGS_MAX ||
	    p->cwd_len != s->cwd.len || p->cwd[p->cwd_len] != '\0' ||
	    memcmp(p->cwd, s->cwd.bytes, p->cwd_len) != 0 ||
	    p->pid != s->pid || p->ppid != s->ppid || p->pgid != s->pgid ||
	    p->fds.view.left != s->fds.view.left ||
	    first_unsupported_fd(p->fds) != -1 ||
	    !same_set(p->sigmask, signal_set(s->sigmask)) ||
	    !same_set(p->sigignore, signal_set(s->sigignore)) ||
	    p->spawn != s->spawn || p->umask != s->umask ||
	    p->data_area != s->data_area.cap ||
	    p->data_slots != s->data_area.data_slots ||
	    p->has_image != s->has_image ||
	    (s->has_image && p->image != s->image.u.object.cap))
		abort();
}

/*
 * The start-up plan of the frame the check judged, with need bytes of
 * scratch: accepted says whether the check accepted it, and s and refusal
 * are what the check gave.
 */
static void
plan_start(const uint8_t *frame, size_t len, size_t need, bool accepted,
    const erx_prog_start_t *s, const erx_profile_refusal_t *refusal)
{
	static erx_prog_startup_t p;
	uint8_t *scratch;

	scratch = malloc(need == 0 ? 1 : need);
	if (scratch == NULL)
		abort();
	(void)erx_prog_startup_plan(frame, len, scratch, need, &p);
	free(scratch);
	if (!accepted) {
		if (p.status != ERX_PROG_STATUS_REFUSED ||
		    p.cause != ERX_PROG_STARTUP_CHECK ||
		    p.refusal.reason != refusal->reason ||
		    p.refusal.kind != refusal->kind ||
		    p.refusal.offset != refusal->offset)
			abort();
		return;
	}
	switch (p.cause) {
	case ERX_PROG_STARTUP_GO:
		check_go(&p, s);
		return;
	case ERX_PROG_STARTUP_DESCRIPTOR:
		if (p.status != ERX_PROG_STATUS_REFUSED ||
		    first_unsupported_fd(s->fds) != p.fd)
			abort();
		return;
	case ERX_PROG_STARTUP_CHECK:
	case ERX_PROG_STARTUP_BOUND:
		break;
	}
	abort();
}

/*
 * The check's answer with scratch_len bytes of scratch at offset bytes into a
 * buffer that ends where the scratch does.
 */
static bool
check(bool request, const uint8_t *frame, size_t len, size_t offset,
    size_t scratch_len, erx_prog_start_t *start, erx_profile_refusal_t *refusal)
{
	uint16_t operation;
	uint8_t slot;
	uint8_t *scratch;
	bool ok;

	scratch = malloc(offset + scratch_len);
	if (scratch == NULL)
		abort();
	if (request)
		ok = erx_prog_check_request(frame, len, scratch + offset, scratch_len,
		    &slot, &operation, refusal);
	else
		ok = erx_prog_check_start(frame, len, scratch + offset, scratch_len,
		    start, refusal);
	free(scratch);
	if (!ok && (refusal->offset > len ||
	    erx_profile_reason_name(refusal->reason) == NULL ||
	    erx_prog_kind_name(refusal->kind) == NULL))
		abort();
	return (ok);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_profile_refusal_t full_refusal, short_refusal;
	erx_prog_start_t start;
	size_t need, len, offset;
	bool request, full;

	if (size < 1)
		return (0);
	request = (data[0] & 1) != 0;
	offset = (data[0] >> 1) & 7;
	frame_start = data + 1;
	frame_len = len = size - 1;
	need = erx_prog_scratch_bytes(len);
	if (need == SIZE_MAX)
		abort();
	full = check(request, frame_start, len, offset, need, &start,
	    &full_refusal);
	if (!full && full_refusal.reason == ERX_PROFILE_SCRATCH)
		abort();
	if (full && !request)
		read_start(&start);
	if (!request)
		plan_start(frame_start, len, need, full, &start, &full_refusal);
	if (check(request, frame_start, len, offset, need - 1, &start,
	    &short_refusal) || (short_refusal.reason != ERX_PROFILE_SCRATCH &&
	    short_refusal.reason != ERX_PROFILE_SIZE))
		abort();
	return (0);
}
