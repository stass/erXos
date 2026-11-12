/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The producer's check of a pipe lane's reader page
 * (liberx/erx_pipe_check.c) over hostile read ends.  The input is a size
 * selector and the write end's own wpos, then the bytes of the reader
 * page, from which the harness copies rpos, wake and sleepers through
 * erx_shm_copy, each once, as a write end does.  The room it is given must
 * never exceed the ring, and room is given only for an rpos that passes
 * docs/design-pipes.md's check; any other rpos is a full ring.
 */

#include <stdalign.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/pipe.h"
#include "erx/shm.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static alignas(8) _Atomic uint64_t page[ERX_PAGE_SIZE / 8];

static uint64_t
take_u64(const uint8_t **data, size_t *size)
{
	uint64_t value = 0;
	size_t i;

	for (i = 0; i < 8 && *size > 0; i++, (*data)++, (*size)--)
		value |= (uint64_t)**data << (8 * i);
	return (value);
}

static void
check(int held)
{
	if (!held)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint64_t ring_size, wpos, rpos, wake, sleepers, room;

	if (size < 1)
		return (0);
	ring_size = data[0] & 1 ? ERX_PIPE_RING_FIRST : ERX_PIPE_RING_NEXT;
	data++;
	size--;
	/* A write end's own position is private and always whole grains. */
	wpos = take_u64(&data, &size) & ~UINT64_C(15);
	memset((void *)page, 0, sizeof(page));
	memcpy((void *)page, data, size < sizeof(page) ? size : sizeof(page));

	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_RPAGE_OFF_RPOS, &rpos,
	    sizeof(rpos));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_RPAGE_OFF_WAKE, &wake,
	    sizeof(wake));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_RPAGE_OFF_SLEEPERS,
	    &sleepers, sizeof(sleepers));
	(void)wake;
	(void)sleepers;

	room = erx_ring_room(ring_size, wpos, rpos);
	check(room <= ring_size);
	if (room > 0)
		check(rpos % 16 == 0 && rpos <= wpos &&
		    wpos - rpos + room == ring_size);
	else
		check(rpos % 16 != 0 || rpos > wpos ||
		    wpos - rpos >= ring_size);
	return (0);
}
