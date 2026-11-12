/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PIPE_H
#define ERX_PIPE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * A pipe's checks of what its ends copy from the pages other holders write
 * (docs/design-pipes.md, "The ring" and "The lock page"), and the doorbell
 * label of a pipe end.
 *
 * Every holder of a pipe may write any value into the page it writes, so an
 * end copies each field it reads from another's page once, through
 * erx_shm_copy (erx/shm.h), and decides only on the copy.  The checks below
 * are pure functions of those copies and of the end's private state: they
 * read no page, and a violation they report never makes the end fail, only
 * stop trusting the lane (a reader marks it broken) or wait (a writer sees
 * a full ring).
 *
 * A pipe's lane carries only ERX_REC_DATA and ERX_REC_CONTROL records, so
 * erx_ring_check refuses every other kind, ERX_REC_FRAME included: no pipe
 * step ever sees a frame.
 */

/* What a consumer's check found; any fault marks the lane broken. */
typedef enum erx_ring_fault {
	ERX_RING_SOUND = 0,
	ERX_RING_UNALIGNED,	/* rpos or wpos is not a multiple of 16 */
	ERX_RING_BEHIND,	/* wpos is below rpos */
	ERX_RING_AHEAD,		/* wpos is more than the area's size past rpos */
	ERX_RING_KIND,		/* the record at rpos is not a pipe's kind */
	ERX_RING_LENGTH,	/* its len is outside its kind's range */
	ERX_RING_UNPUBLISHED	/* its header and payload run past wpos */
} erx_ring_fault_t;

/*
 * What a consumer copied, in this order: rpos from the reader page (under
 * the reader lock), wpos from the ring header by its one acquire load, and,
 * when wpos is past rpos, the header of the record at rpos.  The record's
 * stamp orders records across lanes and needs no check.
 */
typedef struct erx_ring_copy {
	uint64_t	 rpos;
	uint64_t	 wpos;
	uint32_t	 kind;		/* the record header's, when wpos > rpos */
	uint32_t	 len;
} erx_ring_copy_t;

/*
 * The consumer's check of a lane whose data area is size bytes: rpos and
 * wpos are multiples of 16, rpos <= wpos and wpos - rpos <= size; and, when
 * wpos > rpos, the record at rpos is a data record of 1 to ERX_PIPE_BUF
 * bytes or a control record of whole tickets up to ERX_PIPE_CONTROL_MAX,
 * whose header and padded payload fit in wpos - rpos.  A sound copy with
 * wpos > rpos names a whole record the reader may copy to its end.
 */
erx_ring_fault_t erx_ring_check(uint64_t size, const erx_ring_copy_t *copy);

/* The bytes a record of len payload bytes takes in a ring: header and padding. */
uint64_t erx_ring_span(uint32_t len);

/*
 * The producer's check: the bytes a write end at wpos may write into a ring
 * of size bytes whose reader page holds the copied rpos.  An rpos that is
 * not a multiple of 16, is past wpos or more than size behind it gives 0,
 * the room of a full ring, so a reader can stop its writer but never make
 * it fail.
 */
uint64_t erx_ring_room(uint64_t size, uint64_t wpos, uint64_t rpos);

/* The reader lock's word, owner: free, held by read end index, or broken. */
typedef enum erx_pipe_owner {
	ERX_PIPE_OWNER_FREE = 0,
	ERX_PIPE_OWNER_HELD,
	ERX_PIPE_OWNER_BROKEN	/* names no read end: 1 + an index >= 64 */
} erx_pipe_owner_t;

/*
 * Checks a copied owner word, 0 when the lock is free, else 1 + the
 * holder's index; on ERX_PIPE_OWNER_HELD, *index is that index, below
 * ERX_PIPE_READERS_MAX.
 */
erx_pipe_owner_t erx_pipe_owner_check(uint32_t owner, uint32_t *index);

/*
 * What a reader that took the lock knows when it settles the current
 * record.  cur, cur_off and cur_pos are untrusted copies of the lock
 * page; rpos is an untrusted copy of cur's lane's reader page; held,
 * record_sound and len are the reader's own findings: whether cur names a
 * write end whose lane it holds, whether the record at rpos passed
 * erx_ring_check, and that record's checked length.
 */
typedef struct erx_pipe_cur_copy {
	uint32_t	 cur;		/* a write end's number, or ERX_PIPE_NONE */
	uint32_t	 cur_off;	/* payload bytes the readers claimed */
	uint64_t	 cur_pos;	/* the record's position in its lane */
	bool		 held;		/* cur's lane is one this reader holds */
	bool		 record_sound;	/* a record at rpos passed erx_ring_check */
	uint64_t	 rpos;		/* cur's lane's rpos, copied */
	uint32_t	 len;		/* that record's payload length */
} erx_pipe_cur_copy_t;

/* The settle table's rows, in the order the reader tries them. */
typedef enum erx_pipe_settle {
	ERX_PIPE_SETTLE_CONTINUE = 0,	/* continue the record from cur_off */
	ERX_PIPE_SETTLE_RETIRE,		/* all claimed: retire it, cur to none */
	ERX_PIPE_SETTLE_FINISHED,	/* rpos is past it: cur to none */
	ERX_PIPE_SETTLE_NONE		/* anything else: cur to none */
} erx_pipe_settle_t;

/*
 * The first row of the lock page's settle table that matches the copies:
 * a record whose bytes a reader claimed is never read from its start
 * again, and a record no reader claimed is never retired.
 */
erx_pipe_settle_t erx_pipe_settle(const erx_pipe_cur_copy_t *copy);

/*
 * A pipe end's doorbell label in a program's group is
 * (pipe << ERX_PIPE_LABEL_SHIFT) | end, computed in 64 bits.  Pipe numbers
 * start at 1, so a label is at least 2^ERX_PIPE_LABEL_SHIFT and never the
 * channel's, ERX_PROG_CHANNEL_LABEL.  These two helpers are the only
 * places C builds a label or takes one apart.  erx_pipe_label refuses a
 * pipe of 0, and a pipe or an end too wide for its part of the label.
 */
_Static_assert(ERX_PIPE_LABEL_SHIFT > 0 && ERX_PIPE_LABEL_SHIFT < 64,
    "both parts of a label are shifts within 64 bits");

static inline bool
erx_pipe_label(uint64_t pipe, uint64_t end, uint64_t *label)
{
	if (pipe == 0 || pipe >> (64 - ERX_PIPE_LABEL_SHIFT) != 0 ||
	    end >> ERX_PIPE_LABEL_SHIFT != 0)
		return (false);
	*label = pipe << ERX_PIPE_LABEL_SHIFT | end;
	return (true);
}

/* Takes a label apart; refuses one below 2^shift, which is no pipe end's. */
static inline bool
erx_pipe_label_parts(uint64_t label, uint64_t *pipe, uint64_t *end)
{
	if (label >> ERX_PIPE_LABEL_SHIFT == 0)
		return (false);
	*pipe = label >> ERX_PIPE_LABEL_SHIFT;
	*end = label & ((UINT64_C(1) << ERX_PIPE_LABEL_SHIFT) - 1);
	return (true);
}

#endif /* !ERX_PIPE_H */
