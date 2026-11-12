/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe core's exploration (docs/design-pipes.md, "The pipe core"), run
 * by test/host/pipe_core_test.rb over the real steps of
 * liberx/erx_pipe_core.c: one pipe with one write end and one read end, a
 * ring of 128 bytes and records of at most 16 bytes.
 *
 * The model performs every action the steps return on a memory of the
 * pipe's shared pages.  Store visibility follows design-pipes.md's
 * memory-order reading: each party's stores wait in its own buffer until
 * a flush event commits one, and a party reads its own buffered stores
 * first.  A plain store may commit before an earlier store to another
 * place, a release store only after every earlier one, and a full fence
 * waits for the party's buffer to drain; the lock's compare-and-swap
 * waits for the party's buffered stores to the lock word.  Loads are not
 * reordered: the acquire loads' pairing with release stores is what the
 * check-litmus suite covers.
 *
 * The events are: a step of either party, asked for its next action, and
 * the action's performance, apart so that a report can land between them, a flush of one buffered store, the
 * start of a write of the scenario's next length or of a read, the write
 * end's close, either holder's death or close where the scenario allows
 * it, each party's event executor applying the report of the other's
 * going (which wakes the party), the reader's call made afresh while it
 * waits, as the session's pipe NIF makes it, to read again or, of 0 bytes,
 * to give the wait up, and in a hostile scenario one rewrite of
 * a shared field by the other party.  The exploration is depth first over
 * every interleaving, with each state's 64-bit fingerprint kept so a
 * state is explored once.  After every event it checks:
 *
 *   PI2  a read returns 0 only once the write end has gone and every byte
 *        it published has been read, and no bytes follow the end of the
 *        stream; the lane is reported drained once, and only then;
 *   PI3  a write fails with EPIPE only once the read end's going has been
 *        applied, and with EAGAIN only on a non-blocking end;
 *   PI4  no step loops: a party takes at most STEPS_MAX steps without a
 *        wait or the end of its call, and nothing reads or writes outside
 *        the model's memory (the address sanitizer);
 *   PI5, PI6  every byte a read copies is the next byte of the stream, so
 *        no byte is lost, repeated or reordered and no record is torn;
 *   PI7  no party sleeps with what it waits for ready while its peer is
 *        idle with no store left to make; and a state from which no event
 *        can follow has both calls finished:
 *        the writer closed or dead and the reader at the end of the stream
 *        or gone; a party asleep there lost a wakeup; and an idle reader
 *        holds no sleepers or waiters bit, which only a wait in progress
 *        may hold.
 *
 * A hostile scenario checks only what the honest party must keep: no
 * loop, no error but its own (a broken lane, EAGAIN, EPIPE), and no access
 * outside memory.  The program's argument names the scenario; it prints
 * the states and the depth reached, or the failed property and the trace.
 * Each scenario has two sets of write lengths: the landing gate's, which
 * fit make check under the sanitizers, and the milestone gate's deeper
 * ones, which tools/erx check-fuzz runs.  Either way every interleaving
 * is explored to its end, not to a depth bound.
 */

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/pipe.h"

#define RING		128u
#define CHUNK		16u
#define GRAIN		16u
#define SLOTS		(RING / GRAIN)
#define BUFFERED_MAX	6
#define WRITES_MAX	4
#define STEPS_MAX	256
#define DEPTH_MAX	4096

/* The places a party stores to. */
enum loc {
	L_WPOS, L_NEED, L_RPOS, L_WAKE, L_SLEEPERS, L_OWNER, L_WAITERS, L_CUR,
	L_AREA			/* one 16-byte slot of the data area */
};

enum rmw { PLAIN = 0, OR, ANDNOT };

typedef struct store {
	uint8_t		 loc;
	uint8_t		 release;
	uint8_t		 rmw;
	uint8_t		 slot;		/* L_AREA */
	uint32_t	 a;		/* L_CUR: cur_off; L_WPOS: stream end */
	uint32_t	 b;		/* L_CUR: cur */
	uint32_t	 pad;
	uint64_t	 value;
	uint8_t		 bytes[GRAIN];
} store_t;

typedef struct mem {
	uint64_t	 wpos, need, rpos, wake, sleepers, waiters, cur_pos;
	uint32_t	 owner, wends, cur, cur_off;
	uint8_t		 area[RING];
} mem_t;

enum pstate { IDLE = 0, CALL, CLOSED, DEAD, ENDED };

/* A holder: its end's state, its pending action and its store buffer. */
typedef struct party {
	uint8_t		 state;
	uint8_t		 bell;		/* a ring latched until a wait */
	uint8_t		 report;	/* the other's going, not yet applied */
	uint8_t		 nbuf;
	uint8_t		 decided;	/* act is the step's answer to in */
	uint8_t		 pad[3];
	uint32_t	 steps;		/* since the last wait or call's end */
	uint64_t	 base;		/* the stream offset of the call's buffer */
	erx_pipe_act_t	 act;
	erx_pipe_in_t	 in;
	store_t		 buf[BUFFERED_MAX];
} party_t;

typedef struct world {
	mem_t		 mem;
	party_t		 w, r;
	erx_pipe_wstate_t ws;
	erx_pipe_rstate_t rs;
	erx_pipe_rlane_t lane;
	uint32_t	 writes;	/* writes started */
	uint64_t	 written;	/* stream bytes the writer's calls took */
	uint64_t	 published;	/* stream bytes behind the committed wpos */
	uint64_t	 received;	/* stream bytes reads returned */
	uint8_t		 eof;
	uint8_t		 drained;
	uint8_t		 hostile;	/* the rewrite happened */
	uint8_t		 quit;		/* the read is a wait given up */
	uint8_t		 pad[4];
} world_t;

typedef struct scenario {
	const char	*name;
	uint32_t	 writes[WRITES_MAX];	/* at the landing gate */
	uint32_t	 deep[WRITES_MAX];	/* at the milestone gate */
	uint32_t	 nwrites;
	uint32_t	 read_len;
	bool		 nonblock;
	bool		 writer_dies;
	bool		 reader_closes;
	bool		 reader_dies;
	int		 hostile;	/* 0, or 'w' or 'r': whose rewrites */
} scenario_t;

static const scenario_t scenarios[] = {
	{ "flow", { 40, 24 }, { 40, 33 }, 2, 24, false, false, false, false, 0 },
	{ "partial", { 20, 7 }, { 40, 7 }, 2, 5, false, false, false, false, 0 },
	{ "nonblock", { 40, 9 }, { 40, 40 }, 2, 24, true, false, false, false, 0 },
	{ "writer-dies", { 24, 9 }, { 40, 33 }, 2, 24, false, true, false, false, 0 },
	{ "reader-closes", { 40, 9 }, { 40, 40 }, 2, 24, false, false, true, false, 0 },
	{ "reader-dies", { 24, 9 }, { 40, 40 }, 2, 24, false, false, false, true, 0 },
	{ "hostile-writer", { 16, 9 }, { 40, 9 }, 2, 24, false, false, false, false, 'w' },
	{ "hostile-reader", { 16, 9 }, { 40, 24 }, 2, 24, false, false, false, false, 'r' },
};

static const scenario_t *sc;
static const uint32_t *writes;	/* the scenario's lengths at this depth */
static world_t worlds[DEPTH_MAX];
static char trace[DEPTH_MAX][48];
static uint64_t *seen;
static uint64_t seen_size, seen_count, max_depth;

/* The stream's byte at offset k; its period is longer than the ring. */
static uint8_t
pattern(uint64_t k)
{
	return ((uint8_t)(1 + k % 251));
}

static void
fail(int depth, const char *property, const char *what)
{
	int i;

	printf("FAIL %s: %s\n", property, what);
	for (i = 1; i <= depth; i++)
		printf("  %d %s\n", i, trace[i]);
	exit(1);
}

static uint64_t
fingerprint(const world_t *wd)
{
	const unsigned char *p = (const unsigned char *)wd;
	uint64_t h = 0x9e3779b97f4a7c15u;
	size_t i;

	for (i = 0; i < sizeof(*wd); i++) {
		h ^= p[i];
		h *= 0x100000001b3u;
		h ^= h >> 29;
	}
	return (h | 1);
}

static bool
seen_insert(uint64_t h)
{
	uint64_t i;

	for (i = h & (seen_size - 1); seen[i] != 0; i = (i + 1) & (seen_size - 1))
		if (seen[i] == h)
			return (false);
	seen[i] = h;
	seen_count++;
	return (true);
}

/* Whether the state is new; remembers it. */
static bool
first_visit(const world_t *wd)
{
	uint64_t i, *old, old_size;

	if (seen_count * 2 >= seen_size) {
		old = seen;
		old_size = seen_size;
		seen_size = old_size == 0 ? UINT64_C(1) << 20 : old_size * 2;
		seen = calloc(seen_size, sizeof(*seen));
		if (seen == NULL)
			abort();
		seen_count = 0;
		for (i = 0; i < old_size; i++)
			if (old[i] != 0)
				(void)seen_insert(old[i]);
		free(old);
	}
	return (seen_insert(fingerprint(wd)));
}

static const char *const op_names[] = {
	"DONE", "CLOCK", "LOAD_RPOS", "LOAD_WPOS", "COPY_NEED", "COPY_WAKE",
	"COPY_SLEEPERS", "COPY_REC", "COPY_CUR", "COPY_WENDS", "COPY_WAITERS",
	"COPY_DATA", "WRITE_REC", "STORE_WPOS", "STORE_NEED", "STORE_RPOS",
	"STORE_WAKE", "STORE_CUR", "SET_SLEEPER", "CLEAR_SLEEPER", "SET_WAITER",
	"CLEAR_WAITER", "TAKE_LOCK", "RELEASE_LOCK", "FENCE", "RING_READERS",
	"RING_WRITER", "WAIT", "DRAINED", "BROKEN"
};

_Static_assert(sizeof(op_names) / sizeof(op_names[0]) == ERX_PIPE_OP_BROKEN + 1,
    "every op is named");

/* The stores the action buffers. */
static unsigned
stores_of(erx_pipe_op_t op)
{
	switch (op) {
	case ERX_PIPE_OP_WRITE_REC:
		return (2);
	case ERX_PIPE_OP_STORE_WPOS:
	case ERX_PIPE_OP_STORE_NEED:
	case ERX_PIPE_OP_STORE_RPOS:
	case ERX_PIPE_OP_STORE_WAKE:
	case ERX_PIPE_OP_STORE_CUR:
	case ERX_PIPE_OP_SET_SLEEPER:
	case ERX_PIPE_OP_CLEAR_SLEEPER:
	case ERX_PIPE_OP_SET_WAITER:
	case ERX_PIPE_OP_CLEAR_WAITER:
	case ERX_PIPE_OP_RELEASE_LOCK:
		return (1);
	default:
		return (0);
	}
}

static bool
buffers(const party_t *p, uint8_t loc)
{
	int i;

	for (i = 0; i < p->nbuf; i++)
		if (p->buf[i].loc == loc)
			return (true);
	return (false);
}

/* Whether the party's pending action can be performed now. */
static bool
ready(const party_t *p)
{
	if (p->state != CALL || !p->decided)
		return (false);
	switch (p->act.op) {
	case ERX_PIPE_OP_FENCE:
		return (p->nbuf == 0);
	case ERX_PIPE_OP_WAIT:
		return (p->bell != 0);
	case ERX_PIPE_OP_TAKE_LOCK:
		return (!buffers(p, L_OWNER));
	default:
		return (p->nbuf + stores_of(p->act.op) <= BUFFERED_MAX);
	}
}

static bool
same_place(const store_t *a, const store_t *b)
{
	return (a->loc == b->loc && (a->loc != L_AREA || a->slot == b->slot));
}

/* A release store follows every earlier store; any store, earlier ones to its place. */
static bool
flushable(const party_t *p, int j)
{
	int i;

	for (i = 0; i < j; i++)
		if (p->buf[j].release || same_place(&p->buf[i], &p->buf[j]))
			return (false);
	return (true);
}

static uint64_t
rmw_apply(uint64_t old, const store_t *s)
{
	switch (s->rmw) {
	case OR:
		return (old | s->value);
	case ANDNOT:
		return (old & ~s->value);
	default:
		return (s->value);
	}
}

static uint64_t *
mem_word(mem_t *m, uint8_t loc)
{
	switch (loc) {
	case L_WPOS:
		return (&m->wpos);
	case L_NEED:
		return (&m->need);
	case L_RPOS:
		return (&m->rpos);
	case L_WAKE:
		return (&m->wake);
	case L_SLEEPERS:
		return (&m->sleepers);
	case L_WAITERS:
		return (&m->waiters);
	default:
		return (NULL);
	}
}

static void
commit(world_t *wd, party_t *p, int j)
{
	const store_t *s = &p->buf[j];
	uint64_t *word;

	switch (s->loc) {
	case L_AREA:
		memcpy(&wd->mem.area[s->slot * GRAIN], s->bytes, GRAIN);
		break;
	case L_OWNER:
		wd->mem.owner = (uint32_t)s->value;
		break;
	case L_CUR:
		wd->mem.cur = s->b;
		wd->mem.cur_off = s->a;
		wd->mem.cur_pos = s->value;
		break;
	default:
		word = mem_word(&wd->mem, s->loc);
		*word = rmw_apply(*word, s);
		if (s->loc == L_WPOS && !wd->hostile)
			wd->published = s->a;
		break;
	}
	memmove(&p->buf[j], &p->buf[j + 1], (size_t)(p->nbuf - j - 1) *
	    sizeof(p->buf[0]));
	p->nbuf--;
	memset(&p->buf[p->nbuf], 0, sizeof(p->buf[0]));
}

/* A load of a word: memory, then the party's own buffered stores to it. */
static uint64_t
load(world_t *wd, const party_t *p, uint8_t loc)
{
	uint64_t v;
	int i;

	v = *mem_word(&wd->mem, loc);
	for (i = 0; i < p->nbuf; i++)
		if (p->buf[i].loc == loc)
			v = rmw_apply(v, &p->buf[i]);
	return (v);
}

static store_t *
push(party_t *p, uint8_t loc, bool release, uint8_t rmw, uint64_t value)
{
	store_t *s = &p->buf[p->nbuf++];

	memset(s, 0, sizeof(*s));
	s->loc = loc;
	s->release = release;
	s->rmw = rmw;
	s->value = value;
	return (s);
}

static void
put_le(uint8_t *at, uint64_t v, int n)
{
	int i;

	for (i = 0; i < n; i++)
		at[i] = (uint8_t)(v >> (8 * i));
}

static uint64_t
get_le(const uint8_t *area, uint64_t pos, int n)
{
	uint64_t v = 0;
	int i;

	for (i = n - 1; i >= 0; i--)
		v = v << 8 | area[(pos + (uint64_t)i) % RING];
	return (v);
}

static bool
writer_gone(const world_t *wd)
{
	return (wd->w.state == CLOSED || wd->w.state == DEAD);
}

static void
next_action(world_t *wd, party_t *p)
{
	if (p == &wd->w) {
		p->act = erx_pipe_wstep(&wd->ws, &p->in);
		p->decided = 1;
	} else {
		wd->rs.lanes = &wd->lane;
		p->act = erx_pipe_rstep(&wd->rs, &p->in);
		wd->rs.lanes = NULL;
		p->decided = 1;
	}
}

static void
writer_done(world_t *wd, int depth, int64_t result)
{
	if (result == -EPIPE && wd->ws.readers != 0)
		fail(depth, "PI3", "EPIPE while a read end remains");
	if (result == -EAGAIN && !sc->nonblock)
		fail(depth, "PI3", "EAGAIN on a blocking write end");
	if (result < 0 && result != -EPIPE && result != -EAGAIN)
		fail(depth, "PI3", "a write failed with another error");
	if (result >= 0 && (uint64_t)result != wd->ws.len && !sc->nonblock &&
	    wd->ws.readers != 0)
		fail(depth, "PI3", "a blocking write returned short");
	if (result > 0)
		wd->written = wd->w.base + (uint64_t)result;
	wd->w.state = IDLE;
}

static void
reader_done(world_t *wd, int depth, int64_t result)
{
	if (wd->quit) {
		if (result != 0)
			fail(depth, "PI2", "a read of 0 bytes returned something");
		wd->quit = 0;
		wd->r.state = IDLE;
		return;
	}
	if (result > 0 && wd->eof)
		fail(depth, "PI2", "bytes after the end of the stream");
	if (result == 0) {
		/* A broken lane counts as gone and drained (design "The ring"). */
		if (!writer_gone(wd) && wd->lane.ring != ERX_PIPE_RING_BROKEN)
			fail(depth, "PI2", "the end of the stream while the writer is open");
		if (!wd->hostile && wd->received != wd->published)
			fail(depth, "PI2", "the end of the stream before every published byte was read");
		wd->eof++;
	}
	if (result == -EAGAIN && !sc->nonblock)
		fail(depth, "PI2", "EAGAIN on a blocking read end");
	if (result < 0 && result != -EAGAIN)
		fail(depth, "PI2", "a read failed with another error");
	if (result > 0)
		wd->received += (uint64_t)result;
	wd->r.state = wd->eof >= 2 ? ENDED : IDLE;
}

static void
copy_data(world_t *wd, int depth, const erx_pipe_act_t *a)
{
	uint64_t i;

	if (a->lane != 0 || a->off + a->n > sc->read_len || a->n == 0 ||
	    a->n > CHUNK)
		fail(depth, "PI4", "a copy outside the lane or the buffer");
	for (i = 0; i < a->n && !wd->hostile; i++)
		if (wd->mem.area[(a->pos + i) % RING] !=
		    pattern(wd->r.base + a->off + i))
			fail(depth, "PI5", "a byte read out of the stream's order");
}

static void
write_rec(world_t *wd, int depth, const erx_pipe_act_t *a)
{
	store_t *s;
	uint64_t i;

	if (a->n == 0 || a->n > CHUNK || a->off + a->n > wd->ws.len ||
	    a->pos % GRAIN != 0)
		fail(depth, "PI4", "a record outside the chunk or the buffer");
	s = push(&wd->w, L_AREA, false, PLAIN, 0);
	s->slot = (uint8_t)((a->pos % RING) / GRAIN);
	put_le(s->bytes, a->n, 4);
	put_le(s->bytes + 4, ERX_REC_DATA, 4);
	put_le(s->bytes + 8, a->value, 8);
	s = push(&wd->w, L_AREA, false, PLAIN, 0);
	s->slot = (uint8_t)(((a->pos + GRAIN) % RING) / GRAIN);
	for (i = 0; i < a->n; i++)
		s->bytes[i] = pattern(wd->w.base + a->off + i);
}

/* Performs the party's pending action, then asks its step for the next. */
static void
perform(world_t *wd, party_t *p, int depth)
{
	const erx_pipe_act_t a = p->act;
	bool writer = p == &wd->w;
	uint64_t bit = UINT64_C(1) << wd->rs.rix;
	store_t *s;

	memset(&p->in, 0, sizeof(p->in));
	p->steps++;
	switch (a.op) {
	case ERX_PIPE_OP_DONE:
		p->steps = 0;
		if (writer)
			writer_done(wd, depth, a.result);
		else
			reader_done(wd, depth, a.result);
		return;
	case ERX_PIPE_OP_CLOCK:
		p->in.value = 0;	/* one lane's order needs no clock */
		break;
	case ERX_PIPE_OP_LOAD_RPOS:
		p->in.value = load(wd, p, L_RPOS);
		break;
	case ERX_PIPE_OP_LOAD_WPOS:
		p->in.value = load(wd, p, L_WPOS);
		break;
	case ERX_PIPE_OP_COPY_NEED:
		p->in.value = load(wd, p, L_NEED);
		break;
	case ERX_PIPE_OP_COPY_WAKE:
		p->in.value = load(wd, p, L_WAKE);
		break;
	case ERX_PIPE_OP_COPY_SLEEPERS:
		p->in.value = load(wd, p, L_SLEEPERS);
		break;
	case ERX_PIPE_OP_COPY_WAITERS:
		p->in.value = load(wd, p, L_WAITERS);
		break;
	case ERX_PIPE_OP_COPY_REC:
		if (a.pos % GRAIN != 0)
			fail(depth, "PI4", "a record header copied off the grain");
		p->in.len = (uint32_t)get_le(wd->mem.area, a.pos, 4);
		p->in.kind = (uint32_t)get_le(wd->mem.area, a.pos + 4, 4);
		p->in.stamp = get_le(wd->mem.area, a.pos + 8, 8);
		break;
	case ERX_PIPE_OP_COPY_CUR:
		p->in.cur = wd->mem.cur;
		p->in.cur_off = wd->mem.cur_off;
		p->in.cur_pos = wd->mem.cur_pos;
		for (int i = 0; i < p->nbuf; i++)
			if (p->buf[i].loc == L_CUR) {
				p->in.cur = p->buf[i].b;
				p->in.cur_off = p->buf[i].a;
				p->in.cur_pos = p->buf[i].value;
			}
		break;
	case ERX_PIPE_OP_COPY_WENDS:
		p->in.value = wd->mem.wends;
		break;
	case ERX_PIPE_OP_COPY_DATA:
		copy_data(wd, depth, &a);
		break;
	case ERX_PIPE_OP_WRITE_REC:
		write_rec(wd, depth, &a);
		break;
	case ERX_PIPE_OP_STORE_WPOS:
		s = push(p, L_WPOS, true, PLAIN, a.value);
		s->a = (uint32_t)(wd->w.base + wd->ws.done + wd->ws.rec);
		break;
	case ERX_PIPE_OP_STORE_NEED:
		push(p, L_NEED, true, PLAIN, a.value);
		break;
	case ERX_PIPE_OP_STORE_RPOS:
		push(p, L_RPOS, true, PLAIN, a.value);
		break;
	case ERX_PIPE_OP_STORE_WAKE:
		push(p, L_WAKE, true, PLAIN, a.value);
		break;
	case ERX_PIPE_OP_STORE_CUR:
		s = push(p, L_CUR, false, PLAIN, a.pos);
		s->a = (uint32_t)a.n;
		s->b = a.lane == ERX_PIPE_LANE_NONE ? ERX_PIPE_NONE : wd->lane.wend;
		break;
	case ERX_PIPE_OP_SET_SLEEPER:
		push(p, L_SLEEPERS, false, OR, bit);
		break;
	case ERX_PIPE_OP_CLEAR_SLEEPER:
		push(p, L_SLEEPERS, false, ANDNOT, bit);
		break;
	case ERX_PIPE_OP_SET_WAITER:
		push(p, L_WAITERS, false, OR, bit);
		break;
	case ERX_PIPE_OP_CLEAR_WAITER:
		push(p, L_WAITERS, false, ANDNOT, bit);
		break;
	case ERX_PIPE_OP_TAKE_LOCK:
		p->in.ok = wd->mem.owner == 0;
		if (p->in.ok)
			wd->mem.owner = 1 + wd->rs.rix;
		break;
	case ERX_PIPE_OP_RELEASE_LOCK:
		push(p, L_OWNER, true, PLAIN, 0);
		break;
	case ERX_PIPE_OP_FENCE:
		break;
	case ERX_PIPE_OP_RING_READERS:
		if (writer && (a.value & bit) != 0)
			wd->r.bell = 1;
		break;
	case ERX_PIPE_OP_RING_WRITER:
		wd->w.bell = 1;
		break;
	case ERX_PIPE_OP_WAIT:
		p->bell = 0;
		p->steps = 0;
		break;
	case ERX_PIPE_OP_DRAINED:
		if (!writer_gone(wd) || wd->drained++ != 0 || (!wd->hostile &&
		    wd->received + wd->rs.done != wd->published))
			fail(depth, "PI2", "a lane reported drained before it was");
		break;
	case ERX_PIPE_OP_BROKEN:
		if (!wd->hostile)
			fail(depth, "PI5", "an honest writer's lane found broken");
		break;
	}
	if (p->steps > STEPS_MAX)
		fail(depth, "PI4", "a step loops without waiting or ending");
	p->decided = 0;
}

/* One rewrite of a shared field by a hostile peer of the honest party. */
static bool
rewrite(world_t *wd, int k)
{
	mem_t *m = &wd->mem;
	uint8_t *rec = &m->area[m->rpos % RING / GRAIN * GRAIN];

	if (sc->hostile == 'w') {
		switch (k) {
		case 0: m->wpos += GRAIN; return (true);
		case 1: m->wpos = m->rpos + RING + GRAIN; return (true);
		case 2: m->wpos |= 8; return (true);
		case 3: m->wpos = m->rpos - GRAIN; return (true);
		case 4: put_le(rec + 4, ERX_REC_FRAME, 4); return (true);
		case 5: put_le(rec, ERX_PIPE_BUF + 1, 4); return (true);
		case 6: put_le(rec, 8, 4); put_le(rec + 4, ERX_REC_CONTROL, 4);
			return (true);
		}
	} else {
		switch (k) {
		case 0: m->rpos = m->wpos + GRAIN; return (true);
		case 1: m->rpos |= 8; return (true);
		case 2: m->rpos = m->wpos - RING - GRAIN; return (true);
		case 3: m->wake = 0; return (true);
		case 4: m->wake = UINT64_MAX; return (true);
		case 5: m->sleepers = UINT64_MAX; return (true);
		}
	}
	return (false);
}

static void explore(int depth);

static world_t *
successor(int depth, const char *what, const char *detail)
{
	worlds[depth + 1] = worlds[depth];
	snprintf(trace[depth + 1], sizeof(trace[0]), "%s%s", what, detail);
	return (&worlds[depth + 1]);
}

static void
visit(int depth)
{
	if (first_visit(&worlds[depth]))
		explore(depth);
}

/* A state from which no event follows must have both calls finished. */
static void
check_end(int depth)
{
	const world_t *wd = &worlds[depth];

	if (sc->hostile != 0)
		return;
	if (!writer_gone(wd))
		fail(depth, "PI7", "the writer sleeps for good (a lost wakeup)");
	if (wd->r.state != ENDED && wd->r.state != CLOSED &&
	    wd->r.state != DEAD)
		fail(depth, "PI7", "the reader sleeps for good (a lost wakeup)");
}

/*
 * A party asleep that nothing will wake, though its peer is idle with no
 * store left to make: the reader with published bytes unread, or the
 * writer with room for its record.  The peer's close or a report would
 * wake it later, so this is checked in every state, not only at the end.
 */
static void
check_asleep(int depth)
{
	const world_t *wd = &worlds[depth];
	bool r_asleep, w_asleep;

	if (sc->hostile != 0)
		return;
	r_asleep = wd->r.state == CALL && wd->r.decided && wd->r.bell == 0 &&
	    wd->r.act.op == ERX_PIPE_OP_WAIT;
	w_asleep = wd->w.state == CALL && wd->w.decided && wd->w.bell == 0 &&
	    wd->w.act.op == ERX_PIPE_OP_WAIT;
	if (r_asleep && wd->w.state == IDLE && wd->w.nbuf == 0 &&
	    wd->published > wd->received + wd->rs.done)
		fail(depth, "PI7", "the reader sleeps past published bytes (a lost wakeup)");
	if (w_asleep && (wd->r.state == IDLE || r_asleep) && wd->r.nbuf == 0 &&
	    wd->ws.readers != 0 && erx_ring_room(RING, wd->ws.wpos,
	    wd->mem.rpos) >= erx_ring_span(wd->ws.rec))
		fail(depth, "PI7", "the writer sleeps with room free (a lost wakeup)");
}

/*
 * The reader's sleepers and waiters bits are set only for a wait in
 * progress: an idle reader whose stores have landed holds neither, or
 * every co-reader's wait would ring it.  A lane closed once drained is
 * let go of and rung by no writer, so its sleepers bit no longer counts.
 */
static void
check_idle_bits(int depth)
{
	const world_t *wd = &worlds[depth];
	uint64_t bit = UINT64_C(1) << wd->rs.rix;

	if (sc->hostile != 0 || wd->r.state != IDLE || wd->r.nbuf != 0)
		return;
	if (wd->lane.ring == ERX_PIPE_RING_LIVE && (wd->mem.sleepers & bit) != 0)
		fail(depth, "PI7", "an idle reader left its sleepers bit set");
	if ((wd->mem.waiters & bit) != 0)
		fail(depth, "PI7", "an idle reader left its waiters bit set");
}

static void
explore(int depth)
{
	world_t *cur = &worlds[depth], *nw;
	party_t *parties[2] = { &cur->w, &cur->r };
	int events = 0, i, j, k;

	if ((uint64_t)depth > max_depth)
		max_depth = (uint64_t)depth;
	if (depth + 1 >= DEPTH_MAX)
		fail(depth, "depth", "the model's depth bound was reached");
	check_asleep(depth);
	check_idle_bits(depth);
	for (i = 0; i < 2; i++) {
		/* The step decides apart from the action, so reports land between. */
		if (parties[i]->state == CALL && !parties[i]->decided) {
			nw = successor(depth, i == 0 ? "W step" : "R step", "");
			next_action(nw, i == 0 ? &nw->w : &nw->r);
			visit(depth + 1);
			events++;
		}
		if (ready(parties[i])) {
			nw = successor(depth, i == 0 ? "W " : "R ",
			    op_names[parties[i]->act.op]);
			perform(nw, i == 0 ? &nw->w : &nw->r, depth + 1);
			visit(depth + 1);
			events++;
		}
		for (j = 0; j < parties[i]->nbuf; j++) {
			if (!flushable(parties[i], j))
				continue;
			nw = successor(depth, i == 0 ? "W flush" : "R flush", "");
			commit(nw, i == 0 ? &nw->w : &nw->r, j);
			visit(depth + 1);
			events++;
		}
	}
	if (cur->w.state == IDLE && cur->writes < sc->nwrites) {
		nw = successor(depth, "W write", "");
		erx_pipe_wstart(&nw->ws, writes[nw->writes++]);
		nw->w.base = nw->written;
		nw->w.state = CALL;
		next_action(nw, &nw->w);
		visit(depth + 1);
		events++;
	}
	if ((cur->w.state == IDLE && cur->writes == sc->nwrites) ||
	    (sc->writer_dies && cur->w.state == CALL)) {
		nw = successor(depth, cur->w.state == IDLE ? "W close" : "W dies", "");
		nw->w.state = nw->w.state == IDLE ? CLOSED : DEAD;
		nw->w.report = 0;
		nw->r.report = 1;
		visit(depth + 1);
		events++;
	}
	if (cur->r.state == IDLE) {
		nw = successor(depth, "R read", "");
		erx_pipe_rstart(&nw->rs, sc->read_len);
		nw->r.base = nw->received;
		nw->r.state = CALL;
		next_action(nw, &nw->r);
		visit(depth + 1);
		events++;
	}
	/*
	 * The session's pipe NIF does not sleep at a wait: it returns, and its
	 * owner calls again, on a ring or a stray message, or, once its wait
	 * times out, with a read of 0 bytes.  Either call starts the read
	 * afresh while the wait is still in progress.
	 */
	if (cur->r.state == CALL && cur->r.decided &&
	    cur->r.act.op == ERX_PIPE_OP_WAIT) {
		for (k = 0; k < 2; k++) {
			nw = successor(depth, k == 0 ? "R reads again" :
			    "R gives up its wait", "");
			erx_pipe_rstart(&nw->rs, k == 0 ? sc->read_len : 0);
			nw->quit = k == 1;
			nw->r.steps = 0;
			next_action(nw, &nw->r);
			visit(depth + 1);
			events++;
		}
	}
	if ((sc->reader_closes && cur->r.state == IDLE && cur->eof == 0) ||
	    (sc->reader_dies && cur->r.state == CALL)) {
		nw = successor(depth, cur->r.state == IDLE ? "R close" : "R dies", "");
		nw->r.state = nw->r.state == IDLE ? CLOSED : DEAD;
		nw->r.report = 0;
		nw->w.report = 1;
		visit(depth + 1);
		events++;
	}
	if (cur->w.report && (cur->w.state == IDLE || cur->w.state == CALL)) {
		nw = successor(depth, "W applies the reader's going", "");
		nw->ws.readers = 0;
		nw->w.bell = 1;
		nw->w.report = 0;
		visit(depth + 1);
		events++;
	}
	/* The report travels by channel, after the writer's stores. */
	if (cur->r.report && cur->w.nbuf == 0 &&
	    (cur->r.state == IDLE || cur->r.state == CALL)) {
		nw = successor(depth, "R applies the writer's going", "");
		nw->lane.writer = ERX_PIPE_WRITER_GONE;
		nw->r.bell = 1;
		nw->r.report = 0;
		visit(depth + 1);
		events++;
	}
	for (k = 0; sc->hostile != 0 && !cur->hostile; k++) {
		nw = successor(depth, "hostile rewrite", "");
		if (!rewrite(nw, k))
			break;
		nw->hostile = 1;
		snprintf(trace[depth + 1], sizeof(trace[0]), "hostile rewrite %d", k);
		visit(depth + 1);
		events++;
	}
	if (events == 0)
		check_end(depth);
}

int
main(int argc, char **argv)
{
	world_t *wd = &worlds[0];
	size_t i;

	if (argc != 3 || (strcmp(argv[2], "landing") != 0 &&
	    strcmp(argv[2], "deep") != 0)) {
		fprintf(stderr, "usage: pipe_explore scenario landing|deep\n");
		return (2);
	}
	for (i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++)
		if (strcmp(argv[1], scenarios[i].name) == 0)
			sc = &scenarios[i];
	if (sc == NULL) {
		fprintf(stderr, "pipe_explore: no scenario %s\n", argv[1]);
		return (2);
	}
	writes = strcmp(argv[2], "deep") == 0 ? sc->deep : sc->writes;
	memset(wd, 0, sizeof(*wd));
	wd->mem.wends = 1;
	wd->ws.size = RING;
	wd->ws.chunk = CHUNK;
	wd->ws.readers = 1;
	wd->ws.nonblock = sc->nonblock;
	wd->rs.rix = 0;
	wd->rs.known = 1;
	wd->rs.batches = 2;
	wd->rs.nlanes = 1;
	wd->rs.nonblock = sc->nonblock;
	wd->lane.wend = 1;
	wd->lane.size = RING;
	wd->w.state = IDLE;
	wd->r.state = IDLE;
	(void)first_visit(wd);
	explore(0);
	printf("pipe_explore %s states %llu depth %llu\n", sc->name,
	    (unsigned long long)seen_count, (unsigned long long)max_depth);
	free(seen);
	return (0);
}
