/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The lock page's checks (liberx/erx_pipe_check.c) over hostile co-readers.
 * The input is what the reader found in its own lanes (whether cur's lane
 * is one it holds, whether a sound record starts at that lane's rpos, the
 * rpos and the record's length), then the bytes of the lock page, from
 * which the harness copies each word once through erx_shm_copy.  The
 * holder index must name a read end, and the settle row must be the first
 * of docs/design-pipes.md's table that matches the copies.
 */

#include <stdalign.h>
#include <stdatomic.h>
#include <stdbool.h>
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
	erx_pipe_cur_copy_t copy;
	erx_pipe_owner_t owned;
	erx_pipe_settle_t row;
	uint64_t waiters;
	uint32_t owner, wends, index;
	bool matches;

	if (size < 1)
		return (0);
	copy.held = (data[0] & 1) != 0;
	copy.record_sound = (data[0] & 2) != 0;
	data++;
	size--;
	copy.rpos = take_u64(&data, &size);
	copy.len = (uint32_t)take_u64(&data, &size);
	memset((void *)page, 0, sizeof(page));
	memcpy((void *)page, data, size < sizeof(page) ? size : sizeof(page));

	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_OWNER, &owner,
	    sizeof(owner));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_WENDS, &wends,
	    sizeof(wends));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_WAITERS, &waiters,
	    sizeof(waiters));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_CUR, &copy.cur,
	    sizeof(copy.cur));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_CUR_OFF,
	    &copy.cur_off, sizeof(copy.cur_off));
	erx_shm_copy(page, ERX_PAGE_SIZE, ERX_PIPE_LOCK_OFF_CUR_POS,
	    &copy.cur_pos, sizeof(copy.cur_pos));
	(void)wends;
	(void)waiters;

	index = UINT32_MAX;
	owned = erx_pipe_owner_check(owner, &index);
	check((owned == ERX_PIPE_OWNER_FREE) == (owner == 0));
	if (owned == ERX_PIPE_OWNER_HELD)
		check(index < ERX_PIPE_READERS_MAX && index + 1 == owner);
	else
		check(index == UINT32_MAX);
	if (owned == ERX_PIPE_OWNER_BROKEN)
		check(owner > ERX_PIPE_READERS_MAX);

	row = erx_pipe_settle(&copy);
	matches = copy.cur != ERX_PIPE_NONE && copy.held;
	switch (row) {
	case ERX_PIPE_SETTLE_CONTINUE:
		check(matches && copy.record_sound && copy.rpos == copy.cur_pos &&
		    copy.cur_off < copy.len);
		break;
	case ERX_PIPE_SETTLE_RETIRE:
		check(matches && copy.record_sound && copy.rpos == copy.cur_pos &&
		    copy.cur_off == copy.len);
		break;
	case ERX_PIPE_SETTLE_FINISHED:
		check(matches && copy.rpos > copy.cur_pos);
		break;
	case ERX_PIPE_SETTLE_NONE:
		check(!matches || (copy.rpos == copy.cur_pos ?
		    !copy.record_sound || copy.cur_off > copy.len :
		    copy.rpos < copy.cur_pos));
		break;
	default:
		check(false);
	}
	return (0);
}
