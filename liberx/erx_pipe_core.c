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
	W_SIDE = 0,	/* check the read side; copy rpos */
	W_ROOM,		/* in.value: rpos */
	W_ARMED,	/* need stored: fence, then check again */
	W_WOKE,		/* the doorbell rang: check again */
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
	w->armed = false;
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

/* Publishes the record at wpos whole, by one store of the next wpos. */
static erx_pipe_act_t
pipe_publish(const erx_pipe_wstate_t *w)
{
	return (pipe_value_act(ERX_PIPE_OP_STORE_WPOS, ERX_PIPE_LANE_NONE,
	    w->wpos + erx_ring_span(w->rec)));
}

erx_pipe_act_t
erx_pipe_wstep(erx_pipe_wstate_t *w, const erx_pipe_in_t *in)
{
	uint64_t need, old, span;

	switch (w->phase) {
	case W_WOKE:
		w->armed = false;
		/* FALLTHROUGH */
	case W_SIDE:
		if (w->done == w->len)
			return (pipe_done((int64_t)w->done));
		if (w->lost || w->readers == 0)
			return (pipe_done(pipe_count_or(w->done, EPIPE)));
		w->rec = w->len - w->done < w->chunk ?
		    (uint32_t)(w->len - w->done) : w->chunk;
		w->phase = W_ROOM;
		return (pipe_act(ERX_PIPE_OP_LOAD_RPOS));
	case W_ROOM:
		span = erx_ring_span(w->rec);
		if (erx_ring_room(w->size, w->wpos, in->value) >= span) {
			w->armed = false;
			w->phase = W_STAMPED;
			return (pipe_act(ERX_PIPE_OP_CLOCK));
		}
		if (w->nonblock)
			return (pipe_done(pipe_count_or(w->done, EAGAIN)));
		if (w->armed) {
			w->phase = W_WOKE;
			return (pipe_act(ERX_PIPE_OP_WAIT));
		}
		/*
		 * The read position at which span bytes are free.  Below it
		 * a ring this end never filled has room, so a smaller one
		 * means a bad rpos, which no store of a reader crosses.
		 */
		need = w->wpos + span > w->size ? w->wpos + span - w->size : 0;
		w->armed = true;
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
		return (erx_pipe_wstep(w, in));
	}
	return (pipe_done(-EIO));
}

/*
 * The reader (design "Reading and merging"): take the lock, take up the
 * reports, settle the current record, then pick, claim, copy and finish
 * records until the buffer is full or nothing is readable; then the end
 * of the stream, EAGAIN, or publishing sleepers and wake and waiting; and
 * last the release, which rings the read ends waiting for the lock.
 */
enum {
	R_LOCK = 0,	/* try the lock */
	R_LOCKED,	/* in.ok */
	R_WAITER_SET,	/* waiters bit set: fence */
	R_RETRY,	/* try the lock again */
	R_RELOCKED,	/* in.ok of the retry */
	R_LOCK_WOKE,	/* woken while waiting for the lock */
	R_TAKEUP,	/* step 2, from lane at */
	R_SETTLE,	/* step 3: copy the current record */
	R_CUR,		/* in: cur, cur_off, cur_pos */
	R_CUR_RPOS,	/* in.value: cur's lane's rpos */
	R_CUR_WPOS,	/* in.value: its wpos */
	R_CUR_REC,	/* in: its record at rpos */
	R_PICK,		/* step 4: a look over every lane */
	R_LANE,		/* the look at lane at, or the next lane */
	R_LANE_RPOS,	/* in.value: rpos */
	R_LANE_CLOCK,	/* in.value: the clock before the wpos copy */
	R_LANE_WPOS,	/* in.value: wpos */
	R_LANE_REC,	/* in: the record at rpos */
	R_LANE_NEXT,	/* a notice of lane at went out */
	R_LOOKED,	/* every lane looked at */
	R_WENDS,	/* in.value: wends */
	R_COPY,		/* step 5: the claim is stored; copy */
	R_COPIED,	/* the copy is done */
	R_FINISH_CUR,	/* step 6: rpos stored; cur to none */
	R_FINISH_FENCE,
	R_NEED,		/* copy need */
	R_NEED_IN,	/* in.value: need */
	R_MORE,		/* go on or end the read */
	R_ARM,		/* step 7: */		/* set sleepers bit of lane at */
	R_ARM_WAKE,	/* store wake of lane at */
	R_ARM_NEXT,
	R_RELEASED,	/* step 8: the lock is released */
	R_WAITERS,
	R_WAITERS_IN,	/* in.value: waiters */
	R_AFTER,	/* the end of the call, or a wait */
	R_DATA_WOKE	/* clear sleepers bits from lane at */
};

/* What follows the release of the reader lock. */
enum {
	R_AFTER_DONE = 0,	/* return result */
	R_AFTER_DATA,		/* wait for data, then clear sleepers bits */
	R_AFTER_REPORT		/* wait for the report wends names */
};

void
erx_pipe_rstart(erx_pipe_rstate_t *r, uint64_t len)
{
	r->phase = R_LOCK;
	r->after = R_AFTER_DONE;
	r->at = 0;
	r->scan = 0;
	r->second = false;
	r->any = false;
	r->armed = false;
	r->len = len;
	r->done = 0;
	r->clock = 0;
	r->wpos = 0;
	r->cur = ERX_PIPE_LANE_NONE;
	r->cur_off = 0;
	r->cur_pos = 0;
	r->cur_len = 0;
	r->claim = 0;
	r->result = 0;
}

static erx_pipe_act_t
pipe_release(erx_pipe_rstate_t *r, uint32_t after, int64_t result)
{
	r->after = after;
	r->result = result;
	r->phase = R_RELEASED;
	return (pipe_act(ERX_PIPE_OP_RELEASE_LOCK));
}

/* Lane at failed a check: it is broken from now on, and logged once. */
static erx_pipe_act_t pipe_break(erx_pipe_rstate_t *, erx_ring_fault_t);

static erx_pipe_act_t
pipe_break(erx_pipe_rstate_t *r, erx_ring_fault_t fault)
{
	erx_pipe_rlane_t *lane = &r->lanes[r->at];
	erx_pipe_act_t act;

	lane->ring = ERX_PIPE_RING_BROKEN;
	lane->has_rec = false;
	r->phase = R_LANE_NEXT;
	act = pipe_lane_act(ERX_PIPE_OP_BROKEN, r->at);
	act.n = fault;
	return (act);
}

/* The current record goes: cur to none, then the next look. */
static erx_pipe_act_t
pipe_clear_cur(erx_pipe_rstate_t *r)
{
	r->cur = ERX_PIPE_LANE_NONE;
	r->phase = R_PICK;
	return (pipe_act(ERX_PIPE_OP_STORE_CUR));
}

/* The current record is read to its end: advance rpos past it. */
static erx_pipe_act_t
pipe_finish(erx_pipe_rstate_t *r)
{
	r->phase = R_FINISH_CUR;
	return (pipe_value_act(ERX_PIPE_OP_STORE_RPOS, r->cur,
	    r->cur_pos + erx_ring_span(r->cur_len)));
}

/* The current record's next claim: as much as is left and fits. */
static erx_pipe_act_t
pipe_claim(erx_pipe_rstate_t *r)
{
	erx_pipe_act_t act;
	uint64_t left;

	left = r->len - r->done;
	r->claim = r->cur_len - r->cur_off < left ?
	    r->cur_len - r->cur_off : (uint32_t)left;
	r->phase = R_COPY;
	act = pipe_lane_act(ERX_PIPE_OP_STORE_CUR, r->cur);
	act.n = r->cur_off + r->claim;
	act.pos = r->cur_pos;
	return (act);
}

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

/*
 * The look at lane at has its wpos, r->wpos, a fresh copy or the newest
 * batch's end: both positions are checked here, so a record header is
 * copied only at a sound rpos below a sound wpos.  An empty ring is
 * drained if its writer was gone before the look.
 */
static erx_pipe_act_t
pipe_lane_wpos(erx_pipe_rstate_t *r)
{
	erx_pipe_rlane_t *lane = &r->lanes[r->at];
	erx_ring_copy_t copy = { .rpos = lane->rpos, .wpos = r->wpos,
	    .kind = PIPE_NO_KIND };
	erx_ring_fault_t fault;
	erx_pipe_act_t act;

	fault = erx_ring_check(lane->size, &copy);
	if (fault != ERX_RING_SOUND && fault != ERX_RING_KIND)
		return (pipe_break(r, fault));
	if (r->wpos != lane->rpos) {
		r->phase = R_LANE_REC;
		act = pipe_lane_act(ERX_PIPE_OP_COPY_REC, r->at);
		act.pos = lane->rpos;
		return (act);
	}
	if (lane->gone) {
		lane->ring = ERX_PIPE_RING_DRAINED;
		if (!lane->noticed) {
			lane->noticed = true;
			r->phase = R_LANE_NEXT;
			return (pipe_lane_act(ERX_PIPE_OP_DRAINED, r->at));
		}
	}
	r->at++;
	r->phase = R_LANE;
	return (erx_pipe_rstep(r, NULL));
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

/*
 * Whether the stream has ended: every lane is broken, which counts as
 * gone and drained, or its writer is gone and the lane found drained.
 */
static bool
pipe_ended(const erx_pipe_rstate_t *r)
{
	const erx_pipe_rlane_t *lane;
	uint32_t i;

	for (i = 0; i < r->nlanes; i++) {
		lane = &r->lanes[i];
		if (lane->ring == ERX_PIPE_RING_LIVE ||
		    (lane->ring == ERX_PIPE_RING_DRAINED &&
		    lane->writer != ERX_PIPE_WRITER_GONE))
			return (false);
	}
	return (true);
}

erx_pipe_act_t
erx_pipe_rstep(erx_pipe_rstate_t *r, const erx_pipe_in_t *in)
{
	erx_pipe_rlane_t *lane;
	erx_pipe_cur_copy_t settle;
	erx_ring_copy_t copy;
	erx_ring_fault_t fault;
	erx_pipe_act_t act;
	uint64_t base, mark, next;
	uint32_t at;

	lane = r->at < r->nlanes ? &r->lanes[r->at] : NULL;
	switch (r->phase) {
	/* Step 1: the lock. */
	case R_LOCK:
		if (r->len == 0)
			return (pipe_done(0));
		r->phase = R_LOCKED;
		return (pipe_act(ERX_PIPE_OP_TAKE_LOCK));
	case R_LOCKED:
		if (in->ok) {
			r->at = 0;
			r->phase = R_TAKEUP;
			return (erx_pipe_rstep(r, NULL));
		}
		r->phase = R_WAITER_SET;
		return (pipe_act(ERX_PIPE_OP_SET_WAITER));
	case R_WAITER_SET:
		r->phase = R_RETRY;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case R_RETRY:
		r->phase = R_RELOCKED;
		return (pipe_act(ERX_PIPE_OP_TAKE_LOCK));
	case R_RELOCKED:
		r->at = 0;
		r->phase = in->ok ? R_TAKEUP : R_LOCK_WOKE;
		return (pipe_act(in->ok ? ERX_PIPE_OP_CLEAR_WAITER :
		    ERX_PIPE_OP_WAIT));
	case R_LOCK_WOKE:
		r->phase = R_LOCK;
		return (pipe_act(ERX_PIPE_OP_CLEAR_WAITER));

	/* Step 2: the reports; a lane gone and drained is noticed once. */
	case R_TAKEUP:
		if (r->lost)
			return (pipe_release(r, R_AFTER_DONE, -EIO));
		for (; r->at < r->nlanes; r->at++) {
			lane = &r->lanes[r->at];
			if (lane->writer == ERX_PIPE_WRITER_GONE &&
			    lane->ring != ERX_PIPE_RING_LIVE && !lane->noticed) {
				lane->noticed = true;
				return (pipe_lane_act(ERX_PIPE_OP_DRAINED,
				    r->at++));
			}
		}
		r->phase = R_SETTLE;
		return (erx_pipe_rstep(r, NULL));

	/* Step 3: settle the current record by the lock page's table. */
	case R_SETTLE:
		r->phase = R_CUR;
		return (pipe_act(ERX_PIPE_OP_COPY_CUR));
	case R_CUR:
		r->cur = ERX_PIPE_LANE_NONE;
		for (at = 0; at < r->nlanes; at++)
			if (r->lanes[at].wend == in->cur &&
			    r->lanes[at].ring == ERX_PIPE_RING_LIVE)
				r->cur = at;
		if (r->cur == ERX_PIPE_LANE_NONE) {
			if (in->cur == ERX_PIPE_NONE) {
				r->phase = R_PICK;
				return (erx_pipe_rstep(r, NULL));
			}
			return (pipe_clear_cur(r));
		}
		r->cur_off = in->cur_off;
		r->cur_pos = in->cur_pos;
		r->phase = R_CUR_RPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_RPOS, r->cur));
	case R_CUR_RPOS:
		r->lanes[r->cur].rpos = in->value;
		if (in->value == r->cur_pos) {
			r->phase = R_CUR_WPOS;
			return (pipe_lane_act(ERX_PIPE_OP_LOAD_WPOS, r->cur));
		}
		/* Not at the record: finished by another reader, or nothing. */
		return (pipe_clear_cur(r));
	case R_CUR_WPOS:
		r->wpos = in->value;
		copy = (erx_ring_copy_t){ .rpos = r->cur_pos, .wpos = r->wpos,
		    .kind = PIPE_NO_KIND };
		if (erx_ring_check(r->lanes[r->cur].size, &copy) !=
		    ERX_RING_KIND)
			return (pipe_clear_cur(r));
		r->phase = R_CUR_REC;
		act = pipe_lane_act(ERX_PIPE_OP_COPY_REC, r->cur);
		act.pos = r->cur_pos;
		return (act);
	case R_CUR_REC:
		copy = (erx_ring_copy_t){ .rpos = r->cur_pos, .wpos = r->wpos,
		    .kind = in->kind, .len = in->len };
		settle = (erx_pipe_cur_copy_t){ .cur = r->lanes[r->cur].wend,
		    .cur_off = r->cur_off, .cur_pos = r->cur_pos, .held = true,
		    .rpos = r->cur_pos, .len = in->len,
		    .record_sound = in->kind == ERX_REC_DATA &&
		    erx_ring_check(r->lanes[r->cur].size, &copy) ==
		    ERX_RING_SOUND };
		r->cur_len = in->len;
		switch (erx_pipe_settle(&settle)) {
		case ERX_PIPE_SETTLE_CONTINUE:
			return (pipe_claim(r));
		case ERX_PIPE_SETTLE_RETIRE:
			return (pipe_finish(r));
		case ERX_PIPE_SETTLE_FINISHED:
		case ERX_PIPE_SETTLE_NONE:
			break;
		}
		return (pipe_clear_cur(r));

	/*
	 * Step 4: look at every lane; if one holds a record, compare wends
	 * with the write ends known, look again at the lanes found empty and
	 * those taken up, and pick by order key.
	 */
	case R_PICK:
		r->scan = r->nlanes;
		r->at = 0;
		r->second = false;
		r->any = false;
		for (at = 0; at < r->nlanes; at++)
			r->lanes[at].has_rec = false;
		r->phase = R_LANE;
		return (erx_pipe_rstep(r, NULL));
	case R_LANE:
		for (; r->at < r->scan; r->at++) {
			lane = &r->lanes[r->at];
			if (lane->ring != ERX_PIPE_RING_LIVE || lane->has_rec)
				continue;
			lane->gone = lane->writer == ERX_PIPE_WRITER_GONE;
			r->phase = R_LANE_RPOS;
			return (pipe_lane_act(ERX_PIPE_OP_LOAD_RPOS, r->at));
		}
		r->phase = R_LOOKED;
		return (erx_pipe_rstep(r, NULL));
	case R_LANE_RPOS:
		lane->rpos = in->value;
		pipe_close_batches(lane);
		if (lane->nbatches < pipe_batches(r)) {
			r->phase = R_LANE_CLOCK;
			return (pipe_act(ERX_PIPE_OP_CLOCK));
		}
		/* Every batch open: no new copy of wpos until one closes. */
		r->wpos = lane->batch[lane->nbatches - 1].end;
		return (pipe_lane_wpos(r));
	case R_LANE_CLOCK:
		r->clock = in->value;
		r->phase = R_LANE_WPOS;
		return (pipe_lane_act(ERX_PIPE_OP_LOAD_WPOS, r->at));
	case R_LANE_WPOS:
		copy = (erx_ring_copy_t){ .rpos = lane->rpos, .wpos = in->value,
		    .kind = PIPE_NO_KIND };
		fault = erx_ring_check(lane->size, &copy);
		if (fault != ERX_RING_SOUND && fault != ERX_RING_KIND)
			return (pipe_break(r, fault));
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
		return (pipe_lane_wpos(r));
	case R_LANE_REC:
		copy = (erx_ring_copy_t){ .rpos = lane->rpos, .wpos = r->wpos,
		    .kind = in->kind, .len = in->len };
		fault = erx_ring_check(lane->size, &copy);
		if (fault != ERX_RING_SOUND)
			return (pipe_break(r, fault));
		/* A control record waits for the second tier (fails safe). */
		if (in->kind != ERX_REC_DATA)
			return (pipe_break(r, ERX_RING_KIND));
		lane->has_rec = true;
		lane->len = in->len;
		lane->key = in->stamp > lane->batch[0].mark ?
		    in->stamp : lane->batch[0].mark;
		r->any = true;
		/* FALLTHROUGH */
	case R_LANE_NEXT:
		r->at++;
		r->phase = R_LANE;
		return (erx_pipe_rstep(r, NULL));
	case R_LOOKED:
		if (!r->any)
			break;		/* to step 7 */
		if (!r->second) {
			r->phase = R_WENDS;
			return (pipe_act(ERX_PIPE_OP_COPY_WENDS));
		}
		r->cur = pipe_choose(r);
		if (r->cur == ERX_PIPE_LANE_NONE)
			break;
		r->cur_pos = r->lanes[r->cur].rpos;
		r->cur_len = r->lanes[r->cur].len;
		r->cur_off = 0;
		return (pipe_claim(r));
	case R_WENDS:
		/* A write end the reports have not named yet: wait for it. */
		if (in->value > r->known)
			return (pipe_release(r, R_AFTER_REPORT, 0));
		r->second = true;
		r->scan = r->nlanes;
		r->at = 0;
		r->phase = R_LANE;
		return (erx_pipe_rstep(r, NULL));

	/* Steps 5 and 6: claim, copy, finish, and ring the writer. */
	case R_COPY:
		r->phase = R_COPIED;
		act = pipe_lane_act(ERX_PIPE_OP_COPY_DATA, r->cur);
		act.pos = r->cur_pos + PIPE_GRAIN + r->cur_off;
		act.n = r->claim;
		act.off = r->done;
		return (act);
	case R_COPIED:
		r->done += r->claim;
		r->cur_off += r->claim;
		if (r->cur_off == r->cur_len)
			return (pipe_finish(r));
		/* The buffer is full; the record stays current. */
		return (pipe_release(r, R_AFTER_DONE, (int64_t)r->done));
	case R_FINISH_CUR:
		r->phase = R_FINISH_FENCE;
		return (pipe_act(ERX_PIPE_OP_STORE_CUR));
	case R_FINISH_FENCE:
		r->phase = R_NEED;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case R_NEED:
		r->phase = R_NEED_IN;
		return (pipe_lane_act(ERX_PIPE_OP_COPY_NEED, r->cur));
	case R_NEED_IN:
		next = r->cur_pos + erx_ring_span(r->cur_len);
		at = r->cur;
		r->lanes[at].rpos = next;
		pipe_close_batches(&r->lanes[at]);
		r->cur = ERX_PIPE_LANE_NONE;
		r->phase = R_MORE;
		if (pipe_crossed(r->cur_pos, next, in->value))
			return (pipe_lane_act(ERX_PIPE_OP_RING_WRITER, at));
		/* FALLTHROUGH */
	case R_MORE:
		if (r->done < r->len) {
			r->phase = R_PICK;
			return (erx_pipe_rstep(r, NULL));
		}
		return (pipe_release(r, R_AFTER_DONE, (int64_t)r->done));

	/* Step 7: the end of the stream, EAGAIN, or sleep. */
	case R_ARM:
		for (; r->at < r->scan; r->at++) {
			lane = &r->lanes[r->at];
			if (lane->ring == ERX_PIPE_RING_LIVE &&
			    lane->writer == ERX_PIPE_WRITER_OPEN) {
				r->phase = R_ARM_WAKE;
				return (pipe_lane_act(ERX_PIPE_OP_SET_SLEEPER,
				    r->at));
			}
		}
		r->armed = true;
		r->phase = R_PICK;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case R_ARM_WAKE:
		r->phase = R_ARM_NEXT;
		return (pipe_value_act(ERX_PIPE_OP_STORE_WAKE, r->at,
		    lane->rpos + 1));
	case R_ARM_NEXT:
		r->at++;
		r->phase = R_ARM;
		return (erx_pipe_rstep(r, NULL));

	/* Step 8: release the lock and ring its waiters. */
	case R_RELEASED:
		r->phase = R_WAITERS;
		return (pipe_act(ERX_PIPE_OP_FENCE));
	case R_WAITERS:
		r->phase = R_WAITERS_IN;
		return (pipe_act(ERX_PIPE_OP_COPY_WAITERS));
	case R_WAITERS_IN:
		r->phase = R_AFTER;
		if ((in->value & ~(UINT64_C(1) << r->rix)) != 0)
			return (pipe_value_act(ERX_PIPE_OP_RING_READERS,
			    ERX_PIPE_LANE_NONE,
			    in->value & ~(UINT64_C(1) << r->rix)));
		/* FALLTHROUGH */
	case R_AFTER:
		switch (r->after) {
		case R_AFTER_DATA:
			r->at = 0;
			r->phase = R_DATA_WOKE;
			return (pipe_act(ERX_PIPE_OP_WAIT));
		case R_AFTER_REPORT:
			r->armed = false;
			r->phase = R_LOCK;
			return (pipe_act(ERX_PIPE_OP_WAIT));
		default:
			return (pipe_done(r->result));
		}
	case R_DATA_WOKE:
		for (; r->at < r->nlanes; r->at++)
			if (r->lanes[r->at].ring == ERX_PIPE_RING_LIVE)
				return (pipe_lane_act(ERX_PIPE_OP_CLEAR_SLEEPER,
				    r->at++));
		r->armed = false;
		r->phase = R_LOCK;
		return (erx_pipe_rstep(r, NULL));
	default:
		return (pipe_done(-EIO));
	}

	/* Step 7, reached from R_LOOKED when no lane holds a record. */
	if (r->done > 0)
		return (pipe_release(r, R_AFTER_DONE, (int64_t)r->done));
	if (pipe_ended(r))
		return (pipe_release(r, R_AFTER_DONE, 0));
	if (r->nonblock)
		return (pipe_release(r, R_AFTER_DONE, -EAGAIN));
	if (r->armed)
		return (pipe_release(r, R_AFTER_DATA, 0));
	r->at = 0;
	r->phase = R_ARM;
	return (erx_pipe_rstep(r, NULL));
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
