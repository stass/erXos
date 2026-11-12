/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe core's effects (liberx/erx_pipe_run.c) on real pages: one pipe
 * with one write end and one read end in one address space, driven by
 * erx_pipe_wrun and erx_pipe_rrun as a program's ends and the session's
 * pipe NIF drive them.  Each case prints FAIL and its name when it breaks;
 * test/host/pipe_run_test.rb seeds faults into the runner and expects the
 * case named beside each.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/pipe_run.h"

#define SIZE	ERX_PIPE_RING_FIRST

static int failures;

#define CHECK(name, cond) do {						\
	if (!(cond)) {							\
		printf("FAIL %s\n", name);				\
		failures++;						\
	}								\
} while (0)

typedef struct world {
	erx_lane_hdr_t	*hdr;
	unsigned char	*area;
	erx_pipe_rpage_t *rpage;
	erx_pipe_lock_t	*lock;
	erx_pipe_wstate_t w;
	erx_pipe_rstate_t r;
	erx_pipe_rlane_t lane;
	erx_pipe_wmap_t	 wmap;
	erx_pipe_rmap_t	 rmap;
	uint64_t	 clock;
	uint64_t	 join_at;	/* the clock at which a write end joins */
	int		 reader_rings;
	int		 writer_rings;
	int		 drained;
	int		 broken;
} world_t;

/*
 * The clock, copied once each look at a lane: at join_at a second write
 * end joins, as the pipe server stores wends in the lock page while a
 * read is under way, before the reader's executor applies its report.
 */
static uint64_t
fx_clock(void *ctx)
{
	world_t *wd = ctx;

	if (++wd->clock == wd->join_at)
		(void)erx_pipe_lock_wends_store(wd->lock, 2);
	return (wd->clock);
}

static void
fx_ring_reader(void *ctx, uint32_t rix)
{
	if (rix == 0)
		((world_t *)ctx)->reader_rings++;
}

static void
fx_ring_writer(void *ctx, uint32_t lane)
{
	if (lane == 0)
		((world_t *)ctx)->writer_rings++;
}

static void
fx_drained(void *ctx, uint32_t lane)
{
	world_t *wd = ctx;

	/* The NIF and liberx unmap a drained lane; no later action may touch it. */
	if (lane == 0) {
		wd->drained++;
		memset(&wd->rmap, 0, sizeof(wd->rmap));
	}
}

static void
fx_broken(void *ctx, uint32_t lane, uint64_t fault)
{
	(void)lane;
	(void)fault;
	((world_t *)ctx)->broken++;
}

static erx_pipe_fx_t fx;

static void *
page(size_t size)
{
	void *p;

	if (posix_memalign(&p, 4096, size) != 0)
		abort();
	memset(p, 0, size);
	return (p);
}

static void
world_init(world_t *wd)
{
	memset(wd, 0, sizeof(*wd));
	wd->hdr = page(4096);
	wd->area = page(SIZE);
	wd->rpage = page(4096);
	wd->lock = page(4096);
	(void)erx_pipe_lock_wends_store(wd->lock, 1);
	wd->w.size = SIZE;
	wd->w.chunk = ERX_PIPE_BUF;
	wd->w.readers = 1;
	wd->lane.wend = 1;
	wd->lane.size = SIZE;
	wd->r.rix = 0;
	wd->r.known = 1;
	wd->r.batches = ERX_PIPE_BATCHES;
	wd->r.lanes = &wd->lane;
	wd->r.nlanes = 1;
	wd->wmap = (erx_pipe_wmap_t){ wd->hdr, wd->area, wd->rpage };
	wd->rmap = (erx_pipe_rmap_t){ wd->hdr, wd->area, wd->rpage };
	fx = (erx_pipe_fx_t){ wd, fx_clock, fx_ring_reader, fx_ring_writer,
	    fx_drained, fx_broken };
}

static void
world_free(world_t *wd)
{
	free(wd->hdr);
	free(wd->area);
	free(wd->rpage);
	free(wd->lock);
}

static erx_pipe_act_t
do_write(world_t *wd, const void *buf, uint64_t len)
{
	erx_pipe_wstart(&wd->w, len);
	return (erx_pipe_wrun(&wd->w, &wd->wmap, buf, &fx));
}

/* A read as the NIF makes it: a fresh call that never waits. */
static erx_pipe_act_t
do_read(world_t *wd, void *buf, uint64_t len)
{
	erx_pipe_rstart(&wd->r, len);
	return (erx_pipe_rrun(&wd->r, &wd->rmap, wd->lock, buf, &fx));
}

static bool
done(erx_pipe_act_t act, int64_t result)
{
	return (act.op == ERX_PIPE_OP_DONE && act.result == result);
}

static void
case_bytes_pass(void)
{
	world_t wd;
	char out[64];

	world_init(&wd);
	CHECK("bytes write", done(do_write(&wd, "hello", 5), 5));
	memset(out, 0, sizeof(out));
	CHECK("bytes read", done(do_read(&wd, out, sizeof(out)), 5) &&
	    memcmp(out, "hello", 5) == 0);
	CHECK("bytes owner free", atomic_load(&wd.lock->owner) == 0);
	world_free(&wd);
}

static void
case_empty_waits_and_is_rung(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	CHECK("empty waits", do_read(&wd, out, sizeof(out)).op ==
	    ERX_PIPE_OP_WAIT);
	CHECK("empty sleeper published", atomic_load(&wd.rpage->sleepers) == 1);
	CHECK("empty lock released", atomic_load(&wd.lock->owner) == 0);
	CHECK("empty write", done(do_write(&wd, "x", 1), 1));
	CHECK("empty reader rung", wd.reader_rings == 1);
	CHECK("empty read after ring", done(do_read(&wd, out, sizeof(out)), 1) &&
	    out[0] == 'x');
	world_free(&wd);
}

/*
 * Read end 1 arms the lane as a co-reader does, its sleepers bit and wake
 * one past rpos, and a write crosses that wake: only read ends still
 * waiting may be rung.
 */
static void
co_reader_armed_and_crossed(world_t *wd)
{
	uint64_t rpos = 0;

	(void)erx_pipe_rpage_rpos_load(wd->rpage, &rpos);
	(void)atomic_fetch_or(&wd->rpage->sleepers, UINT64_C(2));
	(void)erx_pipe_rpage_wake_store(wd->rpage, rpos + 1);
	(void)do_write(wd, "y", 1);
}

/*
 * A wait ends with the read that follows it, whatever that read returns: a
 * read that waited, was rung and then read the data leaves no sleepers bit,
 * so a co-reader's later wait does not ring this end.
 */
static void
case_wait_ends_with_next_read(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	(void)do_read(&wd, out, sizeof(out));
	(void)do_write(&wd, "x", 1);
	CHECK("ended read gets data", done(do_read(&wd, out, sizeof(out)), 1));
	CHECK("ended sleeper cleared", atomic_load(&wd.rpage->sleepers) == 0);
	co_reader_armed_and_crossed(&wd);
	CHECK("ended not rung again", wd.reader_rings == 1);
	world_free(&wd);
}

/*
 * A read of 0 bytes, which the NIF's owner makes when its wait times out,
 * ends the wait without reading: no sleepers bit is left, and a
 * co-reader's later wait does not ring this end.
 */
static void
case_wait_ends_with_empty_read(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	(void)do_read(&wd, out, sizeof(out));
	CHECK("timeout ends wait", done(do_read(&wd, out, 0), 0));
	CHECK("timeout sleeper cleared", atomic_load(&wd.rpage->sleepers) == 0);
	co_reader_armed_and_crossed(&wd);
	CHECK("timeout not rung", wd.reader_rings == 0);
	world_free(&wd);
}

/*
 * A wait for the reader lock ends the same way: once read end 1 lets the
 * lock go, the next read takes it and leaves no waiters bit, so read end
 * 1's later releases do not ring this end.
 */
static void
case_lock_wait_ends_with_next_read(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	(void)do_write(&wd, "x", 1);
	(void)erx_pipe_lock_owner_store(wd.lock, 2);
	CHECK("lock waits", do_read(&wd, out, sizeof(out)).op ==
	    ERX_PIPE_OP_WAIT);
	CHECK("lock waiter published", atomic_load(&wd.lock->waiters) == 1);
	(void)erx_pipe_lock_owner_store(wd.lock, 0);
	CHECK("lock read after release", done(do_read(&wd, out, sizeof(out)), 1));
	CHECK("lock waiter cleared", atomic_load(&wd.lock->waiters) == 0);
	world_free(&wd);
}

/*
 * A write end joins after a read has copied a record and before it looks
 * for the next: the read returns what it copied, since rpos is past it
 * and a wait would make the NIF answer would_block and drop it.  Once
 * the join's report is applied, the next read takes the next record.
 */
static void
case_join_keeps_copied_bytes(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	(void)do_write(&wd, "a", 1);
	(void)do_write(&wd, "b", 1);
	wd.join_at = wd.clock + 2;	/* the look after the first record */
	memset(out, 0, sizeof(out));
	CHECK("join read keeps copied bytes",
	    done(do_read(&wd, out, sizeof(out)), 1) && out[0] == 'a');
	CHECK("join read leaves no bits",
	    atomic_load(&wd.rpage->sleepers) == 0 &&
	    atomic_load(&wd.lock->waiters) == 0);
	CHECK("join read waits for the report", do_read(&wd, out,
	    sizeof(out)).op == ERX_PIPE_OP_WAIT);
	wd.r.known = 2;		/* the join's report applied */
	CHECK("join read after the report", done(do_read(&wd, out,
	    sizeof(out)), 1) && out[0] == 'b');
	world_free(&wd);
}

/*
 * A read end that takes an index clears that index's bits, which an end
 * that held it before and died mid-wait may have left set, and no other
 * end's bits.
 */
static void
case_take_clears_bits(void)
{
	world_t wd;

	world_init(&wd);
	(void)atomic_fetch_or(&wd.rpage->sleepers, UINT64_C(0x6));
	(void)atomic_fetch_or(&wd.lock->waiters, UINT64_C(0x6));
	CHECK("take refuses a bad index", !erx_pipe_rtake(&wd.r,
	    ERX_PIPE_READERS_MAX, &wd.rmap, wd.lock));
	CHECK("take clears bits", erx_pipe_rtake(&wd.r, 1, &wd.rmap, wd.lock) &&
	    wd.r.rix == 1 &&
	    atomic_load(&wd.rpage->sleepers) == UINT64_C(0x4) &&
	    atomic_load(&wd.lock->waiters) == UINT64_C(0x4));
	world_free(&wd);
}

static void
case_record_whole(void)
{
	world_t wd;
	static unsigned char in[ERX_PIPE_BUF], out[2 * ERX_PIPE_BUF];
	size_t i;

	world_init(&wd);
	for (i = 0; i < sizeof(in); i++)
		in[i] = (unsigned char)(i * 7 + 3);
	CHECK("record write", done(do_write(&wd, in, sizeof(in)), ERX_PIPE_BUF));
	CHECK("record read whole", done(do_read(&wd, out, sizeof(out)),
	    ERX_PIPE_BUF) && memcmp(in, out, sizeof(in)) == 0);
	world_free(&wd);
}

/* A full ring: the write waits with what it published, and a read rings it. */
static void
case_full_ring(void)
{
	world_t wd;
	static unsigned char in[2 * SIZE], out[2 * SIZE];
	erx_pipe_act_t act;
	uint64_t got;

	world_init(&wd);
	memset(in, 'a', sizeof(in));
	act = do_write(&wd, in, sizeof(in));
	CHECK("full waits", act.op == ERX_PIPE_OP_WAIT);
	CHECK("full published part", wd.w.done > 0 && wd.w.done < SIZE);
	got = 0;
	while (got < wd.w.done) {
		act = do_read(&wd, out, sizeof(out));
		if (act.op != ERX_PIPE_OP_DONE || act.result <= 0)
			break;
		got += (uint64_t)act.result;
	}
	CHECK("full read all", got == wd.w.done);
	CHECK("full writer rung", wd.writer_rings >= 1);
	/* The write resumes where it stopped. */
	act = erx_pipe_wrun(&wd.w, &wd.wmap, in, &fx);
	CHECK("full resumes", act.op == ERX_PIPE_OP_WAIT ||
	    act.op == ERX_PIPE_OP_DONE);
	world_free(&wd);
}

static void
case_writer_gone(void)
{
	world_t wd;
	char out[16];

	world_init(&wd);
	CHECK("gone write", done(do_write(&wd, "ab", 2), 2));
	wd.lane.writer = ERX_PIPE_WRITER_GONE;
	CHECK("gone bytes first", done(do_read(&wd, out, sizeof(out)), 2));
	CHECK("gone then eof", done(do_read(&wd, out, sizeof(out)), 0));
	CHECK("gone drained once", wd.drained == 1);
	CHECK("gone eof again", done(do_read(&wd, out, sizeof(out)), 0) &&
	    wd.drained == 1);
	world_free(&wd);
}

static void
case_reader_gone_and_lost(void)
{
	world_t wd;
	char out[4];

	world_init(&wd);
	wd.w.readers = 0;
	CHECK("epipe", done(do_write(&wd, "a", 1), -EPIPE));
	wd.r.lost = true;
	CHECK("lost eio", done(do_read(&wd, out, sizeof(out)), -EIO));
	world_free(&wd);
}

/* A hostile writer's record past the area is refused, never copied. */
static void
case_hostile_record(void)
{
	world_t wd;
	char out[16];
	uint32_t bad[4] = { ERX_PIPE_BUF + 1, ERX_REC_DATA, 0, 0 };

	world_init(&wd);
	memcpy(wd.area, bad, sizeof(bad));
	(void)erx_lane_hdr_wpos_store(wd.hdr, 16);
	CHECK("hostile no bytes", do_read(&wd, out, sizeof(out)).result <= 0);
	CHECK("hostile broken", wd.broken == 1);
	world_free(&wd);
}

int
main(void)
{
	case_bytes_pass();
	case_join_keeps_copied_bytes();
	case_take_clears_bits();
	case_empty_waits_and_is_rung();
	case_wait_ends_with_next_read();
	case_wait_ends_with_empty_read();
	case_lock_wait_ends_with_next_read();
	case_record_whole();
	case_full_ring();
	case_writer_gone();
	case_reader_gone_and_lost();
	case_hostile_record();
	if (failures != 0)
		return (1);
	printf("pipe_run done\n");
	return (0);
}
