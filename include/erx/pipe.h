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
 * The pipe core (docs/design-pipes.md, "Writing", "Reading and merging"
 * and "The pipe core"): the writer's and the reader's steps, pure state
 * machines over an end's private state.  A call of erx_pipe_write or
 * erx_pipe_read starts its end's state with erx_pipe_wstart or
 * erx_pipe_rstart, then loops: the step returns one action, the caller
 * performs it (one copy of a shared field, a store, a fence, a ring or a
 * wait) and hands what it copied back in erx_pipe_in_t to the next step,
 * until the step returns ERX_PIPE_OP_DONE.  A step reads no page, clock or
 * global state: every shared value reaches it as one copy, which it checks
 * before use and keeps in the end's state, so no decision reads a field
 * twice.  The steps' loops are bounded by the end's own lanes and the
 * call's length, never by a copied value.
 */

/* What a step asks its caller to do; the action's fields it uses follow. */
typedef enum erx_pipe_op {
	ERX_PIPE_OP_DONE = 0,	/* the call returns result */
	ERX_PIPE_OP_CLOCK,	/* in.value = the time page's monotonic clock */
	ERX_PIPE_OP_LOAD_RPOS,	/* in.value = lane's rpos, the acquire load */
	ERX_PIPE_OP_LOAD_WPOS,	/* in.value = lane's wpos, the acquire load */
	ERX_PIPE_OP_COPY_NEED,	/* in.value = lane's ring header need */
	ERX_PIPE_OP_COPY_WAKE,	/* in.value = the reader page's wake */
	ERX_PIPE_OP_COPY_SLEEPERS, /* in.value = the reader page's sleepers */
	ERX_PIPE_OP_COPY_REC,	/* in.len, kind, stamp = lane's record at pos */
	ERX_PIPE_OP_COPY_CUR,	/* in.cur, cur_off, cur_pos = the lock page's */
	ERX_PIPE_OP_COPY_WENDS,	/* in.value = the lock page's wends */
	ERX_PIPE_OP_COPY_WAITERS, /* in.value = the lock page's waiters */
	ERX_PIPE_OP_COPY_DATA,	/* n bytes of lane's area at pos to buf + off */
	ERX_PIPE_OP_WRITE_REC,	/* a data record of n bytes from buf + off, its
				 * stamp value, at pos of the area */
	ERX_PIPE_OP_STORE_WPOS,	/* wpos = value, release */
	ERX_PIPE_OP_STORE_NEED,	/* need = value, release */
	ERX_PIPE_OP_STORE_RPOS,	/* lane's rpos = value, release */
	ERX_PIPE_OP_STORE_WAKE,	/* lane's wake = value, release */
	ERX_PIPE_OP_STORE_CUR,	/* cur = lane's write end, or ERX_PIPE_NONE for
				 * ERX_PIPE_LANE_NONE; cur_off = n; cur_pos =
				 * pos; relaxed */
	ERX_PIPE_OP_SET_SLEEPER, /* atomic or of the end's bit in lane's sleepers */
	ERX_PIPE_OP_CLEAR_SLEEPER, /* atomic and of its complement */
	ERX_PIPE_OP_SET_WAITER,	/* the same in the lock page's waiters */
	ERX_PIPE_OP_CLEAR_WAITER,
	ERX_PIPE_OP_TAKE_LOCK,	/* in.ok = CAS of owner from 0 to 1 + rix */
	ERX_PIPE_OP_RELEASE_LOCK, /* owner = 0, release */
	ERX_PIPE_OP_FENCE,	/* a full fence */
	ERX_PIPE_OP_RING_READERS, /* ring each read end whose bit is in value */
	ERX_PIPE_OP_RING_WRITER, /* ring lane's write end */
	ERX_PIPE_OP_WAIT,	/* wait for the end's doorbell */
	ERX_PIPE_OP_DRAINED,	/* send the handler {drained} for lane's end */
	ERX_PIPE_OP_BROKEN	/* log once that lane broke, its fault in n */
} erx_pipe_op_t;

#define ERX_PIPE_LANE_NONE	UINT32_MAX	/* an action that names no lane */

typedef struct erx_pipe_act {
	erx_pipe_op_t	 op;
	uint32_t	 lane;		/* an index into the read end's lanes */
	uint64_t	 pos;
	uint64_t	 value;
	uint64_t	 n;
	uint64_t	 off;		/* into the call's buffer */
	int64_t		 result;	/* DONE: a count, or a negative errno */
} erx_pipe_act_t;

/* What the last action copied, for the next step. */
typedef struct erx_pipe_in {
	uint64_t	 value;
	bool		 ok;
	uint32_t	 len;
	uint32_t	 kind;
	uint64_t	 stamp;
	uint32_t	 cur;
	uint32_t	 cur_off;
	uint64_t	 cur_pos;
} erx_pipe_in_t;

/*
 * A write end.  size, chunk, readers, lost and nonblock are the end's:
 * chunk is ERX_PIPE_BUF (a model scales it down with its rings), and
 * readers and lost are what the event executor keeps from the handler's
 * reports (PI3).  wpos is the end's private write position, which it only
 * ever stores.  armed and need, the end's lasting state, are kept apart
 * from published, the call's own store of need, as the read end's armed
 * is from its published.  armed and need last from call to
 * call: whether a call of the end has published a need, and the last one
 * published, which the calls of one end waiting at once share
 * (docs/design-pipes.md, "Ends in liberx").  The rest belongs to the call
 * in progress, valid only while the call holds the end.
 */
typedef struct erx_pipe_wstate {
	uint64_t	 size;		/* the data area, a power of two */
	uint32_t	 chunk;
	uint32_t	 readers;
	bool		 lost;
	bool		 nonblock;
	uint64_t	 wpos;
	uint32_t	 phase;
	uint64_t	 len;		/* bytes the call writes */
	uint64_t	 done;		/* bytes it published */
	uint32_t	 rec;		/* the record being written */
	bool		 published;	/* this call stored need and fenced */
	bool		 wake_local;	/* this call stored a need and then found
					 * room: its caller wakes the end's
					 * other waiting calls */
	uint64_t	 stamp;
	uint64_t	 wake;		/* the copy of wake */
	bool		 armed;		/* a need is published and fenced */
	uint64_t	 need;		/* the need last published */
} erx_pipe_wstate_t;

/*
 * A lane's writer, as the read end's reports give it.  GONE is final: a
 * lane serves one write end, and the event executor never sets a gone
 * writer open again nor reuses the lane for another write end, so a
 * DRAINED lane always has a gone writer.
 */
typedef enum erx_pipe_writer {
	ERX_PIPE_WRITER_OPEN = 0,
	ERX_PIPE_WRITER_GONE
} erx_pipe_writer_t;

/*
 * Where the read end is with a lane's ring.  A LIVE lane is read; one
 * that fails a check is BROKEN, which counts as gone and drained (PI2);
 * and a lane found empty after its writer went, or broken with its writer
 * gone, is DRAINED: the read end has sent the handler {drained} for it,
 * once, and is done with it.  A lane never returns to LIVE, and only a
 * lane whose writer is gone is DRAINED.
 */
typedef enum erx_pipe_ring {
	ERX_PIPE_RING_LIVE = 0,
	ERX_PIPE_RING_DRAINED,
	ERX_PIPE_RING_BROKEN
} erx_pipe_ring_t;

/* The most batches a read end keeps for one lane. */
#define ERX_PIPE_BATCHES	4

/* Bytes found at one copy of a lane's wpos: up to end, and their mark. */
typedef struct erx_pipe_batch {
	uint64_t	 end;
	uint64_t	 mark;		/* the clock before the previous copy */
} erx_pipe_batch_t;

/*
 * A read end's lane, one for each write end it knows.  wend, size and
 * writer are the event executor's, from the handler's reports; the rest
 * is the steps'.
 */
typedef struct erx_pipe_rlane {
	uint32_t	 wend;		/* the write end's number, from 1 */
	uint64_t	 size;
	erx_pipe_writer_t writer;
	erx_pipe_ring_t	 ring;
	bool		 looked;	/* a copy of wpos was taken before */
	uint64_t	 look;		/* the clock before the last such copy */
	uint32_t	 nbatches;
	erx_pipe_batch_t batch[ERX_PIPE_BATCHES];
	uint64_t	 rpos;		/* the last copy, or the reader's store */
	/* What the pick in progress found at rpos, under the reader lock. */
	bool		 has_rec;	/* a sound data record, in a LIVE lane */
	uint32_t	 len;
	uint64_t	 key;
} erx_pipe_rlane_t;

/*
 * A read end.  rix, taken, nonblock, lost, known, batches and the lanes are
 * the end's: rix is its index, which only erx_pipe_rtake gives it, setting
 * taken, so a read state made any other way, a zeroed one included, has no
 * index erx_pipe_rrun accepts; lanes holds nlanes lanes, which the event
 * executor appends as reports name write ends, raising known, its count of
 * the write ends it knows (compared with the lock page's wends); batches is
 * at most ERX_PIPE_BATCHES (a model scales it down).  armed and waiting
 * are the end's too, lasting from call to call: the bits a wait of the
 * end published, which the calls of one end waiting at once share, and
 * which a call clears only when it ends every such wait, setting
 * wake_local (docs/design-pipes.md, "Ends in liberx").  The rest belongs
 * to the call in progress, valid only while the call holds the end,
 * grouped by the reader's stage that uses it (liberx/erx_pipe_core.c).
 */
typedef struct erx_pipe_rstate {
	uint32_t	 rix;
	bool		 taken;		/* erx_pipe_rtake gave rix */
	bool		 nonblock;
	bool		 lost;
	uint32_t	 known;
	uint32_t	 batches;
	erx_pipe_rlane_t *lanes;
	uint32_t	 nlanes;
	bool		 armed;		/* its sleepers bits and wake are published
					 * and fenced, for a wait for data */
	bool		 waiting;	/* its waiters bit is published */
	/* Where the call is. */
	uint32_t	 stage;		/* the design step the read is in */
	uint32_t	 phase;		/* the action the stage waits on */
	uint32_t	 at;		/* the lane a loop over the lanes is at */
	uint64_t	 len;		/* bytes wanted */
	uint64_t	 done;		/* bytes copied */
	bool		 published;	/* this call armed: the pick that follows
					 * decides whether it waits */
	bool		 wake_local;	/* this call cleared armed or waiting:
					 * its caller wakes the end's other
					 * waiting calls */
	/* The settle: what its table reads, as far as it is copied. */
	erx_pipe_cur_copy_t settle;
	uint32_t	 settle_at;	/* the lane of settle.cur, when held */
	/* The pick: the look in progress. */
	uint32_t	 scan;		/* the lanes it covers, which arming
					 * covers too */
	bool		 second;	/* the pick's second look */
	bool		 any;		/* the first look found a record */
	bool		 gone;		/* the lane's writer was gone before it */
	uint64_t	 clock;
	uint64_t	 wpos;		/* the lane's, checked against its rpos;
					 * the settle's copy too */
	/* The copy and finish: the current record, at cur_pos of lane cur. */
	uint32_t	 cur;		/* ERX_PIPE_LANE_NONE when none */
	uint32_t	 cur_off;	/* its payload bytes claimed */
	uint64_t	 cur_pos;
	uint32_t	 cur_len;
	uint32_t	 claim;		/* bytes of it this copy takes */
	/* The release: what follows it. */
	uint32_t	 after;
	int64_t		 result;
} erx_pipe_rstate_t;

/*
 * Starts a write of len bytes, one record per chunk, in order.  A call
 * that waited starts afresh with the bytes it has not written, which is
 * what the step after its wait does too.
 */
void		erx_pipe_wstart(erx_pipe_wstate_t *w, uint64_t len);
erx_pipe_act_t	erx_pipe_wstep(erx_pipe_wstate_t *w, const erx_pipe_in_t *in);

/*
 * Starts a read of at most len bytes.  A call that waited starts afresh,
 * which is what the step after its wait does too; a read never waits with
 * bytes copied.  A read started while another call of the end waits
 * shares the bits that wait published, and a read of 0 bytes clears them,
 * ending every wait of the end; either sets wake_local when it clears.
 */
void		erx_pipe_rstart(erx_pipe_rstate_t *r, uint64_t len);
erx_pipe_act_t	erx_pipe_rstep(erx_pipe_rstate_t *r, const erx_pipe_in_t *in);

/*
 * The POLL* bits of an end (docs/design-pipes.md, "Readiness"): a read
 * end's from whether a lane holds a data record and its count of open
 * writers, a write end's from its ring's room and its count of read ends.
 */
short	erx_pipe_ready_read(bool data, uint32_t writers_open, bool lost);
short	erx_pipe_ready_write(uint64_t room, uint32_t chunk, uint32_t readers,
	    bool lost);

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
