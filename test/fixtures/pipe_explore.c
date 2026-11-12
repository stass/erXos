/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe core's exploration (docs/design-pipes.md, "The pipe core"), run
 * by test/host/pipe_core_test.rb over the real steps of
 * liberx/erx_pipe_core.c: one pipe with up to NW_MAX write ends and NR_MAX
 * read ends, rings of 128 bytes and records of at most 16 bytes.  Each
 * scenario picks a shape: one write end and one read end; two write ends
 * merged by one read end, the second of them joining mid-stream in some
 * scenarios; or one write end read by two co-readers that share the reader
 * lock.
 *
 * The model performs every action the steps return on a memory of the
 * pipe's shared pages: a ring header, a reader page and a data area for
 * each write end's lane, and the lock page.  Store visibility follows
 * design-pipes.md's memory-order reading: each party's stores wait in its
 * own buffer until a flush event commits one, and a party reads its own
 * buffered stores first.  A plain store may commit before an earlier store
 * to another place, a release store only after every earlier one, and a
 * full fence waits for the party's buffer to drain; the lock's
 * compare-and-swap waits for the party's buffered stores to the lock word.
 * Loads are not reordered: the acquire loads' pairing with release stores
 * is what the check-litmus suite covers (test/litmus/pipe-*.litmus).
 *
 * The events are: a step of any party, asked for its next action, and the
 * action's performance, apart so that a report can land between them; a
 * flush of one buffered store; the start of a write of a write end's next
 * length or of a read; a write end's close once its writes are done;
 * deaths and closes where the scenario allows them; each party's event
 * executor applying a report of the pipe server's (a write end's going,
 * which waits for that end's stores, a read end's going, a join, the
 * pipe's loss), each of which wakes the party; the pipe server freeing the
 * reader lock a gone read end held, once that end's stores have landed;
 * a read made afresh while the last one waits, as the session's pipe NIF
 * makes it, to read again or, of 0 bytes, to give the wait up; in a join
 * scenario the pipe server's store of wends, which installs the joining
 * write end; in a lost scenario the pipe's loss; and in a hostile scenario
 * one rewrite of a shared field.  The clock advances at every reading in
 * the shapes with two write ends, and reads 0 with one, whose order needs
 * no clock.  The exploration is depth first over every interleaving, with
 * each state's 64-bit fingerprint kept so a state is explored once.
 *
 * The model keeps a record of every record each write end wrote: its
 * stream offset and length, the bytes readers claimed of it in the lock
 * page, and, for PI6, the records of every write end that were published
 * before its stamp was read (the relation `before` gathers for each write
 * end at its last stamp and `after` keeps per record).  After every event
 * it checks:
 *
 *   PI2  a read returns 0 only once every write end installed has gone
 *        and every byte published has been claimed, and no bytes follow
 *        the end of the stream; a read end reports each lane drained once,
 *        and only then; a read fails with EIO only once the pipe's loss
 *        has been applied;
 *   PI3  a write fails with EPIPE only once no read end remains or the
 *        loss has been applied, and with EAGAIN only on a non-blocking end;
 *   PI4  no step loops: a party takes at most STEPS_MAX steps without a
 *        wait or the end of its call; nothing reads or writes outside the
 *        model's memory (the address sanitizer); and every copy stays in
 *        the call's buffer and the claimed record;
 *   PI5  claims are made under the reader lock, each write end's claims
 *        follow its stream byte for byte (none claimed twice or skipped),
 *        a record partly claimed is the next claimed (PIPE_BUF atomicity,
 *        across co-readers too), a record is retired only once every byte
 *        of it is claimed and rpos moves one record at a time, every byte
 *        a read copies is the claimed byte of its write end's stream, and
 *        no read waits with bytes copied, since rpos is past them and the
 *        session's pipe NIF answers a wait with would_block;
 *   PI6  of two records of different write ends, one whose wpos landed
 *        before the other's stamp was read is claimed first;
 *   PI7  no party sleeps with what it waits for ready while every other
 *        party is idle or asleep with no store left to make and no report
 *        or server event pending; a state from which no event can follow
 *        has every call finished, so a party asleep there lost a wakeup;
 *        and an idle read end holds no sleepers bit on a live lane, no
 *        waiters bit and not the reader lock;
 *
 * and, at the end of a scenario in which no read end ended early, that the
 * reads returned every byte published.  The service bound of PI6 is not
 * checked: at the model's lengths no write end publishes the two rings a
 * record may wait behind.
 *
 * A hostile scenario checks only what the honest parties must keep: no
 * loop, no error but their own (a broken lane, EAGAIN, EPIPE once no read
 * end remains), and no access outside memory.  The program's argument
 * names the scenario; it prints the states and the depth reached, or the
 * failed property and the trace.  Each scenario has two sets of write
 * lengths: the landing gate's, which fit make check under the sanitizers,
 * and the milestone gate's deeper ones, which tools/erx check-fuzz runs.
 * Either way every interleaving is explored to its end, not to a depth
 * bound.
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
#define SPAN		(2 * GRAIN)	/* every model record: header, payload */
#define SLOTS		(RING / GRAIN)
#define NW_MAX		2
#define NR_MAX		2
#define RECS_MAX	8		/* records a write end writes */
#define BUFFERED_MAX	6
#define WRITES_MAX	4
#define STEPS_MAX	256
#define DEPTH_MAX	4096
#define NO_REC		0xffu

/* The places a party stores to; the first five are a lane's. */
enum loc {
	L_WPOS, L_NEED, L_RPOS, L_WAKE, L_SLEEPERS, L_OWNER, L_WAITERS, L_CUR,
	L_AREA			/* one 16-byte slot of a lane's data area */
};

enum rmw { PLAIN = 0, OR, ANDNOT };

typedef struct store {
	uint8_t		 loc;
	uint8_t		 release;
	uint8_t		 rmw;
	uint8_t		 slot;		/* L_AREA */
	uint8_t		 lane;		/* the write end whose lane it is */
	uint8_t		 pad[3];
	uint32_t	 a;		/* L_CUR: cur_off; L_WPOS: stream end */
	uint32_t	 b;		/* L_CUR: cur */
	uint64_t	 value;
	uint8_t		 bytes[GRAIN];
} store_t;

/* One write end's lane: its ring header, its reader page, its area. */
typedef struct lane_mem {
	uint64_t	 wpos, need, rpos, wake, sleepers;
	uint8_t		 area[RING];
} lane_mem_t;

typedef struct mem {
	lane_mem_t	 lane[NW_MAX];
	uint64_t	 waiters, cur_pos;
	uint32_t	 owner, wends, cur, cur_off;
} mem_t;

enum pstate { ABSENT = 0, IDLE, CALL, CLOSED, DEAD, ENDED, HOSTILE };

/* The reports a party's event executor has still to apply. */
#define REP_WGONE(w)	(1u << (w))		/* write end w went */
#define REP_RGONE(r)	(1u << (4 + (r)))	/* read end r went */
#define REP_JOIN	(1u << 8)		/* the joining write end */
#define REP_LOST	(1u << 9)		/* the pipe is lost */

/* A holder: its pending action, its reports and its store buffer. */
typedef struct party {
	uint8_t		 state;
	uint8_t		 bell;		/* a ring latched until a wait */
	uint8_t		 nbuf;
	uint8_t		 decided;	/* act is the step's answer to in */
	uint16_t	 reports;
	uint8_t		 pad[2];
	uint32_t	 steps;		/* since the last wait or call's end */
	uint32_t	 pad2;
	uint64_t	 base;		/* the stream offset of the call's buffer */
	erx_pipe_act_t	 act;
	erx_pipe_in_t	 in;
	store_t		 buf[BUFFERED_MAX];
} party_t;

/*
 * A record a write end wrote, at lane position SPAN * its index: after[o]
 * holds the records of write end o published before its stamp was read,
 * which happened before it and must be read first (PI6).
 */
#define G_WRITTEN	1u
#define G_PUBLISHED	2u
#define G_LANDED	4u	/* its header is in the area */
typedef struct ghost {
	uint8_t		 flags;
	uint8_t		 len;
	uint8_t		 claimed;	/* payload bytes claimed in the lock page */
	uint8_t		 after[NW_MAX];
	uint16_t	 off;		/* the stream offset of its first byte */
} ghost_t;

typedef struct world {
	mem_t		 mem;
	party_t		 w[NW_MAX], r[NR_MAX];
	erx_pipe_wstate_t ws[NW_MAX];
	erx_pipe_rstate_t rs[NR_MAX];
	erx_pipe_rlane_t lane[NR_MAX][NW_MAX];
	ghost_t		 rec[NW_MAX][RECS_MAX];
	/* before[w][o]: write end o's records published when write end w
	 * last read the clock for a stamp; copied to the record as after. */
	uint8_t		 before[NW_MAX][NW_MAX];
	uint64_t	 written[NW_MAX];	/* bytes each write end's calls took */
	uint64_t	 published[NW_MAX];	/* bytes behind its committed wpos */
	uint64_t	 taken[NW_MAX];		/* bytes of it claimed */
	uint64_t	 received[NR_MAX];	/* bytes each read end's reads returned */
	uint64_t	 pend_off[NR_MAX];	/* the read end's last claim, to copy */
	uint32_t	 pend_n[NR_MAX];
	uint8_t		 pend_w[NR_MAX];
	uint8_t		 writes[NW_MAX];	/* writes started */
	uint8_t		 eof[NR_MAX];
	uint8_t		 quit[NR_MAX];		/* the read is a wait given up */
	uint8_t		 drained[NR_MAX][NW_MAX];
	uint8_t		 going;		/* read ends whose going the server has
					 * still to handle */
	uint8_t		 open_w, open_k;	/* a record partly claimed */
	uint8_t		 hostile;	/* the rewrite happened */
	uint8_t		 joined;	/* the joining write end is installed */
	uint8_t		 lost;		/* the pipe's loss happened */
	uint8_t		 cut;		/* a read end ended early */
	uint8_t		 calls;		/* reads read end 0 started */
	uint16_t	 now;		/* the clock's last reading */
	uint16_t	 pad2[3];
} world_t;

_Static_assert(sizeof(world_t) % sizeof(uint64_t) == 0,
    "the fingerprint reads the world in words");

typedef struct scenario {
	const char	*name;
	uint8_t		 nw, nr;
	/* Each write end's lengths, ended by 0: at the landing gate, deep. */
	uint32_t	 writes[NW_MAX][WRITES_MAX];
	uint32_t	 deep[NW_MAX][WRITES_MAX];
	uint32_t	 read_len;
	bool		 nonblock;
	bool		 writer_dies;	/* write end 0 */
	bool		 reader_closes;	/* read end 0 */
	bool		 reader_dies;	/* read end 0 */
	bool		 joins;		/* the last write end joins mid-stream */
	bool		 lost;
	bool		 nif;		/* reads made afresh during a wait */
	bool		 clock;		/* the clock advances at every reading */
	/* The reads read end 0 makes before it closes, at the landing gate
	 * and deep; 0 for no bound. */
	uint8_t		 calls[2];
	/* 0, or whose rewrites: 'w' a writer's, 'r' a reader's of its lane's
	 * reader page, 'c' a co-reader's, the last read end, which never
	 * reads */
	int		 hostile;
} scenario_t;

static const scenario_t scenarios[] = {
	{ .name = "flow", .nw = 1, .nr = 1, .writes = { { 40, 24 } },
	  .deep = { { 40, 33 } }, .read_len = 24, .nif = true },
	{ .name = "partial", .nw = 1, .nr = 1, .writes = { { 20, 7 } },
	  .deep = { { 40, 7 } }, .read_len = 5, .nif = true },
	{ .name = "nonblock", .nw = 1, .nr = 1, .writes = { { 40, 9 } },
	  .deep = { { 40, 40 } }, .read_len = 24, .nonblock = true,
	  .nif = true },
	{ .name = "writer-dies", .nw = 1, .nr = 1, .writes = { { 24, 9 } },
	  .deep = { { 40, 33 } }, .read_len = 24, .writer_dies = true,
	  .nif = true },
	{ .name = "reader-closes", .nw = 1, .nr = 1, .writes = { { 40, 9 } },
	  .deep = { { 40, 40 } }, .read_len = 24, .reader_closes = true,
	  .nif = true },
	{ .name = "reader-dies", .nw = 1, .nr = 1, .writes = { { 24, 9 } },
	  .deep = { { 40, 40 } }, .read_len = 24, .reader_dies = true,
	  .nif = true },
	{ .name = "lost", .nw = 1, .nr = 1, .writes = { { 24, 9 } },
	  .deep = { { 40, 33 } }, .read_len = 24, .lost = true, .nif = true },
	/* A write end that joins and writes nothing: the wends wait alone. */
	{ .name = "join", .nw = 2, .nr = 1, .writes = { { 24, 9 }, { 0 } },
	  .deep = { { 40, 33 }, { 0 } }, .read_len = 24, .joins = true,
	  .nif = true },
	{ .name = "merge", .nw = 2, .nr = 1, .writes = { { 3 }, { 2 } },
	  .deep = { { 9, 3 }, { 5 } }, .read_len = 24, .clock = true },
	{ .name = "merge-join", .nw = 2, .nr = 1, .writes = { { 2 }, { 1 } },
	  .deep = { { 3, 5 }, { 4 } }, .read_len = 24, .joins = true,
	  .clock = true },
	{ .name = "coread", .nw = 1, .nr = 2, .writes = { { 7 } },
	  .deep = { { 9, 3 } }, .read_len = 5, .calls = { 1, 3 } },
	{ .name = "coread-dies", .nw = 1, .nr = 2, .writes = { { 6 } },
	  .deep = { { 6 } }, .read_len = 5, .reader_dies = true,
	  .calls = { 1, 2 } },
	/* A co-reader dies with nothing written: the lock and reports alone. */
	{ .name = "coread-dies-empty", .nw = 1, .nr = 2, .writes = { { 0 } },
	  .deep = { { 0 } }, .read_len = 1, .reader_dies = true,
	  .calls = { 1, 1 } },
	/* The loss with nothing written: with bytes to read, the loss report
	 * pending at each party keeps every step of the others in play, and
	 * the shape is too large to explore (TODO.md). */
	{ .name = "coread-lost", .nw = 1, .nr = 2, .writes = { { 0 } },
	  .deep = { { 0 } }, .read_len = 5, .lost = true,
	  .calls = { 1, 2 } },
	{ .name = "hostile-writer", .nw = 1, .nr = 1, .writes = { { 16, 9 } },
	  .deep = { { 40, 9 } }, .read_len = 24, .hostile = 'w', .nif = true },
	{ .name = "hostile-reader", .nw = 1, .nr = 1, .writes = { { 16, 9 } },
	  .deep = { { 40, 24 } }, .read_len = 24, .hostile = 'r', .nif = true },
	{ .name = "hostile-coreader", .nw = 1, .nr = 2, .writes = { { 16, 9 } },
	  .deep = { { 40, 24 } }, .read_len = 5, .hostile = 'c' },
};

static const scenario_t *sc;
static uint32_t (*writes)[WRITES_MAX];	/* the scenario's lengths at this depth */
static uint32_t lengths[NW_MAX][WRITES_MAX];
static uint8_t calls_max;	/* the scenario's bound at this depth */
static world_t worlds[DEPTH_MAX];
static char trace[DEPTH_MAX][160];
static uint64_t *seen;
static uint64_t seen_size, seen_count, max_depth;

/* Write end w's stream byte at offset k; its period is longer than a ring. */
static uint8_t
pattern(int w, uint64_t k)
{
	return ((uint8_t)(1 + k % 127 + 128 * (uint64_t)w));
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
	uint64_t h = 0x9e3779b97f4a7c15u, v;
	size_t i;

	for (i = 0; i < sizeof(*wd); i += sizeof(v)) {
		memcpy(&v, p + i, sizeof(v));
		h = (h ^ v) * 0xff51afd7ed558ccdu;
		h ^= h >> 32;
	}
	h *= 0xc4ceb9fe1a85ec53u;
	h ^= h >> 29;
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
	return (a->loc == b->loc && (a->loc > L_SLEEPERS || a->lane == b->lane) &&
	    (a->loc != L_AREA || (a->lane == b->lane && a->slot == b->slot)));
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
mem_word(mem_t *m, uint8_t loc, uint8_t lane)
{
	switch (loc) {
	case L_WPOS:
		return (&m->lane[lane].wpos);
	case L_NEED:
		return (&m->lane[lane].need);
	case L_RPOS:
		return (&m->lane[lane].rpos);
	case L_WAKE:
		return (&m->lane[lane].wake);
	case L_SLEEPERS:
		return (&m->lane[lane].sleepers);
	case L_WAITERS:
		return (&m->waiters);
	default:
		abort();
	}
}

/* Write end w's wpos landed at stream end: its records up to it are published. */
static void
published(world_t *wd, int w, uint64_t wpos, uint32_t end)
{
	uint64_t k;

	wd->published[w] = end;
	for (k = 0; k < RECS_MAX && (k + 1) * SPAN <= wpos; k++)
		wd->rec[w][k].flags |= G_PUBLISHED;
}

static void
commit(world_t *wd, party_t *p, int j)
{
	const store_t *s = &p->buf[j];
	uint64_t *word;

	switch (s->loc) {
	case L_AREA:
		memcpy(&wd->mem.lane[s->lane].area[s->slot * GRAIN], s->bytes,
		    GRAIN);
		if (s->slot % 2 == 0 && s->value < RECS_MAX)
			wd->rec[s->lane][s->value].flags |= G_LANDED;
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
		word = mem_word(&wd->mem, s->loc, s->lane);
		*word = rmw_apply(*word, s);
		if (s->loc == L_WPOS && !wd->hostile)
			published(wd, s->lane, s->value, s->a);
		break;
	}
	memmove(&p->buf[j], &p->buf[j + 1], (size_t)(p->nbuf - j - 1) *
	    sizeof(p->buf[0]));
	p->nbuf--;
	memset(&p->buf[p->nbuf], 0, sizeof(p->buf[0]));
}

/* A load of a word: memory, then the party's own buffered stores to it. */
static uint64_t
load(world_t *wd, const party_t *p, uint8_t loc, uint8_t lane)
{
	uint64_t v;
	int i;

	v = *mem_word(&wd->mem, loc, lane);
	for (i = 0; i < p->nbuf; i++)
		if (p->buf[i].loc == loc && (loc > L_SLEEPERS ||
		    p->buf[i].lane == lane))
			v = rmw_apply(v, &p->buf[i]);
	return (v);
}

static store_t *
push(party_t *p, uint8_t loc, uint8_t lane, bool release, uint8_t rmw,
    uint64_t value)
{
	store_t *s = &p->buf[p->nbuf++];

	memset(s, 0, sizeof(*s));
	s->loc = loc;
	s->lane = lane;
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
gone(const party_t *p)
{
	return (p->state == CLOSED || p->state == DEAD);
}

static bool
alive(const party_t *p)
{
	return (p->state == IDLE || p->state == CALL);
}

/* Whether every write end installed has gone; one not yet joined never will. */
static bool
writers_gone(const world_t *wd)
{
	int w;

	for (w = 0; w < sc->nw; w++)
		if (wd->w[w].state != ABSENT && !gone(&wd->w[w]))
			return (false);
	return (true);
}

static int
party_index(const world_t *wd, const party_t *p, bool *writer)
{
	*writer = p >= wd->w && p < wd->w + NW_MAX;
	return ((int)(*writer ? p - wd->w : p - wd->r));
}

static void
next_action(world_t *wd, party_t *p)
{
	bool writer;
	int i = party_index(wd, p, &writer);

	if (writer) {
		p->act = erx_pipe_wstep(&wd->ws[i], &p->in);
	} else {
		wd->rs[i].lanes = wd->lane[i];
		p->act = erx_pipe_rstep(&wd->rs[i], &p->in);
		wd->rs[i].lanes = NULL;
	}
	memset(&p->in, 0, sizeof(p->in));	/* spent: no state keeps it */
	p->decided = 1;
}

static void
writer_done(world_t *wd, int w, int depth, int64_t result)
{
	const erx_pipe_wstate_t *ws = &wd->ws[w];

	if (result == -EPIPE && ws->readers != 0 && !ws->lost)
		fail(depth, "PI3", "EPIPE while a read end remains");
	if (result == -EAGAIN && !sc->nonblock)
		fail(depth, "PI3", "EAGAIN on a blocking write end");
	if (result < 0 && result != -EPIPE && result != -EAGAIN)
		fail(depth, "PI3", "a write failed with another error");
	if (result >= 0 && (uint64_t)result != ws->len && !sc->nonblock &&
	    ws->readers != 0 && !ws->lost)
		fail(depth, "PI3", "a blocking write returned short");
	if (result > 0)
		wd->written[w] = wd->w[w].base + (uint64_t)result;
	wd->w[w].state = IDLE;
}

/* Whether every byte published has been claimed. */
static bool
all_taken(const world_t *wd)
{
	int w;

	for (w = 0; w < sc->nw; w++)
		if (wd->taken[w] != wd->published[w])
			return (false);
	return (true);
}

static void
reader_done(world_t *wd, int r, int depth, int64_t result)
{
	party_t *p = &wd->r[r];

	if (wd->quit[r]) {
		if (result != 0)
			fail(depth, "PI2", "a read of 0 bytes returned something");
		wd->quit[r] = 0;
		p->state = IDLE;
		return;
	}
	if (result > 0 && wd->eof[r])
		fail(depth, "PI2", "bytes after the end of the stream");
	if (result == 0) {
		/* A broken lane counts as gone and drained (design "The ring"). */
		if (!wd->hostile && !writers_gone(wd))
			fail(depth, "PI2", "the end of the stream while a writer is open");
		if (!wd->hostile && !all_taken(wd))
			fail(depth, "PI2", "the end of the stream before every published byte was read");
		wd->eof[r]++;
	}
	if (result == -EAGAIN && !sc->nonblock)
		fail(depth, "PI2", "EAGAIN on a blocking read end");
	if (result == -EIO && !wd->rs[r].lost)
		fail(depth, "PI2", "EIO before the pipe's loss was applied");
	if (result < 0 && result != -EAGAIN && result != -EIO)
		fail(depth, "PI2", "a read failed with another error");
	if (result > 0)
		wd->received[r] += (uint64_t)result;
	p->state = wd->eof[r] >= 2 || result == -EIO ? ENDED : IDLE;
	if (p->state == ENDED)
		p->reports = 0;
}

/* The write end whose lane is read end r's lane at, or a failure. */
static int
lane_writer(const world_t *wd, int r, int depth, uint32_t at)
{
	if (at >= wd->rs[r].nlanes || at >= NW_MAX)
		fail(depth, "PI4", "an action names a lane the read end lacks");
	return ((int)wd->lane[r][at].wend - 1);
}

/* A record's model entry at lane position pos, or NULL past the model's. */
static ghost_t *
ghost(world_t *wd, int w, uint64_t pos)
{
	if (pos % SPAN != 0 || pos / SPAN >= RECS_MAX)
		return (NULL);
	return (&wd->rec[w][pos / SPAN]);
}

/*
 * The claim of a store of cur: payload bytes up to n of the record at pos
 * of write end w.  It must be made under the lock, continue that end's
 * stream and the record partly claimed, and, when it starts a record,
 * follow every record of another end published before this one's stamp.
 */
static void
claim(world_t *wd, int r, int w, int depth, const erx_pipe_act_t *a)
{
	uint32_t n = wd->rs[r].claim, from = (uint32_t)a->n - n;
	ghost_t *g = ghost(wd, w, a->pos), *x;
	int k, o;

	if (wd->hostile)
		return;
	if (g == NULL || (g->flags & G_PUBLISHED) == 0)
		fail(depth, "PI5", "a claim of a record not published");
	if (wd->mem.owner != 1u + wd->rs[r].rix)
		fail(depth, "PI5", "a claim outside the reader lock");
	if (n == 0 || a->n > g->len)
		fail(depth, "PI4", "a claim outside its record");
	if (wd->open_w != NO_REC && (wd->open_w != w ||
	    wd->open_k != a->pos / SPAN))
		fail(depth, "PI5", "a record partly read was split by another");
	if (from != g->claimed || wd->taken[w] != g->off + from)
		fail(depth, "PI5", "bytes claimed twice or skipped");
	for (o = 0; from == 0 && o < sc->nw; o++)
		for (k = 0; k < RECS_MAX; k++) {
			x = &wd->rec[o][k];
			if ((g->after[o] & 1u << k) != 0 && x->claimed == 0)
				fail(depth, "PI6", "a record read before one published before it was written");
		}
	g->claimed = (uint8_t)a->n;
	wd->taken[w] += n;
	wd->open_w = a->n < g->len ? (uint8_t)w : NO_REC;
	wd->open_k = a->n < g->len ? (uint8_t)(a->pos / SPAN) : NO_REC;
	wd->pend_w[r] = (uint8_t)w;
	wd->pend_off[r] = g->off + from;
	wd->pend_n[r] = n;
}

/* A store of rpos by read end r: one record on, and that one wholly claimed. */
static void
retire(world_t *wd, int r, int w, int depth, const erx_pipe_act_t *a)
{
	const ghost_t *g = ghost(wd, w, a->value - SPAN);

	if (wd->hostile)
		return;
	if (a->value != load(wd, &wd->r[r], L_RPOS, (uint8_t)w) + SPAN)
		fail(depth, "PI5", "rpos moved by other than one record");
	if (g == NULL || g->claimed != g->len || g->len == 0)
		fail(depth, "PI5", "a record retired with bytes unclaimed");
	if (wd->mem.owner != 1u + wd->rs[r].rix)
		fail(depth, "PI5", "a record retired outside the reader lock");
}

static void
copy_data(world_t *wd, int r, int w, int depth, const erx_pipe_act_t *a)
{
	uint64_t i;

	if (a->off + a->n > sc->read_len || a->n == 0 || a->n > CHUNK)
		fail(depth, "PI4", "a copy outside the lane or the buffer");
	if (wd->hostile)
		return;
	if (a->n != wd->pend_n[r] || w != wd->pend_w[r])
		fail(depth, "PI5", "a copy of other than the bytes claimed");
	for (i = 0; i < a->n; i++)
		if (wd->mem.lane[w].area[(a->pos + i) % RING] !=
		    pattern(w, wd->pend_off[r] + i))
			fail(depth, "PI5", "a byte read out of its stream's order");
	wd->pend_n[r] = 0;
}

static void
write_rec(world_t *wd, int w, int depth, const erx_pipe_act_t *a)
{
	party_t *p = &wd->w[w];
	ghost_t *g = ghost(wd, w, a->pos);
	store_t *s;
	uint64_t i;

	if (a->n == 0 || a->n > CHUNK || a->off + a->n > wd->ws[w].len ||
	    a->pos % GRAIN != 0)
		fail(depth, "PI4", "a record outside the chunk or the buffer");
	if (g == NULL && !wd->hostile)
		fail(depth, "model", "a write end wrote more records than RECS_MAX");
	if (g != NULL)
		*g = (ghost_t){ .flags = G_WRITTEN, .len = (uint8_t)a->n,
		    .off = (uint16_t)(p->base + a->off) };
	if (g != NULL)
		memcpy(g->after, wd->before[w], sizeof(g->after));
	s = push(p, L_AREA, (uint8_t)w, false, PLAIN, a->pos / SPAN);
	s->slot = (uint8_t)((a->pos % RING) / GRAIN);
	put_le(s->bytes, a->n, 4);
	put_le(s->bytes + 4, ERX_REC_DATA, 4);
	put_le(s->bytes + 8, a->value, 8);
	s = push(p, L_AREA, (uint8_t)w, false, PLAIN, 0);
	s->slot = (uint8_t)(((a->pos + GRAIN) % RING) / GRAIN);
	for (i = 0; i < a->n; i++)
		s->bytes[i] = pattern(w, p->base + a->off + i);
}

/* Rings every read end whose bit is in bits. */
static void
ring_readers(world_t *wd, uint64_t bits)
{
	int r;

	for (r = 0; r < sc->nr; r++)
		if ((bits & UINT64_C(1) << wd->rs[r].rix) != 0)
			wd->r[r].bell = 1;
}

/* Write end w reads its stamp: the records published so far precede it. */
static void
stamped(world_t *wd, int w)
{
	int o, k;

	for (o = 0; o < NW_MAX; o++) {
		wd->before[w][o] = 0;
		for (k = 0; o != w && k < RECS_MAX; k++)
			if ((wd->rec[o][k].flags & G_PUBLISHED) != 0)
				wd->before[w][o] |= (uint8_t)(1u << k);
	}
}

/* Performs a writer's pending action. */
static void
wperform(world_t *wd, int w, int depth, const erx_pipe_act_t *a)
{
	party_t *p = &wd->w[w];
	store_t *s;

	switch (a->op) {
	case ERX_PIPE_OP_DONE:
		p->steps = 0;
		writer_done(wd, w, depth, a->result);
		return;
	case ERX_PIPE_OP_CLOCK:
		p->in.value = sc->clock ? ++wd->now : 0;
		stamped(wd, w);
		break;
	case ERX_PIPE_OP_LOAD_RPOS:
		p->in.value = load(wd, p, L_RPOS, (uint8_t)w);
		break;
	case ERX_PIPE_OP_COPY_WAKE:
		p->in.value = load(wd, p, L_WAKE, (uint8_t)w);
		break;
	case ERX_PIPE_OP_COPY_SLEEPERS:
		p->in.value = load(wd, p, L_SLEEPERS, (uint8_t)w);
		break;
	case ERX_PIPE_OP_WRITE_REC:
		write_rec(wd, w, depth, a);
		break;
	case ERX_PIPE_OP_STORE_WPOS:
		s = push(p, L_WPOS, (uint8_t)w, true, PLAIN, a->value);
		s->a = (uint32_t)(p->base + wd->ws[w].done + wd->ws[w].rec);
		break;
	case ERX_PIPE_OP_STORE_NEED:
		push(p, L_NEED, (uint8_t)w, true, PLAIN, a->value);
		break;
	case ERX_PIPE_OP_FENCE:
		break;
	case ERX_PIPE_OP_RING_READERS:
		ring_readers(wd, a->value);
		break;
	case ERX_PIPE_OP_WAIT:
		p->bell = 0;
		p->steps = 0;
		break;
	default:
		fail(depth, "PI4", "a writer asked for a reader's action");
	}
}

/* Performs a reader's pending action. */
static void
rperform(world_t *wd, int r, int depth, const erx_pipe_act_t *a)
{
	party_t *p = &wd->r[r];
	uint64_t bit = UINT64_C(1) << wd->rs[r].rix;
	uint8_t w = 0;
	store_t *s;
	int i;

	if (a->lane != ERX_PIPE_LANE_NONE)
		w = (uint8_t)lane_writer(wd, r, depth, a->lane);
	switch (a->op) {
	case ERX_PIPE_OP_DONE:
		p->steps = 0;
		reader_done(wd, r, depth, a->result);
		return;
	case ERX_PIPE_OP_CLOCK:
		p->in.value = sc->clock ? ++wd->now : 0;
		break;
	case ERX_PIPE_OP_LOAD_RPOS:
		p->in.value = load(wd, p, L_RPOS, w);
		break;
	case ERX_PIPE_OP_LOAD_WPOS:
		p->in.value = wd->mem.lane[w].wpos;
		break;
	case ERX_PIPE_OP_COPY_NEED:
		p->in.value = wd->mem.lane[w].need;
		break;
	case ERX_PIPE_OP_COPY_WAITERS:
		p->in.value = load(wd, p, L_WAITERS, 0);
		break;
	case ERX_PIPE_OP_COPY_REC:
		if (a->pos % GRAIN != 0)
			fail(depth, "PI4", "a record header copied off the grain");
		p->in.len = (uint32_t)get_le(wd->mem.lane[w].area, a->pos, 4);
		p->in.kind = (uint32_t)get_le(wd->mem.lane[w].area, a->pos + 4, 4);
		p->in.stamp = get_le(wd->mem.lane[w].area, a->pos + 8, 8);
		break;
	case ERX_PIPE_OP_COPY_CUR:
		p->in.cur = wd->mem.cur;
		p->in.cur_off = wd->mem.cur_off;
		p->in.cur_pos = wd->mem.cur_pos;
		for (i = 0; i < p->nbuf; i++)
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
		copy_data(wd, r, w, depth, a);
		break;
	case ERX_PIPE_OP_STORE_RPOS:
		retire(wd, r, w, depth, a);
		push(p, L_RPOS, w, true, PLAIN, a->value);
		break;
	case ERX_PIPE_OP_STORE_WAKE:
		push(p, L_WAKE, w, true, PLAIN, a->value);
		break;
	case ERX_PIPE_OP_STORE_CUR:
		if (a->lane != ERX_PIPE_LANE_NONE)
			claim(wd, r, w, depth, a);
		s = push(p, L_CUR, 0, false, PLAIN, a->pos);
		s->a = (uint32_t)a->n;
		s->b = a->lane == ERX_PIPE_LANE_NONE ? ERX_PIPE_NONE :
		    wd->lane[r][a->lane].wend;
		break;
	case ERX_PIPE_OP_SET_SLEEPER:
		push(p, L_SLEEPERS, w, false, OR, bit);
		break;
	case ERX_PIPE_OP_CLEAR_SLEEPER:
		push(p, L_SLEEPERS, w, false, ANDNOT, bit);
		break;
	case ERX_PIPE_OP_SET_WAITER:
		push(p, L_WAITERS, 0, false, OR, bit);
		break;
	case ERX_PIPE_OP_CLEAR_WAITER:
		push(p, L_WAITERS, 0, false, ANDNOT, bit);
		break;
	case ERX_PIPE_OP_TAKE_LOCK:
		p->in.ok = wd->mem.owner == 0;
		if (p->in.ok)
			wd->mem.owner = 1 + wd->rs[r].rix;
		break;
	case ERX_PIPE_OP_RELEASE_LOCK:
		push(p, L_OWNER, 0, true, PLAIN, 0);
		break;
	case ERX_PIPE_OP_FENCE:
		break;
	case ERX_PIPE_OP_RING_READERS:
		ring_readers(wd, a->value);
		break;
	case ERX_PIPE_OP_RING_WRITER:
		wd->w[w].bell = 1;
		break;
	case ERX_PIPE_OP_WAIT:
		p->bell = 0;
		p->steps = 0;
		break;
	case ERX_PIPE_OP_DRAINED:
		if (!gone(&wd->w[w]) || wd->drained[r][w]++ != 0 ||
		    (!wd->hostile && wd->taken[w] != wd->published[w]))
			fail(depth, "PI2", "a lane reported drained before it was");
		break;
	case ERX_PIPE_OP_BROKEN:
		if (!wd->hostile)
			fail(depth, "PI5", "an honest writer's lane found broken");
		break;
	default:
		fail(depth, "PI4", "a reader asked for a writer's action");
	}
}

/* Performs the party's pending action. */
static void
perform(world_t *wd, party_t *p, int depth)
{
	const erx_pipe_act_t a = p->act;
	bool writer;
	int i = party_index(wd, p, &writer);

	memset(&p->in, 0, sizeof(p->in));
	p->steps++;
	if (writer)
		wperform(wd, i, depth, &a);
	else
		rperform(wd, i, depth, &a);
	if (a.op == ERX_PIPE_OP_DONE)
		return;
	if (p->steps > STEPS_MAX)
		fail(depth, "PI4", "a step loops without waiting or ending");
	p->decided = 0;
}

/* One rewrite of a shared field by a hostile peer of the honest parties. */
static bool
rewrite(world_t *wd, int k)
{
	mem_t *m = &wd->mem;
	lane_mem_t *l = &m->lane[0];
	uint8_t *rec = &l->area[l->rpos % RING / GRAIN * GRAIN];

	if (sc->hostile == 'w') {
		switch (k) {
		case 0: l->wpos += GRAIN; return (true);
		case 1: l->wpos = l->rpos + RING + GRAIN; return (true);
		case 2: l->wpos |= 8; return (true);
		case 3: l->wpos = l->rpos - GRAIN; return (true);
		case 4: put_le(rec + 4, ERX_REC_FRAME, 4); return (true);
		case 5: put_le(rec, ERX_PIPE_BUF + 1, 4); return (true);
		case 6: put_le(rec, 8, 4); put_le(rec + 4, ERX_REC_CONTROL, 4);
			return (true);
		}
	} else if (sc->hostile == 'r') {
		switch (k) {
		case 0: l->rpos = l->wpos + GRAIN; return (true);
		case 1: l->rpos |= 8; return (true);
		case 2: l->rpos = l->wpos - RING - GRAIN; return (true);
		case 3: l->wake = 0; return (true);
		case 4: l->wake = UINT64_MAX; return (true);
		case 5: l->sleepers = UINT64_MAX; return (true);
		}
	} else {
		/* A co-reader's: the lock page, as it may write it. */
		switch (k) {
		case 0: m->owner = 1 + wd->rs[sc->nr - 1].rix; return (true);
		case 1: m->owner = 200; return (true);
		case 2: m->cur = 1; m->cur_off = 1; m->cur_pos = l->rpos;
			return (true);
		case 3: m->cur = 1; m->cur_off = 200; m->cur_pos = l->rpos;
			return (true);
		case 4: m->cur = 1; m->cur_pos = l->rpos - SPAN; return (true);
		case 5: m->cur = 7; return (true);
		case 6: m->wends = 9; return (true);
		case 7: m->waiters = UINT64_MAX; return (true);
		case 8: l->rpos = l->wpos + GRAIN; return (true);
		}
	}
	return (false);
}

static void explore(int depth);

static world_t *
successor(int depth, const char *what, int who)
{
	worlds[depth + 1] = worlds[depth];
	snprintf(trace[depth + 1], sizeof(trace[0]), "%s%c", what,
	    who < 0 ? ' ' : '0' + who);
	return (&worlds[depth + 1]);
}

/*
 * Whether the party's pending action touches only its own state: a store
 * into its own buffer (a flush is what others see), a fence with the
 * buffer drained, or a clock that reads 0.  Performed at once or later,
 * such an action leaves every other party's view the same, so the model
 * performs it at once, except for a party that may die, whose death
 * between two stores leaves one of them unmade.
 */
static bool
local_act(const world_t *wd, const party_t *p)
{
	bool writer;
	int i = party_index(wd, p, &writer);

	if (i == 0 && ((writer && sc->writer_dies) ||
	    (!writer && sc->reader_dies)))
		return (false);
	switch (p->act.op) {
	case ERX_PIPE_OP_CLOCK:
		return (!sc->clock);
	case ERX_PIPE_OP_FENCE:
		return (p->nbuf == 0);
	/*
	 * Under the reader lock, rpos and the current record change only by
	 * the holder's own stores: the last holder's landed before its
	 * release did, and a gone holder's before the server freed the lock.
	 * A hostile co-reader may rewrite them at any time; wends changes
	 * only at a join.
	 */
	case ERX_PIPE_OP_LOAD_RPOS:
	case ERX_PIPE_OP_COPY_CUR:
		return (!writer && sc->hostile == 0 &&
		    wd->mem.owner == 1 + wd->rs[i].rix);
	case ERX_PIPE_OP_COPY_WENDS:
		return (!sc->joins && sc->hostile == 0);
	default:
		return (stores_of(p->act.op) != 0 &&
		    p->nbuf + stores_of(p->act.op) <= BUFFERED_MAX);
	}
}

/* Performs a party's action at once, adding it to the event's trace line. */
static void
perform_shown(world_t *wd, party_t *p, int i, int depth)
{
	size_t n = strlen(trace[depth]);

	snprintf(trace[depth] + n, sizeof(trace[0]) - n, "; %c%d %s",
	    i < NW_MAX ? 'W' : 'R', i < NW_MAX ? i : i - NW_MAX,
	    op_names[p->act.op]);
	perform(wd, p, depth);
}

/*
 * A step reads only its end's private state, which only the end's own
 * events and its executor's reports change, so the model asks it for its
 * next action at once unless a report is pending, when the step is an
 * event of its own and the report can land before or after it; and it
 * performs local actions at once in the same way.  A report posted after
 * the action and applied before the step is the same run as one posted
 * before the action, unless the server event that posts it changed what
 * the action read: that is the join, which stores wends, so while a join
 * can still come the step after COPY_WENDS is an event of its own too.
 * Every state is explored in this form.
 */
static void
advance(world_t *wd, int depth)
{
	party_t *p;
	int i;

	for (i = 0; i < NW_MAX + NR_MAX; i++) {
		p = i < NW_MAX ? &wd->w[i] : &wd->r[i - NW_MAX];
		while (p->state == CALL && p->reports == 0) {
			if (!p->decided && p->act.op == ERX_PIPE_OP_COPY_WENDS &&
			    sc->joins && !wd->joined)
				break;
			if (!p->decided)
				next_action(wd, p);
			else if (local_act(wd, p))
				perform_shown(wd, p, i, depth);
			else
				break;
		}
	}
}

/*
 * The clock's readings matter only by their order: the steps compare and
 * take the larger of stamps and marks, and the model compares a record's
 * landing with another's stamp.  So the model renumbers every reading the
 * state holds by its rank, keeping 0, and two states that differ only in
 * how far the clock has run are explored once.  The places a reading
 * lives are all listed here; one left out would be compared on another
 * scale.
 */
#define READINGS_MAX	512

static uint16_t readings[READINGS_MAX];
static int nreadings;

static void
reading(uint64_t v)
{
	if (nreadings == READINGS_MAX)
		abort();
	readings[nreadings++] = (uint16_t)v;
}

static int
by_value(const void *a, const void *b)
{
	return ((int)*(const uint16_t *)a - (int)*(const uint16_t *)b);
}

static uint64_t
rank(uint64_t v)
{
	int lo = 0, hi = nreadings - 1, mid;

	while (lo < hi) {
		mid = (lo + hi) / 2;
		if (readings[mid] < v)
			lo = mid + 1;
		else
			hi = mid;
	}
	return ((uint64_t)lo);
}

/* Every reading of the state, through f: collected, then renumbered. */
static void
readings_of(world_t *wd, uint64_t (*f)(uint64_t))
{
	erx_pipe_rlane_t *l;
	party_t *p;
	uint8_t *h;
	int i, j, k;

	wd->now = (uint16_t)f(wd->now);
	for (i = 0; i < NW_MAX; i++) {
		wd->ws[i].stamp = f(wd->ws[i].stamp);
		for (k = 0; k < (int)SLOTS; k += 2) {
			h = &wd->mem.lane[i].area[k * GRAIN];
			put_le(h + 8, f(get_le(h, 8, 8)), 8);
		}
	}
	for (i = 0; i < NR_MAX; i++) {
		wd->rs[i].clock = f(wd->rs[i].clock);
		for (j = 0; j < NW_MAX; j++) {
			l = &wd->lane[i][j];
			l->look = f(l->look);
			l->key = f(l->key);
			/* A batch past nbatches is spent: nothing reads it. */
			for (k = 0; k < ERX_PIPE_BATCHES; k++)
				l->batch[k] = k < (int)l->nbatches ?
				    (erx_pipe_batch_t){ .end = l->batch[k].end,
				    .mark = f(l->batch[k].mark) } :
				    (erx_pipe_batch_t){ 0 };
		}
	}
	for (i = 0; i < NW_MAX + NR_MAX; i++) {
		p = i < NW_MAX ? &wd->w[i] : &wd->r[i - NW_MAX];
		if (p->act.op == ERX_PIPE_OP_WRITE_REC)
			p->act.value = f(p->act.value);
		if (!p->decided && p->act.op == ERX_PIPE_OP_CLOCK)
			p->in.value = f(p->in.value);
		if (!p->decided && p->act.op == ERX_PIPE_OP_COPY_REC)
			p->in.stamp = f(p->in.stamp);
		for (j = 0; j < p->nbuf; j++)
			if (p->buf[j].loc == L_AREA && p->buf[j].slot % 2 == 0)
				put_le(p->buf[j].bytes + 8,
				    f(get_le(p->buf[j].bytes, 8, 8)), 8);
	}
}

static uint64_t
collect(uint64_t v)
{
	reading(v);
	return (v);
}

/*
 * Readings nothing will compare again are dropped first, so they do not
 * tell states apart: a write end's stamp once its record is written (the
 * pending WRITE_REC carries it), the reader's clock once its look has
 * copied wpos, a lane's key outside a pick, and the stamp in the header
 * of a record read past, which no reader copies again.
 */
static void
forget(world_t *wd)
{
	const party_t *p;
	int i, j, k, top;

	for (i = 0; i < NW_MAX; i++) {
		wd->ws[i].stamp = 0;
		for (j = 0; j < (int)SLOTS; j += 2) {
			/* The newest record whose header landed in slot j. */
			for (k = top = -1; ++k < RECS_MAX;)
				if (k * SPAN % RING == (unsigned)j * GRAIN &&
				    (wd->rec[i][k].flags & G_LANDED) != 0)
					top = k;
			if (top >= 0 && (uint64_t)(top + 1) * SPAN <=
			    wd->mem.lane[i].rpos)
				put_le(&wd->mem.lane[i].area[j * GRAIN + 8], 0, 8);
		}
	}
	for (i = 0; i < NR_MAX; i++) {
		p = &wd->r[i];
		if (p->act.op != ERX_PIPE_OP_LOAD_WPOS)
			wd->rs[i].clock = 0;
		for (j = 0; j < NW_MAX; j++)
			if (!wd->lane[i][j].has_rec)
				wd->lane[i][j].key = 0;
	}
}

static void
renumber(world_t *wd)
{
	int i, n;

	forget(wd);
	nreadings = 0;
	reading(0);
	readings_of(wd, collect);
	qsort(readings, (size_t)nreadings, sizeof(readings[0]), by_value);
	for (i = n = 1; i < nreadings; i++)
		if (readings[i] != readings[n - 1])
			readings[n++] = readings[i];
	nreadings = n;
	readings_of(wd, rank);
}

static void
visit(int depth)
{
	advance(&worlds[depth], depth);
	if (sc->clock)
		renumber(&worlds[depth]);
	if (first_visit(&worlds[depth]))
		explore(depth);
}

static bool
asleep(const party_t *p)
{
	return (p->state == CALL && p->decided && p->bell == 0 &&
	    p->act.op == ERX_PIPE_OP_WAIT);
}

/* A state from which no event follows must have every call finished. */
static void
check_end(int depth)
{
	const world_t *wd = &worlds[depth];
	uint64_t got = 0, sent = 0;
	int i;

	if (sc->hostile != 0)
		return;
	if (!writers_gone(wd))
		fail(depth, "PI7", "a writer sleeps for good (a lost wakeup)");
	for (i = 0; i < sc->nr; i++) {
		if (wd->r[i].state != ENDED && !gone(&wd->r[i]))
			fail(depth, "PI7", "a reader sleeps for good (a lost wakeup)");
		got += wd->received[i];
	}
	for (i = 0; i < sc->nw; i++)
		sent += wd->published[i];
	if (!wd->cut && !wd->lost && got != sent)
		fail(depth, "PI5", "the reads did not return every byte published");
}

/*
 * Whether nothing but the party itself can move: every other party is
 * idle, gone or asleep with no store left to make, and no report or
 * server event is pending.  A peer's later close or a report would wake a
 * sleeper too, so a sleeper with what it waits for ready in such a state
 * has lost its wakeup, whatever happens next.
 */
static bool
quiet(const world_t *wd, const party_t *self)
{
	const party_t *p;
	int i;

	if (wd->going != 0)
		return (false);
	for (i = 0; i < NW_MAX + NR_MAX; i++) {
		p = i < NW_MAX ? &wd->w[i] : &wd->r[i - NW_MAX];
		if (p->nbuf != 0 || p->reports != 0)
			return (false);
		if (p != self && p->state == CALL && !asleep(p))
			return (false);
	}
	return (true);
}

static void
check_asleep(int depth)
{
	const world_t *wd = &worlds[depth];
	const erx_pipe_rlane_t *l;
	const party_t *p;
	bool data;
	int i, j, w;

	if (sc->hostile != 0)
		return;
	for (i = 0; i < sc->nr; i++) {
		p = &wd->r[i];
		if (!asleep(p) || !quiet(wd, p) || wd->mem.owner != 0)
			continue;
		data = false;
		for (j = 0; j < (int)wd->rs[i].nlanes; j++) {
			l = &wd->lane[i][j];
			w = (int)l->wend - 1;
			data |= l->ring == ERX_PIPE_RING_LIVE &&
			    wd->published[w] > wd->taken[w];
		}
		if (data)
			fail(depth, "PI7", "a reader sleeps past published bytes (a lost wakeup)");
		if (wd->rs[i].lost)
			fail(depth, "PI7", "a reader sleeps past the pipe's loss (a lost wakeup)");
	}
	for (i = 0; i < sc->nw; i++) {
		p = &wd->w[i];
		if (!asleep(p) || !quiet(wd, p))
			continue;
		if (wd->ws[i].readers != 0 && !wd->ws[i].lost &&
		    erx_ring_room(RING, wd->ws[i].wpos, wd->mem.lane[i].rpos) >=
		    erx_ring_span(wd->ws[i].rec))
			fail(depth, "PI7", "a writer sleeps with room free (a lost wakeup)");
	}
}

/*
 * A read end's sleepers and waiters bits are set only for a wait in
 * progress, and it holds the reader lock only inside a call: an idle read
 * end whose stores have landed holds neither bit nor the lock, or every
 * co-reader's wait would ring it, or wait for it.  A lane closed once
 * drained is let go of and rung by no writer, so its sleepers bit no
 * longer counts.
 */
static void
check_idle(int depth)
{
	const world_t *wd = &worlds[depth];
	const erx_pipe_rlane_t *l;
	uint64_t bit;
	int i, j;

	if (sc->hostile != 0)
		return;
	for (i = 0; i < sc->nr; i++) {
		if (wd->r[i].state != IDLE || wd->r[i].nbuf != 0)
			continue;
		bit = UINT64_C(1) << wd->rs[i].rix;
		for (j = 0; j < (int)wd->rs[i].nlanes; j++) {
			l = &wd->lane[i][j];
			if (l->ring == ERX_PIPE_RING_LIVE &&
			    (wd->mem.lane[l->wend - 1].sleepers & bit) != 0)
				fail(depth, "PI7", "an idle reader left its sleepers bit set");
		}
		if ((wd->mem.waiters & bit) != 0)
			fail(depth, "PI7", "an idle reader left its waiters bit set");
		if (wd->mem.owner == 1 + wd->rs[i].rix)
			fail(depth, "PI7", "an idle reader holds the reader lock");
	}
}

/*
 * A read waits only with nothing copied: rpos is already past what it
 * copied, and the session's pipe NIF answers a wait with would_block and
 * drops its buffer, so a wait with bytes copied loses them.
 */
static void
check_wait_empty(int depth)
{
	const world_t *wd = &worlds[depth];
	int i;

	for (i = 0; i < sc->nr; i++)
		if (wd->r[i].state == CALL && wd->r[i].decided &&
		    wd->r[i].act.op == ERX_PIPE_OP_WAIT && wd->rs[i].done > 0)
			fail(depth, "PI5", "a read waits with bytes copied (they are lost)");
}

/* Posts report bits to every living read end. */
static void
tell_readers(world_t *wd, uint16_t bits)
{
	int r;

	for (r = 0; r < sc->nr; r++)
		if (alive(&wd->r[r]))
			wd->r[r].reports |= bits;
}

/* Read end r's executor applies one report; each wakes the end. */
static bool
rapply(world_t *wd, int r, uint16_t bit)
{
	erx_pipe_rstate_t *rs = &wd->rs[r];
	int w;

	if (bit == REP_JOIN) {
		w = sc->nw - 1;
		wd->lane[r][rs->nlanes] = (erx_pipe_rlane_t){ .wend =
		    (uint32_t)w + 1, .size = RING };
		rs->nlanes++;
		rs->known = (uint32_t)sc->nw;
	} else if (bit == REP_LOST) {
		rs->lost = true;
	} else if (bit < REP_RGONE(0)) {
		/* A write end's going travels after its stores, and after
		 * its join's report, on one channel. */
		for (w = 0; REP_WGONE(w) != bit; w++)
			;
		if (wd->w[w].nbuf != 0 || (wd->r[r].reports & REP_JOIN) != 0)
			return (false);
		for (uint32_t at = 0; at < rs->nlanes; at++)
			if (wd->lane[r][at].wend == (uint32_t)w + 1)
				wd->lane[r][at].writer = ERX_PIPE_WRITER_GONE;
	}
	wd->r[r].reports &= (uint16_t)~bit;
	wd->r[r].bell = 1;
	return (true);
}

/* Write end w's executor applies one report; each wakes the end. */
static void
wapply(world_t *wd, int w, uint16_t bit)
{
	if (bit == REP_LOST)
		wd->ws[w].lost = true;
	else
		wd->ws[w].readers--;
	wd->w[w].reports &= (uint16_t)~bit;
	wd->w[w].bell = 1;
}

/* The events of the holders' own: steps, actions, flushes. */
static int
explore_parties(int depth)
{
	world_t *cur = &worlds[depth], *nw;
	party_t *p;
	int events = 0, i, j;

	for (i = 0; i < NW_MAX + NR_MAX; i++) {
		bool writer = i < NW_MAX;
		int k = writer ? i : i - NW_MAX;

		p = writer ? &cur->w[k] : &cur->r[k];
		/* The step decides apart from the action, so reports land between. */
		if (p->state == CALL && !p->decided) {
			nw = successor(depth, writer ? "W step " : "R step ", k);
			next_action(nw, writer ? &nw->w[k] : &nw->r[k]);
			visit(depth + 1);
			events++;
		}
		if (ready(p)) {
			nw = successor(depth, writer ? "W " : "R ", k);
			snprintf(trace[depth + 1], sizeof(trace[0]), "%c%d %s",
			    writer ? 'W' : 'R', k, op_names[p->act.op]);
			perform(nw, writer ? &nw->w[k] : &nw->r[k], depth + 1);
			visit(depth + 1);
			events++;
		}
		for (j = 0; j < p->nbuf; j++) {
			if (!flushable(p, j))
				continue;
			nw = successor(depth, writer ? "W flush " : "R flush ", k);
			commit(nw, writer ? &nw->w[k] : &nw->r[k], j);
			visit(depth + 1);
			events++;
		}
	}
	return (events);
}

/* Write end w's next length, or 0 once its writes are done. */
static uint32_t
next_len(const world_t *wd, int w)
{
	return (wd->writes[w] < WRITES_MAX ? writes[w][wd->writes[w]] : 0);
}

/* The writers' calls, closes and deaths, and their reports applied. */
static int
explore_writers(int depth)
{
	world_t *cur = &worlds[depth], *nw;
	int events = 0, w, b;

	for (w = 0; w < sc->nw; w++) {
		const party_t *p = &cur->w[w];

		if (p->state == IDLE && next_len(cur, w) != 0) {
			nw = successor(depth, "W write ", w);
			erx_pipe_wstart(&nw->ws[w], next_len(nw, w));
			nw->writes[w]++;
			nw->w[w].base = nw->written[w];
			nw->w[w].state = CALL;
			next_action(nw, &nw->w[w]);
			visit(depth + 1);
			events++;
		}
		if ((p->state == IDLE && next_len(cur, w) == 0) ||
		    (sc->writer_dies && w == 0 && p->state == CALL)) {
			nw = successor(depth, p->state == IDLE ? "W close " :
			    "W dies ", w);
			nw->w[w].state = p->state == IDLE ? CLOSED : DEAD;
			nw->w[w].reports = 0;
			tell_readers(nw, (uint16_t)REP_WGONE(w));
			visit(depth + 1);
			events++;
		}
		for (b = 0; alive(p) && b < 16; b++) {
			if ((p->reports & 1u << b) == 0)
				continue;
			nw = successor(depth, "W applies a report ", w);
			wapply(nw, w, (uint16_t)(1u << b));
			visit(depth + 1);
			events++;
		}
	}
	return (events);
}

/* The readers' calls, closes and deaths, and their reports applied. */
static int
explore_readers(int depth)
{
	world_t *cur = &worlds[depth], *nw;
	int events = 0, r, b, k, w;

	for (r = 0; r < sc->nr; r++) {
		const party_t *p = &cur->r[r];

		if (p->state == IDLE && !(r == 0 && calls_max != 0 &&
		    cur->calls == calls_max)) {
			nw = successor(depth, "R read ", r);
			nw->calls += r == 0 && calls_max != 0;
			erx_pipe_rstart(&nw->rs[r], sc->read_len);
			nw->r[r].base = nw->received[r];
			nw->r[r].state = CALL;
			next_action(nw, &nw->r[r]);
			visit(depth + 1);
			events++;
		}
		/*
		 * The session's pipe NIF does not sleep at a wait: it returns,
		 * and its owner calls again, on a ring or a stray message,
		 * or, once its wait times out, with a read of 0 bytes.
		 * Either call starts the read afresh while the wait is still
		 * in progress.
		 */
		if (sc->nif && p->state == CALL && p->decided &&
		    p->act.op == ERX_PIPE_OP_WAIT) {
			for (k = 0; k < 2; k++) {
				nw = successor(depth, k == 0 ? "R reads again " :
				    "R gives up its wait ", r);
				erx_pipe_rstart(&nw->rs[r], k == 0 ? sc->read_len : 0);
				nw->quit[r] = k == 1;
				nw->r[r].steps = 0;
				next_action(nw, &nw->r[r]);
				visit(depth + 1);
				events++;
			}
		}
		if ((r == 0 && ((sc->reader_closes && p->state == IDLE &&
		    cur->eof[r] == 0) || (sc->reader_dies && p->state == CALL))) ||
		    (r == 0 && p->state == IDLE && calls_max != 0 &&
		    cur->calls == calls_max)) {
			nw = successor(depth, p->state == IDLE ? "R close " :
			    "R dies ", r);
			nw->r[r].state = p->state == IDLE ? CLOSED : DEAD;
			nw->r[r].reports = 0;
			nw->going |= (uint8_t)(1u << r);
			/* A co-reader that closes leaves its stream to the others. */
			nw->cut |= p->state == CALL || sc->nr == 1;
			visit(depth + 1);
			events++;
		}
		for (b = 0; alive(p) && b < 16; b++) {
			if ((p->reports & 1u << b) == 0)
				continue;
			nw = successor(depth, "R applies a report ", r);
			if (rapply(nw, r, (uint16_t)(1u << b))) {
				visit(depth + 1);
				events++;
			}
		}
	}
	/*
	 * The pipe server handles a read end's going once that end's stores
	 * have landed (its space has ended): it frees the reader lock if the
	 * end held it, by one compare-and-swap of owner, and tells every
	 * write end and every other read end.
	 */
	for (r = 0; r < sc->nr; r++) {
		if ((cur->going & 1u << r) == 0 || cur->r[r].nbuf != 0)
			continue;
		nw = successor(depth, "the server handles R's going ", r);
		if (nw->mem.owner == 1 + nw->rs[r].rix)
			nw->mem.owner = 0;
		nw->going &= (uint8_t)~(1u << r);
		for (w = 0; w < sc->nw; w++)
			if (alive(&nw->w[w]))
				nw->w[w].reports |= (uint16_t)REP_RGONE(r);
		for (k = 0; k < sc->nr; k++)
			if (k != r && alive(&nw->r[k]))
				nw->r[k].reports |= (uint16_t)REP_RGONE(r);
		visit(depth + 1);
		events++;
	}
	return (events);
}

/* The pipe server's own events: a join, the pipe's loss; and hostile rewrites. */
static int
explore_server(int depth)
{
	world_t *cur = &worlds[depth], *nw;
	int events = 0, k, w;

	/*
	 * The last write end joins while the first is open: the pipe server
	 * stores the new wends in the lock page, installs the end, and
	 * reports it to every read end.
	 */
	if (sc->joins && !cur->joined && alive(&cur->w[0])) {
		nw = successor(depth, "a write end joins", -1);
		w = sc->nw - 1;
		nw->mem.wends = (uint32_t)sc->nw;
		nw->joined = 1;
		nw->w[w].state = IDLE;
		nw->ws[w].readers = 0;
		for (k = 0; k < sc->nr; k++)
			nw->ws[w].readers += alive(&nw->r[k]);
		tell_readers(nw, REP_JOIN);
		visit(depth + 1);
		events++;
	}
	if (sc->lost && !cur->lost) {
		nw = successor(depth, "the pipe is lost", -1);
		nw->lost = 1;
		tell_readers(nw, REP_LOST);
		for (w = 0; w < sc->nw; w++)
			if (alive(&nw->w[w]))
				nw->w[w].reports |= REP_LOST;
		visit(depth + 1);
		events++;
	}
	for (k = 0; sc->hostile != 0 && !cur->hostile; k++) {
		nw = successor(depth, "hostile rewrite", -1);
		if (!rewrite(nw, k))
			break;
		nw->hostile = 1;
		snprintf(trace[depth + 1], sizeof(trace[0]), "hostile rewrite %d", k);
		visit(depth + 1);
		events++;
	}
	return (events);
}

static void
explore(int depth)
{
	int events;

	if ((uint64_t)depth > max_depth)
		max_depth = (uint64_t)depth;
	if (depth + 1 >= DEPTH_MAX)
		fail(depth, "depth", "the model's depth bound was reached");
	check_asleep(depth);
	check_idle(depth);
	check_wait_empty(depth);
	events = explore_parties(depth);
	events += explore_writers(depth);
	events += explore_readers(depth);
	events += explore_server(depth);
	if (events == 0)
		check_end(depth);
}

/* The first state: every end made, the joining one not yet installed. */
static void
start(world_t *wd)
{
	int r, w, at;

	memset(wd, 0, sizeof(*wd));
	wd->open_w = wd->open_k = NO_REC;
	wd->mem.wends = (uint32_t)(sc->joins ? sc->nw - 1 : sc->nw);
	for (w = 0; w < sc->nw; w++) {
		wd->ws[w].size = RING;
		wd->ws[w].chunk = CHUNK;
		wd->ws[w].readers = sc->nr;
		wd->ws[w].nonblock = sc->nonblock;
		wd->w[w].state = sc->joins && w == sc->nw - 1 ? ABSENT : IDLE;
	}
	for (r = 0; r < sc->nr; r++) {
		wd->rs[r].rix = (uint32_t)r;
		wd->rs[r].known = wd->mem.wends;
		wd->rs[r].batches = 2;
		wd->rs[r].nlanes = wd->mem.wends;
		wd->rs[r].nonblock = sc->nonblock;
		for (at = 0; at < (int)wd->mem.wends; at++) {
			wd->lane[r][at].wend = (uint32_t)at + 1;
			wd->lane[r][at].size = RING;
		}
		wd->r[r].state = sc->hostile == 'c' && r == sc->nr - 1 ?
		    HOSTILE : IDLE;
	}
}

int
main(int argc, char **argv)
{
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
	memcpy(lengths, strcmp(argv[2], "deep") == 0 ? sc->deep : sc->writes,
	    sizeof(lengths));
	calls_max = sc->calls[strcmp(argv[2], "deep") == 0];
	writes = lengths;
	start(&worlds[0]);
	visit(0);
	printf("pipe_explore %s states %llu depth %llu\n", sc->name,
	    (unsigned long long)seen_count, (unsigned long long)max_depth);
	free(seen);
	return (0);
}
