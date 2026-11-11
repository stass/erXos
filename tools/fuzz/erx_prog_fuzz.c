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
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/prog_profile.h"

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
	if (check(request, frame_start, len, offset, need - 1, &start,
	    &short_refusal) || (short_refusal.reason != ERX_PROFILE_SCRATCH &&
	    short_refusal.reason != ERX_PROFILE_SIZE))
		abort();
	return (0);
}
