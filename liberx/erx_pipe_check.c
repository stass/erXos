/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe's checks of the copies its ends take from shared pages
 * (docs/design-pipes.md, "The ring" and "The lock page").  Pure functions:
 * they read no page and no global state, and every sum over a copied value
 * is bounded before it is formed, so any value another holder writes gives
 * an answer, never undefined behaviour.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pipe.h"

/*
 * Positions and the data area are multiples of a record header, so a
 * header never straddles the area's end.
 */
#define PIPE_GRAIN	((uint64_t)ERX_LANE_REC_SIZE)

_Static_assert((PIPE_GRAIN & (PIPE_GRAIN - 1)) == 0,
    "positions are aligned by masking with the grain");
_Static_assert(ERX_PIPE_RING_FIRST % PIPE_GRAIN == 0 &&
    ERX_PIPE_RING_NEXT % PIPE_GRAIN == 0, "a ring is whole grains");
_Static_assert(PIPE_GRAIN + ERX_PIPE_BUF <= ERX_PIPE_RING_NEXT,
    "the longest record fits the smallest ring");
_Static_assert(ERX_PIPE_CONTROL_MAX % ERX_PIPE_TICKET == 0,
    "a control record holds whole tickets");
_Static_assert(ERX_PIPE_READERS_MAX <= 64,
    "one bit per read end in a 64-bit word");
_Static_assert(ERX_PIPE_RIX_MAX == ERX_PIPE_READERS_MAX - 1,
    "a read end's largest index is one below the read ends a pipe may have");

static bool pipe_aligned(uint64_t);
static bool pipe_len_sound(uint32_t, uint32_t);

static bool
pipe_aligned(uint64_t pos)
{
	return ((pos & (PIPE_GRAIN - 1)) == 0);
}

/* Whether len is in the range of a record of kind, a pipe's kind. */
static bool
pipe_len_sound(uint32_t kind, uint32_t len)
{
	if (kind == ERX_REC_DATA)
		return (len >= 1 && len <= ERX_PIPE_BUF);
	return (len >= ERX_PIPE_TICKET && len <= ERX_PIPE_CONTROL_MAX &&
	    len % ERX_PIPE_TICKET == 0);
}

uint64_t
erx_ring_span(uint32_t len)
{
	return (PIPE_GRAIN + (((uint64_t)len + PIPE_GRAIN - 1) &
	    ~(PIPE_GRAIN - 1)));
}

/*
 * The positions first, so a record is looked at only between two sound
 * positions; then its kind, so its length is judged by its own kind's
 * range; then whether all of it is published.  The span of a length
 * already bounded by ERX_PIPE_BUF cannot overflow.
 */
erx_ring_fault_t
erx_ring_check(uint64_t size, const erx_ring_copy_t *copy)
{
	if (!pipe_aligned(copy->rpos) || !pipe_aligned(copy->wpos))
		return (ERX_RING_UNALIGNED);
	if (copy->wpos < copy->rpos)
		return (ERX_RING_BEHIND);
	if (copy->wpos - copy->rpos > size)
		return (ERX_RING_AHEAD);
	if (copy->wpos == copy->rpos)
		return (ERX_RING_SOUND);
	switch (copy->kind) {
	case ERX_REC_DATA:
	case ERX_REC_CONTROL:
		break;
	default:
		return (ERX_RING_KIND);
	}
	if (!pipe_len_sound(copy->kind, copy->len))
		return (ERX_RING_LENGTH);
	if (erx_ring_span(copy->len) > copy->wpos - copy->rpos)
		return (ERX_RING_UNPUBLISHED);
	return (ERX_RING_SOUND);
}

uint64_t
erx_ring_room(uint64_t size, uint64_t wpos, uint64_t rpos)
{
	if (rpos > wpos || wpos - rpos > size || !pipe_aligned(rpos))
		return (0);
	return (size - (wpos - rpos));
}

erx_pipe_owner_t
erx_pipe_owner_check(uint32_t owner, uint32_t *index)
{
	if (owner == 0)
		return (ERX_PIPE_OWNER_FREE);
	if (owner > ERX_PIPE_READERS_MAX)
		return (ERX_PIPE_OWNER_BROKEN);
	*index = owner - 1;
	return (ERX_PIPE_OWNER_HELD);
}

/*
 * The table's rows in order.  ERX_PIPE_NONE names no write end, so it never
 * matches the first three rows whatever the caller found for it.
 */
erx_pipe_settle_t
erx_pipe_settle(const erx_pipe_cur_copy_t *copy)
{
	if (copy->cur == ERX_PIPE_NONE || !copy->held)
		return (ERX_PIPE_SETTLE_NONE);
	if (copy->rpos == copy->cur_pos && copy->record_sound) {
		if (copy->cur_off < copy->len)
			return (ERX_PIPE_SETTLE_CONTINUE);
		if (copy->cur_off == copy->len)
			return (ERX_PIPE_SETTLE_RETIRE);
		return (ERX_PIPE_SETTLE_NONE);
	}
	if (copy->rpos > copy->cur_pos)
		return (ERX_PIPE_SETTLE_FINISHED);
	return (ERX_PIPE_SETTLE_NONE);
}
