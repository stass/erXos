/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe core: the writer's and the reader's steps (docs/design-pipes.md,
 * "Writing", "Reading and merging" and "Waiting and doorbells").  Each
 * step is a state machine over an end's private state: it takes what the
 * last action copied, decides, and returns the next action, which its
 * caller performs.  Nothing here reads a page, a clock or global state, so
 * the steps build for the host, where test/fixtures/pipe_explore.c runs
 * them through every interleaving of a model of one pipe.
 *
 * Every value copied from a page another holder writes is checked before
 * it is used (erx_ring_check, erx_ring_room, erx_pipe_settle) and kept in
 * the end's state, so each decision reads each field once.  A writer that
 * finds a bad read position waits as for a full ring; a reader that finds
 * a bad ring marks the lane broken, which counts as gone and drained.  The
 * steps' loops walk the end's own lanes or the call's own length.
 */

#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pipe.h"

/* Positions, records and areas are multiples of a record header. */
#define PIPE_GRAIN	((uint64_t)ERX_LANE_REC_SIZE)

/*
 * A kind no record has: erx_ring_check called with it on positions alone
 * returns ERX_RING_KIND exactly when both positions are sound and a record
 * lies between them.
 */
#define PIPE_NO_KIND	UINT32_MAX

_Static_assert(ERX_REC_DATA != PIPE_NO_KIND && ERX_REC_CONTROL != PIPE_NO_KIND,
    "the positions-only kind is no record's");
_Static_assert(ERX_PIPE_NONE == 0, "write ends are numbered from 1");

static erx_pipe_act_t
pipe_act(erx_pipe_op_t op)
{
	erx_pipe_act_t act = { .op = op, .lane = ERX_PIPE_LANE_NONE };

	return (act);
}

static erx_pipe_act_t
pipe_lane_act(erx_pipe_op_t op, uint32_t lane)
{
	erx_pipe_act_t act = pipe_act(op);

	act.lane = lane;
	return (act);
}

static erx_pipe_act_t
pipe_value_act(erx_pipe_op_t op, uint32_t lane, uint64_t value)
{
	erx_pipe_act_t act = pipe_lane_act(op, lane);

	act.value = value;
	return (act);
}

static erx_pipe_act_t
pipe_pos_act(erx_pipe_op_t op, uint32_t lane, uint64_t pos)
{
	erx_pipe_act_t act = pipe_lane_act(op, lane);

	act.pos = pos;
	return (act);
}

static erx_pipe_act_t
pipe_done(int64_t result)
{
	erx_pipe_act_t act = pipe_act(ERX_PIPE_OP_DONE);

	act.result = result;
	return (act);
}

/* Whether a store that moved a position from old to now crossed mark. */
static bool
pipe_crossed(uint64_t old, uint64_t now, uint64_t mark)
{
	return (old < mark && mark <= now);
}

/* A count of bytes the call finished, or the error when it finished none. */
static int64_t
pipe_count_or(uint64_t done, int error)
{
	return (done > 0 ? (int64_t)done : -error);
}

/*
 * The writer (design "Writing"), one record per chunk: check the read
 * side, find room or publish need and wait, write the stamped record,
 * publish wpos, and ring the read ends that sleep past wake.
 */
enum {
	W_SIDE = 0,	/* the next record: check the read side, copy rpos */
	W_ROOM,		/* in.value: rpos */
	W_ARMED,	/* need stored: fence, then check again */
	W_WOKE,		/* the wait ended: start afresh */
	W_STAMPED,	/* in.value: the clock */
	W_WRITTEN,	/* the record is written: publish it */
	W_PUBLISHED,	/* wpos stored: fence */
	W_FENCED,	/* copy wake */
	W_WAKE,		/* in.value: wake; copy sleepers */
	W_SLEEPERS	/* in.value: sleepers; ring, next record */
};

void
erx_pipe_wstart(erx_pipe_wstate_t *w, uint64_t len)
{
	w->phase = W_SIDE;
	w->len = len;
	w->done = 0;
	w->rec = 0;
	w->published = false;
	w->wake_local = false;
	w->stamp = 0;
	w->wake = 0;
}

/* The record at wpos: its header, stamped, and its payload. */
static erx_pipe_act_t
pipe_write_rec(const erx_pipe_wstate_t *w)
{
	erx_pipe_act_t act;

	act = pipe_value_act(ERX_PIPE_OP_WRITE_REC, ERX_PIPE_LANE_NONE,
	    w->stamp);
	act.pos = w->wpos;
	act.n = w->rec;
	act.off = w->done;
	return (act);
}

/*
 * The call's next record, at most a chunk, or the call's end: its count
 * when every byte is written, else EPIPE when no read end is left.
 */
static erx_pipe_act_t
pipe_write_next(erx_pipe_wstate_t *w)
{
	if (w->done == w->len)
		return (pipe_done((int64_t)w->done));
	if (w->lost || w->readers == 0)
		return (pipe_done(pipe_count_or(w->done, EPIPE)));
	w->rec = w->len - w->done < w->chunk ?
	    (uint32_t)(w->len - w->done) : w->chunk;
	w->phase = W_ROOM;
	return (pipe_act(ERX_PIPE_OP_LOAD_RPOS));
}

/* Publishes the record at wpos whole, by one store of the next wpos. */
static erx_pipe_act_t
pipe_publish(const erx_pipe_wstate_t *w)
{
	return (pipe_value_act(ERX_PIPE_OP_STORE_WPOS, ERX_PIPE_LANE_NONE,
	    w->wpos + erx_ring_span(w->rec)));
}

/*
 * Whether a call short of room, needing need with the rpos it just copied,
 * may wait now.  It may once it has stored its need and fenced in this
 * call and checked again.  Otherwise it may when the published need serves
 * it: every waiting call of the end relies on the one need word, so it
 * holds the smallest need any of them waits for, and a call keeps a
 * published need no greater than its own that the reader has not yet
 * crossed, since the crossing that frees room for it crosses that need
 * first and rings the end, which wakes every waiting call of the end.  A
 * call stores its own need when none is published, when its own is
 * smaller, or when the reader has crossed the published one.  A call that
 * stored a need and then found room does not wait on it, though the
 * calls whose larger need it replaced may: it sets wake_local, and they
 * start afresh and publish theirs again (PI7).
 */
static bool
pipe_wmay_wait(const erx_pipe_wstate_t *w, uint64_t need, uint64_t rpos)
{
	if (w->published)
		return (true);
	return (w->armed && need >= w->need && rpos < w->need);
}

erx_pipe_act_t
erx_pipe_wstep(erx_pipe_wstate_t *w, const erx_pipe_in_t *in)
{
	uint64_t need, old, span;

	switch (w->phase) {
	case W_SIDE:
		return (pipe_write_next(w));
	case W_WOKE:
		/* The call starts afresh with the bytes it has not written. */
		w->published = false;
		w->wake_local = false;
		return (pipe_write_next(w));
	case W_ROOM:
		span = erx_ring_span(w->rec);
		if (erx_ring_room(w->size, w->wpos, in->value) >= span) {
			if (w->published)
				w->wake_local = true;
			w->published = false;
			w->phase = W_STAMPED;
			return (pipe_act(ERX_PIPE_OP_CLOCK));
		}
		if (w->nonblock)
			return (pipe_done(pipe_count_or(w->done, EAGAIN)));
		/*
		 * The read position at which span bytes are free.  Below it
		 * a ring this end never filled has room, so a smaller one
		 * means a bad rpos, which no store of a reader crosses.
		 */
		need = w->wpos + span > w->size ? w->wpos + span - w->size : 0;
		if (pipe_wmay_wait(w, need, in->value)) {
			w->phase = W_WOKE;
			return (pipe_act(ERX_PIPE_OP_WAIT));
		}
		w->armed = true;
		w->need = need;
		w->published = true;
		w->phase = W_ARMED;
		return (pipe_value_act(ERX_PIPE_OP_STORE_NEED, ERX_PIPE_LANE_NONE,
		    need));
	case W_ARMED:
		w->phase = W_SIDE;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case W_STAMPED:
		w->stamp = in->value;
		w->phase = W_WRITTEN;
		return (pipe_write_rec(w));
	case W_WRITTEN:
		w->phase = W_PUBLISHED;
		return (pipe_publish(w));
	case W_PUBLISHED:
		w->wpos += erx_ring_span(w->rec);
		w->phase = W_FENCED;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case W_FENCED:
		w->phase = W_WAKE;
		return (pipe_act(ERX_PIPE_OP_COPY_WAKE));
	case W_WAKE:
		w->wake = in->value;
		w->phase = W_SLEEPERS;
		return (pipe_act(ERX_PIPE_OP_COPY_SLEEPERS));
	case W_SLEEPERS:
		old = w->wpos - erx_ring_span(w->rec);
		w->done += w->rec;
		w->phase = W_SIDE;
		if (in->value != 0 && pipe_crossed(old, w->wpos, w->wake))
			return (pipe_value_act(ERX_PIPE_OP_RING_READERS,
			    ERX_PIPE_LANE_NONE, in->value));
		return (pipe_write_next(w));
	}
	return (pipe_done(-EIO));
}

/*
 * The reader (design "Reading and merging") runs the design's steps as
 * stages, each a small machine of its own:
 *
 *	R_LOCK		step 1: take the reader lock, or wait for it
 *	R_TAKEUP	step 2: close each broken lane whose writer went
 *	R_SETTLE	step 3: copy the current record, settle it by the table
 *	R_PICK		step 4: look at every lane, check wends, look again,
 *			and pick by order key
 *	R_COPY		step 5: claim the record's bytes, then copy them
 *	R_FINISH	step 6: retire a record read to its end, ring its writer
 *	R_ARM		step 7: publish sleepers and wake, then pick again
 *	R_RELEASE	step 8: release the lock and ring its waiters
 *	R_WAIT		wait for the reader lock, data or a report; the step
 *			after it starts the call afresh
 *	R_DISARM	clear the sleepers bits arming set, then return or
 *			wait for a report
 *
 * A stage begins in its pipe_r*_begin function, which returns the stage's
 * first action; erx_pipe_rstep hands what each action copied to the
 * stage's step function, which returns the stage's next action or begins
 * the stage that follows.  r->phase names the action the stage waits on;
 * the begin functions set r->stage.  A step ends in exactly one
 * action and never calls erx_pipe_rstep again, so the begin functions are
 * the only jumps between stages.
 *
 * The pick, copy and finish repeat until the buffer is full or nothing
 * is readable; then pipe_rnothing_readable gives the count, the end of
 * the stream, EAGAIN, or a wait.  Every way out of the lock goes through the
 * release, which r->after follows: the call's result, or a wait, which the
 * release turns into the call's count once it has copied bytes.
 *
 * A wait ends the call: the caller lets go of the end, sleeps, and on its
 * wake starts a fresh call, so every field but the end's lasting ones is
 * the call's scratch.  The bits a wait publishes outlast it, in r->armed
 * (the sleepers bits and wake) and r->waiting (the waiters bit), and are
 * shared by every call of the end waiting at once: a call that finds them
 * set publishes them again before it waits, which changes nothing they
 * promise, and never clears them on the way in, so two waiting calls of
 * one end never clear each other's bits back and forth.  They are cleared
 * only when the end has no wait left to keep them for: the waiters bit
 * once the call holds the reader lock, and the sleepers bits at the
 * release of a call that returns or waits for a report, or by a read of 0
 * bytes.  A call that clears either sets r->wake_local, and its caller
 * wakes the end's other waiting calls, whose wait the bits served; each
 * starts afresh and publishes again what it still waits for.
 *
 * The loops over the lanes (the take-up's, the looks, arming's and
 * the disarm's) each keep their place in
 * r->at, which each loop's begin sets to 0; no two run at once.
 */
enum {
	R_LOCK = 0,
	R_TAKEUP,
	R_SETTLE,
	R_PICK,
	R_COPY,
	R_FINISH,
	R_ARM,
	R_RELEASE,
	R_WAIT,
	R_DISARM
};

/*
 * The phases of every stage, in one enumeration grouped by stage, so no
 * two stages share a value: a phase left over from another stage falls
 * to the step function's default, EIO, rather than being read as one of
 * the stage's own.
 */
enum {
	/* The lock's: what its attempt waits on. */
	LOCK_START = 0,		/* the call's start: try the lock */
	LOCK_TRIED,		/* in.ok of the first compare-and-swap */
	LOCK_WAITER_SET,	/* the waiters bit is set: fence */
	LOCK_FENCED,		/* try again */
	LOCK_RETRIED,		/* in.ok of the second try */
	LOCK_TAKEN,		/* the waiters bit is cleared: take up */
	LOCK_GIVEN_UP,		/* a read of 0 bytes cleared the waiters bit */

	/* The take-up's. */
	TAKEUP_DRAINED,		/* {drained} went out for lane r->at - 1 */

	/* The settle's: each copy the settle table may need, in order. */
	SETTLE_CUR,		/* in: cur, cur_off, cur_pos */
	SETTLE_RPOS,		/* in.value: the held lane's rpos */
	SETTLE_WPOS,		/* in.value: its wpos */
	SETTLE_REC,		/* in: its record at cur_pos */
	SETTLE_CLEARED,		/* cur is stored as none: pick */

	/* The pick's: the look at lane r->at, then wends. */
	LOOK_RPOS,		/* in.value: rpos */
	LOOK_CLOCK,		/* in.value: the clock before the wpos copy */
	LOOK_WPOS,		/* in.value: wpos */
	LOOK_REC,		/* in: the record at rpos */
	LOOK_NOTICED,		/* {drained} or the broken log went out */
	LOOK_WENDS,		/* in.value: wends */

	/* The copy's. */
	COPY_CLAIMED,		/* the claim is in the lock page: copy */
	COPY_COPIED,		/* the bytes are in the buffer */

	/* The finish's. */
	FINISH_RPOS,		/* rpos is past the record: cur to none */
	FINISH_CUR,		/* cur is none: fence */
	FINISH_FENCED,		/* copy need */
	FINISH_NEED,		/* in.value: need */
	FINISH_RUNG,		/* the writer was rung */

	/* Arming's: lane r->at. */
	ARM_SLEEPER,		/* its sleepers bit is set: store wake */
	ARM_WAKE,		/* its wake is stored: the next lane */
	ARM_FENCED,		/* every open lane armed and fenced: pick */

	/* The release's. */
	RELEASE_STORED,		/* owner is 0: fence */
	RELEASE_FENCED,		/* copy waiters */
	RELEASE_WAITERS,	/* in.value: waiters */
	RELEASE_RUNG,		/* the other waiters were rung */

	/* The wait's. */
	WAIT_WOKE,		/* the wait ended: start afresh */

	/* The disarm's. */
	DISARM_CLEARED		/* the sleepers bit of lane r->at - 1 is clear */
};

/* What follows step 8, the release of the reader lock. */
enum {
	R_AFTER_DONE = 0,	/* return result */
	R_AFTER_DATA,		/* wait for data, armed */
	R_AFTER_REPORT		/* wait for the report wends names */
};

/*
 * Starts a call: every scratch field afresh.  armed and waiting are the
 * end's and stay as the end's last wait left them.
 */
void
erx_pipe_rstart(erx_pipe_rstate_t *r, uint64_t len)
{
	r->stage = R_LOCK;
	r->phase = LOCK_START;
	r->at = 0;
	r->len = len;
	r->done = 0;
	r->published = false;
	r->wake_local = false;
	r->settle = (erx_pipe_cur_copy_t){ .cur = ERX_PIPE_NONE };
	r->settle_at = ERX_PIPE_LANE_NONE;
	r->scan = 0;
	r->second = false;
	r->any = false;
	r->gone = false;
	r->clock = 0;
	r->wpos = 0;
	r->cur = ERX_PIPE_LANE_NONE;
	r->cur_off = 0;
	r->cur_pos = 0;
	r->cur_len = 0;
	r->claim = 0;
	r->after = R_AFTER_DONE;
	r->result = 0;
}

static erx_pipe_act_t pipe_rlock_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rtakeup_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rsettle_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rpick_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rcopy_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rfinish_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rarm_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rrelease_begin(erx_pipe_rstate_t *, uint32_t,
    int64_t);
static erx_pipe_act_t pipe_rreleased(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rnothing_readable(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rwait_begin(erx_pipe_rstate_t *);
static erx_pipe_act_t pipe_rdisarm_begin(erx_pipe_rstate_t *);

/*
 * Clears the end's waiters bit, which no wait of the end needs any more:
 * the call holds the reader lock, or gives every wait up.  The end's other
 * waiting calls are woken (wake_local) and start afresh.
 */
static erx_pipe_act_t
pipe_rclear_waiter(erx_pipe_rstate_t *r, uint32_t phase)
{
	r->waiting = false;
	r->wake_local = true;
	r->phase = phase;
	return (pipe_act(ERX_PIPE_OP_CLEAR_WAITER));
}

/* The lock is the call's: clear the waiters bit if a wait left it, then take up. */
static erx_pipe_act_t
pipe_rlocked(erx_pipe_rstate_t *r)
{
	if (r->waiting)
		return (pipe_rclear_waiter(r, LOCK_TAKEN));
	return (pipe_rtakeup_begin(r));
}

/*
 * Step 1: take the lock with one compare-and-swap of owner; while another
 * read end holds it, publish a waiters bit, fence and try again, and if it
 * is still held, wait.  The bit stays set until a call of the end holds
 * the lock, so it serves every call of the end waiting for it.  A read of
 * 0 bytes takes no lock: it gives up every wait of the end, clearing the
 * waiters and sleepers bits, and returns 0.  A read of a lost pipe does
 * the same and fails with EIO: the ended pipe server frees no lock a gone
 * read end held, so a read that waited for the lock could wait for ever.
 */
static erx_pipe_act_t
pipe_rlock_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_LOCK;
	if (r->len == 0 || r->lost) {
		/* No lock is held: the release's tail only disarms and returns. */
		r->after = R_AFTER_DONE;
		r->result = r->len == 0 ? 0 : -EIO;
		if (r->waiting)
			return (pipe_rclear_waiter(r, LOCK_GIVEN_UP));
		return (pipe_rreleased(r));
	}
	r->phase = LOCK_TRIED;
	return (pipe_act(ERX_PIPE_OP_TAKE_LOCK));
}

static erx_pipe_act_t
pipe_rlock_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	switch (r->phase) {
	case LOCK_START:
		return (pipe_rlock_begin(r));
	case LOCK_TRIED:
		if (in->ok)
			return (pipe_rlocked(r));
		r->waiting = true;
		r->phase = LOCK_WAITER_SET;
		return (pipe_act(ERX_PIPE_OP_SET_WAITER));
	case LOCK_WAITER_SET:
		r->phase = LOCK_FENCED;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case LOCK_FENCED:
		r->phase = LOCK_RETRIED;
		return (pipe_act(ERX_PIPE_OP_TAKE_LOCK));
	case LOCK_RETRIED:
		if (in->ok)
			return (pipe_rlocked(r));
		return (pipe_rwait_begin(r));
	case LOCK_TAKEN:
		return (pipe_rtakeup_begin(r));
	case LOCK_GIVEN_UP:
		return (pipe_rreleased(r));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 2: bring the lane set up to date.  The event executor has applied
 * the reports, appending lanes and marking writers gone; a broken lane
 * whose writer has gone is closed now, by one {drained}, as a lane found
 * empty after its writer went is closed by the look that finds it.  A
 * lost pipe fails the read at step 1: the event executor applies reports
 * only between runs, under the end's lock.
 */
static erx_pipe_act_t
pipe_rtakeup_next(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane;
	erx_pipe_act_t act;

	for (; r->at < r->nlanes; r->at++) {
		lane = &r->lanes[r->at];
		if (lane->writer == ERX_PIPE_WRITER_GONE &&
		    lane->ring == ERX_PIPE_RING_BROKEN) {
			lane->ring = ERX_PIPE_RING_DRAINED;
			r->phase = TAKEUP_DRAINED;
			act = pipe_lane_act(ERX_PIPE_OP_DRAINED, r->at);
			r->at++;
			return (act);
		}
	}
	return (pipe_rsettle_begin(r));
}

static erx_pipe_act_t
pipe_rtakeup_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_TAKEUP;
	r->at = 0;
	return (pipe_rtakeup_next(r));
}

static erx_pipe_act_t
pipe_rtakeup_step(erx_pipe_rstate_t *r)
{
	switch (r->phase) {
	case TAKEUP_DRAINED:
		return (pipe_rtakeup_next(r));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 3: settle the current record by the lock page's table
 * (erx_pipe_settle).  The reader copies cur and then only what the table
 * needs and may safely copy: cur's lane's rpos when the reader holds that
 * lane, its wpos when rpos is at the record, and the record's header when
 * both positions are sound with a record between them.  Where a copy
 * leaves nothing more to copy, the table decides from what r->settle
 * holds.  The stops mirror the table's rows: the rows that continue or
 * retire need every copy, the others match on what came before, so a new
 * row that reads another field must move the stops with it.
 */
static erx_pipe_act_t
pipe_rsettle_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_SETTLE;
	r->phase = SETTLE_CUR;
	return (pipe_act(ERX_PIPE_OP_COPY_CUR));
}

/* The lane of write end wend that the reader holds and still reads. */
static uint32_t
pipe_held_lane(const erx_pipe_rstate_t *r, uint32_t wend)
{
	uint32_t at;

	if (wend == ERX_PIPE_NONE)
		return (ERX_PIPE_LANE_NONE);
	for (at = 0; at < r->nlanes; at++)
		if (r->lanes[at].wend == wend &&
		    r->lanes[at].ring == ERX_PIPE_RING_LIVE)
			return (at);
	return (ERX_PIPE_LANE_NONE);
}

/* The record at pos of lane at becomes current, cur_off bytes claimed. */
static void
pipe_make_current(erx_pipe_rstate_t *r, uint32_t at, uint64_t pos,
    uint32_t len, uint32_t cur_off)
{
	r->cur = at;
	r->cur_pos = pos;
	r->cur_len = len;
	r->cur_off = cur_off;
}

/*
 * The table's row for what r->settle holds, and what the reader does.
 * The copy is spent once decided, so r->settle and r->settle_at hold
 * nothing between settles.
 */
static erx_pipe_act_t
pipe_rsettled(erx_pipe_rstate_t *r)
{
	const erx_pipe_cur_copy_t copy = r->settle;
	const uint32_t at = r->settle_at;

	r->settle = (erx_pipe_cur_copy_t){ .cur = ERX_PIPE_NONE };
	r->settle_at = ERX_PIPE_LANE_NONE;
	switch (erx_pipe_settle(&copy)) {
	case ERX_PIPE_SETTLE_CONTINUE:
		pipe_make_current(r, at, copy.cur_pos, copy.len,
		    copy.cur_off);
		return (pipe_rcopy_begin(r));
	case ERX_PIPE_SETTLE_RETIRE:
		pipe_make_current(r, at, copy.cur_pos, copy.len,
		    copy.cur_off);
		return (pipe_rfinish_begin(r));
	case ERX_PIPE_SETTLE_FINISHED:
	case ERX_PIPE_SETTLE_NONE:
		break;
	}
	if (copy.cur == ERX_PIPE_NONE)
		return (pipe_rpick_begin(r));	/* already none */
	r->phase = SETTLE_CLEARED;
	return (pipe_act(ERX_PIPE_OP_STORE_CUR));
}

static erx_pipe_act_t
pipe_rsettle_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	erx_pipe_cur_copy_t *copy = &r->settle;
	erx_ring_copy_t ring;

	switch (r->phase) {
	case SETTLE_CUR:
		r->settle_at = pipe_held_lane(r, in->cur);
		*copy = (erx_pipe_cur_copy_t){ .cur = in->cur,
		    .cur_off = in->cur_off, .cur_pos = in->cur_pos,
		    .held = r->settle_at != ERX_PIPE_LANE_NONE };
		if (!copy->held)
			return (pipe_rsettled(r));
		r->phase = SETTLE_RPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_RPOS, r->settle_at));
	case SETTLE_RPOS:
		r->lanes[r->settle_at].rpos = in->value;
		copy->rpos = in->value;
		if (copy->rpos != copy->cur_pos)
			return (pipe_rsettled(r));
		r->phase = SETTLE_WPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_WPOS, r->settle_at));
	case SETTLE_WPOS:
		r->wpos = in->value;
		ring = (erx_ring_copy_t){ .rpos = copy->cur_pos,
		    .wpos = r->wpos, .kind = PIPE_NO_KIND };
		if (erx_ring_check(r->lanes[r->settle_at].size, &ring) !=
		    ERX_RING_KIND)
			return (pipe_rsettled(r));	/* no sound record */
		r->phase = SETTLE_REC;
		return (pipe_pos_act(ERX_PIPE_OP_COPY_REC, r->settle_at,
		    copy->cur_pos));
	case SETTLE_REC:
		ring = (erx_ring_copy_t){ .rpos = copy->cur_pos,
		    .wpos = r->wpos, .kind = in->kind, .len = in->len };
		copy->len = in->len;
		copy->record_sound = in->kind == ERX_REC_DATA &&
		    erx_ring_check(r->lanes[r->settle_at].size, &ring) ==
		    ERX_RING_SOUND;
		return (pipe_rsettled(r));
	case SETTLE_CLEARED:
		return (pipe_rpick_begin(r));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 4: pick the next record.  The first look covers every lane; if one
 * holds a record, the reader copies wends, and when that names a write
 * end the reports have not named yet, releases the lock to wait for the
 * report, or to return what the call has copied.  Otherwise a second look
 * covers the lanes found empty and the
 * lanes appended meanwhile, and the reader takes the record with the
 * smallest order key.  A look at a lane copies rpos, the clock, wpos
 * (or, while every batch is open, the newest batch's end) and the record
 * at rpos; a lane that fails a check is broken from then on, and an empty
 * lane whose writer was gone before the look is drained and closed.
 */

/* The batches a lane may hold: the end's bound, within ERX_PIPE_BATCHES. */
static uint32_t
pipe_batches(const erx_pipe_rstate_t *r)
{
	return (r->batches == 0 || r->batches > ERX_PIPE_BATCHES ?
	    ERX_PIPE_BATCHES : r->batches);
}

/* Drops the batches the reader has read past. */
static void
pipe_close_batches(erx_pipe_rlane_t *lane)
{
	uint32_t i, kept;

	kept = 0;
	for (i = 0; i < lane->nbatches; i++)
		if (lane->batch[i].end > lane->rpos)
			lane->batch[kept++] = lane->batch[i];
	lane->nbatches = kept;
}

/* The lane with the smallest order key, the lowest write end on a tie. */
static uint32_t
pipe_choose(const erx_pipe_rstate_t *r)
{
	const erx_pipe_rlane_t *a, *best;
	uint32_t i, pick;

	best = NULL;
	pick = ERX_PIPE_LANE_NONE;
	for (i = 0; i < r->nlanes; i++) {
		a = &r->lanes[i];
		if (!a->has_rec)
			continue;
		if (best == NULL || a->key < best->key ||
		    (a->key == best->key && a->wend < best->wend)) {
			best = a;
			pick = i;
		}
	}
	return (pick);
}

/* Every lane of this look is looked at: wends, the pick, or step 7. */
static erx_pipe_act_t
pipe_rlooked(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane;
	uint32_t at;

	if (!r->any)
		return (pipe_rnothing_readable(r));
	if (!r->second) {
		r->phase = LOOK_WENDS;
		return (pipe_act(ERX_PIPE_OP_COPY_WENDS));
	}
	at = pipe_choose(r);
	if (at == ERX_PIPE_LANE_NONE)
		return (pipe_rnothing_readable(r));
	lane = &r->lanes[at];
	pipe_make_current(r, at, lane->rpos, lane->len, 0);
	return (pipe_rcopy_begin(r));
}

/* The look at the next lane this look covers that may hold a record. */
static erx_pipe_act_t
pipe_rlook_next(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane;

	for (; r->at < r->scan; r->at++) {
		lane = &r->lanes[r->at];
		if (lane->ring != ERX_PIPE_RING_LIVE || lane->has_rec)
			continue;
		r->gone = lane->writer == ERX_PIPE_WRITER_GONE;
		r->phase = LOOK_RPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_RPOS, r->at));
	}
	return (pipe_rlooked(r));
}

/* Starts a look over the lanes the reader has now. */
static erx_pipe_act_t
pipe_rlook_begin(erx_pipe_rstate_t *r, bool second)
{
	r->second = second;
	r->scan = r->nlanes;
	r->at = 0;
	return (pipe_rlook_next(r));
}

static erx_pipe_act_t
pipe_rpick_begin(erx_pipe_rstate_t *r)
{
	uint32_t at;

	r->stage = R_PICK;
	r->any = false;
	for (at = 0; at < r->nlanes; at++)
		r->lanes[at].has_rec = false;
	return (pipe_rlook_begin(r, false));
}

/* Lane at failed a check: it is broken from now on, and logged once. */
static erx_pipe_act_t
pipe_rbreak(erx_pipe_rstate_t *r, erx_ring_fault_t fault)
{
	erx_pipe_act_t act;

	r->lanes[r->at].ring = ERX_PIPE_RING_BROKEN;
	r->phase = LOOK_NOTICED;
	act = pipe_lane_act(ERX_PIPE_OP_BROKEN, r->at);
	act.n = fault;
	return (act);
}

/*
 * The look at lane at has its wpos, r->wpos, a fresh copy or the newest
 * batch's end: both positions are checked here, so a record header is
 * copied only at a sound rpos below a sound wpos.  An empty ring is
 * drained if its writer was gone before the look, and the lane closed.
 */
static erx_pipe_act_t
pipe_rlook_wpos(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane = &r->lanes[r->at];
	erx_ring_copy_t copy = { .rpos = lane->rpos, .wpos = r->wpos,
	    .kind = PIPE_NO_KIND };
	erx_ring_fault_t fault;

	fault = erx_ring_check(lane->size, &copy);
	if (fault != ERX_RING_SOUND && fault != ERX_RING_KIND)
		return (pipe_rbreak(r, fault));
	if (r->wpos != lane->rpos) {
		r->phase = LOOK_REC;
		return (pipe_pos_act(ERX_PIPE_OP_COPY_REC, r->at, lane->rpos));
	}
	if (r->gone) {
		lane->ring = ERX_PIPE_RING_DRAINED;
		r->phase = LOOK_NOTICED;
		return (pipe_lane_act(ERX_PIPE_OP_DRAINED, r->at));
	}
	r->at++;
	return (pipe_rlook_next(r));
}

static erx_pipe_act_t
pipe_rpick_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	erx_pipe_rlane_t *lane;
	erx_ring_copy_t copy;
	erx_ring_fault_t fault;
	uint64_t base, mark;

	switch (r->phase) {
	case LOOK_RPOS:
		lane = &r->lanes[r->at];
		lane->rpos = in->value;
		pipe_close_batches(lane);
		if (lane->nbatches < pipe_batches(r)) {
			r->phase = LOOK_CLOCK;
			return (pipe_act(ERX_PIPE_OP_CLOCK));
		}
		/* Every batch open: no new copy of wpos until one closes. */
		r->wpos = lane->batch[lane->nbatches - 1].end;
		return (pipe_rlook_wpos(r));
	case LOOK_CLOCK:
		r->clock = in->value;
		r->phase = LOOK_WPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_WPOS, r->at));
	case LOOK_WPOS:
		lane = &r->lanes[r->at];
		copy = (erx_ring_copy_t){ .rpos = lane->rpos, .wpos = in->value,
		    .kind = PIPE_NO_KIND };
		fault = erx_ring_check(lane->size, &copy);
		if (fault != ERX_RING_SOUND && fault != ERX_RING_KIND)
			return (pipe_rbreak(r, fault));
		/*
		 * Bytes past the newest batch open one, marked with the clock
		 * before the previous copy, the last look without them.
		 */
		base = lane->nbatches > 0 ?
		    lane->batch[lane->nbatches - 1].end : lane->rpos;
		mark = lane->looked ? lane->look : 0;
		if (in->value > base && lane->nbatches < pipe_batches(r))
			lane->batch[lane->nbatches++] =
			    (erx_pipe_batch_t){ .end = in->value, .mark = mark };
		lane->look = r->clock;
		lane->looked = true;
		r->wpos = lane->nbatches > 0 ?
		    lane->batch[lane->nbatches - 1].end : lane->rpos;
		return (pipe_rlook_wpos(r));
	case LOOK_REC:
		lane = &r->lanes[r->at];
		copy = (erx_ring_copy_t){ .rpos = lane->rpos, .wpos = r->wpos,
		    .kind = in->kind, .len = in->len };
		fault = erx_ring_check(lane->size, &copy);
		if (fault != ERX_RING_SOUND)
			return (pipe_rbreak(r, fault));
		/* A control record waits for the second tier (fails safe). */
		if (in->kind != ERX_REC_DATA)
			return (pipe_rbreak(r, ERX_RING_KIND));
		lane->has_rec = true;
		lane->len = in->len;
		lane->key = in->stamp > lane->batch[0].mark ?
		    in->stamp : lane->batch[0].mark;
		r->any = true;
		r->at++;
		return (pipe_rlook_next(r));
	case LOOK_NOTICED:
		r->at++;
		return (pipe_rlook_next(r));
	case LOOK_WENDS:
		/*
		 * A write end the reports have not named yet: wait for it, or,
		 * once this call has copied bytes, return them (step 8).
		 */
		if (in->value > r->known)
			return (pipe_rrelease_begin(r, R_AFTER_REPORT, 0));
		return (pipe_rlook_begin(r, true));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 5: record in the lock page the bytes of the current record this
 * copy takes, as much as is left of it and fits, then copy them.  A
 * record read to its end is finished; one that does not fit stays current
 * for the next read, and the buffer is full.
 */
static erx_pipe_act_t
pipe_rcopy_begin(erx_pipe_rstate_t *r)
{
	erx_pipe_act_t act;
	uint64_t left;

	left = r->len - r->done;
	r->claim = r->cur_len - r->cur_off < left ?
	    r->cur_len - r->cur_off : (uint32_t)left;
	r->stage = R_COPY;
	r->phase = COPY_CLAIMED;
	act = pipe_lane_act(ERX_PIPE_OP_STORE_CUR, r->cur);
	act.n = r->cur_off + r->claim;
	act.pos = r->cur_pos;
	return (act);
}

static erx_pipe_act_t
pipe_rcopy_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	erx_pipe_act_t act;

	(void)in;
	switch (r->phase) {
	case COPY_CLAIMED:
		r->phase = COPY_COPIED;
		act = pipe_pos_act(ERX_PIPE_OP_COPY_DATA, r->cur,
		    r->cur_pos + PIPE_GRAIN + r->cur_off);
		act.n = r->claim;
		act.off = r->done;
		return (act);
	case COPY_COPIED:
		r->done += r->claim;
		r->cur_off += r->claim;
		if (r->cur_off == r->cur_len)
			return (pipe_rfinish_begin(r));
		return (pipe_rrelease_begin(r, R_AFTER_DONE,
		    (int64_t)r->done));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 6: the current record is read to its end.  Advance rpos past it,
 * set cur to none, fence, and ring the writer if the store crossed its
 * need; then read on while the buffer has room.
 */
static erx_pipe_act_t
pipe_rfinish_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_FINISH;
	r->phase = FINISH_RPOS;
	return (pipe_value_act(ERX_PIPE_OP_STORE_RPOS, r->cur,
	    r->cur_pos + erx_ring_span(r->cur_len)));
}

/* The next record, or the count when the buffer is full. */
static erx_pipe_act_t
pipe_rread_on(erx_pipe_rstate_t *r)
{
	if (r->done < r->len)
		return (pipe_rpick_begin(r));
	return (pipe_rrelease_begin(r, R_AFTER_DONE, (int64_t)r->done));
}

static erx_pipe_act_t
pipe_rfinish_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	erx_pipe_rlane_t *lane;
	uint64_t next;
	uint32_t at;

	switch (r->phase) {
	case FINISH_RPOS:
		r->phase = FINISH_CUR;
		return (pipe_act(ERX_PIPE_OP_STORE_CUR));
	case FINISH_CUR:
		r->phase = FINISH_FENCED;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case FINISH_FENCED:
		r->phase = FINISH_NEED;
		return (pipe_lane_act(ERX_PIPE_OP_COPY_NEED, r->cur));
	case FINISH_NEED:
		at = r->cur;
		lane = &r->lanes[at];
		next = r->cur_pos + erx_ring_span(r->cur_len);
		lane->rpos = next;
		pipe_close_batches(lane);
		r->cur = ERX_PIPE_LANE_NONE;
		if (pipe_crossed(r->cur_pos, next, in->value)) {
			r->phase = FINISH_RUNG;
			return (pipe_lane_act(ERX_PIPE_OP_RING_WRITER, at));
		}
		return (pipe_rread_on(r));
	case FINISH_RUNG:
		return (pipe_rread_on(r));
	}
	return (pipe_done(-EIO));
}

/*
 * Whether the stream has ended: every lane is broken, which counts as
 * gone and drained, or drained after its writer went.
 */
static bool
pipe_ended(const erx_pipe_rstate_t *r)
{
	uint32_t i;

	for (i = 0; i < r->nlanes; i++)
		if (r->lanes[i].ring == ERX_PIPE_RING_LIVE)
			return (false);
	return (true);
}

/*
 * Step 7: nothing is readable.  A read that copied something returns its
 * count; one that copied nothing returns 0 at the end of the stream, else
 * fails with EAGAIN when non-blocking.  A blocking read arms every open
 * lane and picks once more; having armed and still finding nothing, it
 * waits.
 */
static erx_pipe_act_t
pipe_rnothing_readable(erx_pipe_rstate_t *r)
{
	if (r->done > 0)
		return (pipe_rrelease_begin(r, R_AFTER_DONE, (int64_t)r->done));
	if (pipe_ended(r))
		return (pipe_rrelease_begin(r, R_AFTER_DONE, 0));
	if (r->nonblock)
		return (pipe_rrelease_begin(r, R_AFTER_DONE, -EAGAIN));
	if (r->published)
		return (pipe_rrelease_begin(r, R_AFTER_DATA, 0));
	return (pipe_rarm_begin(r));
}

/*
 * Arms the next lane the last look covered whose writer is open: its
 * sleepers bit, then wake = rpos + 1.  Once every such lane is armed, a
 * full fence, then step 4 again.
 */
static erx_pipe_act_t
pipe_rarm_next(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane;

	for (; r->at < r->scan; r->at++) {
		lane = &r->lanes[r->at];
		if (lane->ring == ERX_PIPE_RING_LIVE &&
		    lane->writer == ERX_PIPE_WRITER_OPEN) {
			r->phase = ARM_SLEEPER;
			return (pipe_lane_act(ERX_PIPE_OP_SET_SLEEPER, r->at));
		}
	}
	r->armed = true;
	r->published = true;
	r->phase = ARM_FENCED;
	return (pipe_act(ERX_PIPE_OP_FENCE));
}

static erx_pipe_act_t
pipe_rarm_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_ARM;
	r->at = 0;
	return (pipe_rarm_next(r));
}

static erx_pipe_act_t
pipe_rarm_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	(void)in;
	switch (r->phase) {
	case ARM_SLEEPER:
		r->phase = ARM_WAKE;
		return (pipe_value_act(ERX_PIPE_OP_STORE_WAKE, r->at,
		    r->lanes[r->at].rpos + 1));
	case ARM_WAKE:
		r->at++;
		return (pipe_rarm_next(r));
	case ARM_FENCED:
		return (pipe_rpick_begin(r));
	}
	return (pipe_done(-EIO));
}

/*
 * Step 8: release the lock by storing 0 in owner, fence, copy waiters and
 * ring every other read end whose bit is set; then do what after says.
 *
 * A call that has copied bytes returns them rather than wait, for data or
 * for a report: rpos is already past them, so they exist only in the
 * caller's buffer, and the session's pipe NIF answers a wait with
 * would_block and lets that buffer go.  Every wait but the lock's leaves
 * through here, and the lock's comes only at the start of a call or after
 * one of these waits, so no wait is ever reached with done > 0.
 */
static erx_pipe_act_t
pipe_rrelease_begin(erx_pipe_rstate_t *r, uint32_t after, int64_t result)
{
	if (after != R_AFTER_DONE && r->done > 0) {
		after = R_AFTER_DONE;
		result = (int64_t)r->done;
	}
	r->after = after;
	r->result = result;
	r->stage = R_RELEASE;
	r->phase = RELEASE_STORED;
	return (pipe_act(ERX_PIPE_OP_RELEASE_LOCK));
}

/*
 * After the release: a wait for data keeps the sleepers bits arming set,
 * for every call of the end that waits; a call that returns or waits for a
 * report clears them first, if a wait of the end left them set.
 */
static erx_pipe_act_t
pipe_rreleased(erx_pipe_rstate_t *r)
{
	if (r->armed && r->after != R_AFTER_DATA)
		return (pipe_rdisarm_begin(r));
	if (r->after == R_AFTER_DONE)
		return (pipe_done(r->result));
	return (pipe_rwait_begin(r));
}

static erx_pipe_act_t
pipe_rrelease_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	uint64_t others;

	switch (r->phase) {
	case RELEASE_STORED:
		r->phase = RELEASE_FENCED;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case RELEASE_FENCED:
		r->phase = RELEASE_WAITERS;
		return (pipe_act(ERX_PIPE_OP_COPY_WAITERS));
	case RELEASE_WAITERS:
		others = in->value & ~(UINT64_C(1) << r->rix);
		if (others != 0) {
			r->phase = RELEASE_RUNG;
			return (pipe_value_act(ERX_PIPE_OP_RING_READERS,
			    ERX_PIPE_LANE_NONE, others));
		}
		return (pipe_rreleased(r));
	case RELEASE_RUNG:
		return (pipe_rreleased(r));
	}
	return (pipe_done(-EIO));
}

/*
 * A wait, for the reader lock after step 1 or for data or a report after
 * step 8, for the doorbell.  It ends the call, and the call that follows
 * starts afresh; the step after the wait does the same, for a caller that
 * steps on.  No read waits with bytes copied: the lock's wait comes before
 * any copy, and the release turns every other wait into the call's count
 * once it has copied bytes.
 */
static erx_pipe_act_t
pipe_rwait_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_WAIT;
	r->phase = WAIT_WOKE;
	return (pipe_act(ERX_PIPE_OP_WAIT));
}

static erx_pipe_act_t
pipe_rwait_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	(void)in;
	if (r->phase != WAIT_WOKE)
		return (pipe_done(-EIO));
	erx_pipe_rstart(r, r->len);
	return (pipe_rlock_begin(r));
}

/*
 * Clears the end's sleepers bit in every lane it reads, which ends every
 * wait for data of the end, so its other waiting calls are woken
 * (wake_local); then returns the result or waits for a report.
 */
static erx_pipe_act_t
pipe_rdisarm_next(erx_pipe_rstate_t *r)
{
	for (; r->at < r->nlanes; r->at++) {
		if (r->lanes[r->at].ring == ERX_PIPE_RING_LIVE) {
			r->phase = DISARM_CLEARED;
			return (pipe_lane_act(ERX_PIPE_OP_CLEAR_SLEEPER, r->at++));
		}
	}
	r->armed = false;
	r->wake_local = true;
	if (r->after == R_AFTER_REPORT)
		return (pipe_rwait_begin(r));
	return (pipe_done(r->result));
}

static erx_pipe_act_t
pipe_rdisarm_begin(erx_pipe_rstate_t *r)
{
	r->stage = R_DISARM;
	r->at = 0;
	return (pipe_rdisarm_next(r));
}

static erx_pipe_act_t
pipe_rdisarm_step(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	(void)in;
	if (r->phase == DISARM_CLEARED)
		return (pipe_rdisarm_next(r));
	return (pipe_done(-EIO));
}

erx_pipe_act_t
erx_pipe_rstep(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	switch (r->stage) {
	case R_LOCK:
		return (pipe_rlock_step(r, in));
	case R_TAKEUP:
		return (pipe_rtakeup_step(r));
	case R_SETTLE:
		return (pipe_rsettle_step(r, in));
	case R_PICK:
		return (pipe_rpick_step(r, in));
	case R_COPY:
		return (pipe_rcopy_step(r, in));
	case R_FINISH:
		return (pipe_rfinish_step(r, in));
	case R_ARM:
		return (pipe_rarm_step(r, in));
	case R_RELEASE:
		return (pipe_rrelease_step(r, in));
	case R_WAIT:
		return (pipe_rwait_step(r, in));
	case R_DISARM:
		return (pipe_rdisarm_step(r, in));
	}
	return (pipe_done(-EIO));
}

short
erx_pipe_ready_read(bool data, uint32_t writers_open, bool lost)
{
	short events = 0;

	if (data)
		events |= POLLIN;
	if (writers_open == 0 || lost)
		events |= POLLHUP;
	if (lost)
		events |= POLLERR;
	return (events);
}

short
erx_pipe_ready_write(uint64_t room, uint32_t chunk, uint32_t readers,
    bool lost)
{
	short events = 0;

	if (room >= erx_ring_span(chunk))
		events |= POLLOUT;
	if (readers == 0 || lost)
		events |= POLLERR;
	return (events);
}
