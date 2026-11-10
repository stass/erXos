/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver for the lane's reader and writer (liberx/erx_lane.c).  It
 * plays the producer for the reader and the consumer for the writer, and
 * judges every result against an independent model of the party's
 * position, then prints what it reached; any disagreement prints FAIL and
 * exits 1.  Modes:
 *
 *   explore  every interleaving of a producer and the reader over a 64-byte
 *            area, records of 0 to 100 bytes, three start positions and four
 *            buffer sizes, with both wake handshakes, states deduplicated;
 *            each party's store, fence and load of the other's position
 *            is one step but the producer's wait, so this checks the
 *            handshakes' positions and crossings under sequential
 *            consistency; their fences are the weak-memory litmus tests';
 *   cuts     a record longer than the lane and a shorter one, published
 *            with a cut at every 16-byte boundary, read with three buffer
 *            sizes, against the record written whole;
 *   limits   every refusal and the positions and lengths at their bounds;
 *   writer   the writer and the reader over one lane, records of 0 to
 *            12000 bytes in three pieces, three start positions, three
 *            reserves, four buffer sizes and four schedules, with both
 *            wake handshakes; every put against the model of what it
 *            writes, every byte, every need and every ring;
 *   wlimits  every refusal of the writer and its bounds, and need's sums;
 *   race     the writer, the reader and (second phase, the writer stopped,
 *            until the reader refuses) a mutator that rewrites the
 *            producer's side, on three threads, for TSan;
 *   wrace    the writer against a consumer that publishes plausible
 *            positions, then garbage until the writer refuses, for TSan.
 *
 * The explore mode shrinks the reader's area to 64 bytes after a normal
 * init, which init itself refuses: the reader's arithmetic depends on the
 * size only through its mask, and a small area lets the exploration fill,
 * wrap and wait in few steps.
 */

#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/lane.h"

#define PAGE		4096
#define LANE_SIZE	4096
#define SMALL		64
#define BIG		SIZE_MAX
#define MAX_RECORDS	4
#define MAX_STREAM	16384

static _Alignas(PAGE) unsigned char peer_mem[ERX_LANE_SIDE_DATA + LANE_SIZE];
static _Alignas(PAGE) unsigned char own_mem[ERX_LANE_SIDE_DATA];

static erx_lane_hdr_t *
header(void)
{
	return ((erx_lane_hdr_t *)peer_mem);
}

static erx_lane_rpage_t *
rpage(void)
{
	return ((erx_lane_rpage_t *)(own_mem + ERX_LANE_SIDE_RPAGE));
}

static _Atomic uint64_t *
words(void)
{
	return ((_Atomic uint64_t *)(peer_mem + ERX_LANE_SIDE_DATA));
}

static void
fail(const char *what, unsigned long long a, unsigned long long b)
{
	printf("FAIL: %s (%llu, %llu)\n", what, a, b);
	exit(1);
}

#define CHECK(cond, what, a, b) do {				\
	if (!(cond))						\
		fail((what), (unsigned long long)(a),		\
		    (unsigned long long)(b));			\
} while (0)

static void
store_u64(_Atomic uint64_t *word, uint64_t value)
{
	atomic_store_explicit(word, value, memory_order_relaxed);
}

static uint64_t
grain_up(uint64_t value)
{
	return ((value + 15) & ~UINT64_C(15));
}

/* A record's body byte, distinct per record, offset and stream. */
static unsigned char
body_byte(uint64_t record, uint64_t offset)
{
	return ((unsigned char)(record * 37 + offset * 11 + 5));
}

/*
 * The producer's byte stream: records laid end to end, each a header and
 * a body padded to 16, as positions from a base.
 */
typedef struct stream stream_t;
struct stream {
	uint64_t	 base;
	uint64_t	 total;
	uint64_t	 starts[MAX_RECORDS + 1];
	uint32_t	 lens[MAX_RECORDS];
	unsigned	 nrecords;
	unsigned char	 bytes[MAX_STREAM];
};

static void
stream_make(stream_t *s, uint64_t base, const uint32_t *lens, unsigned n)
{
	uint64_t at;

	memset(s, 0, sizeof(*s));
	s->base = base;
	s->nrecords = n;
	at = 0;
	for (unsigned i = 0; i < n; i++) {
		s->starts[i] = at;
		s->lens[i] = lens[i];
		CHECK(at + 16 + grain_up(lens[i]) <= MAX_STREAM, "stream size",
		    at, lens[i]);
		for (int k = 0; k < 4; k++)
			s->bytes[at + k] = (unsigned char)(lens[i] >> (8 * k));
		s->bytes[at + 4] = (unsigned char)(i + 1);	/* kind */
		s->bytes[at + 8] = (unsigned char)(0x40 + i);	/* zero word */
		for (uint64_t o = 0; o < lens[i]; o++)
			s->bytes[at + 16 + o] = body_byte(i, o);
		at += 16 + grain_up(lens[i]);
	}
	s->starts[n] = at;
	s->total = at;
}

/* Writes the stream's grains [from, to) into an area of size bytes. */
static void
stream_write(const stream_t *s, uint64_t size, uint64_t from, uint64_t to)
{
	uint64_t word;

	for (uint64_t pos = from; pos < to; pos += 8) {
		memcpy(&word, s->bytes + (pos - s->base), 8);
		store_u64(&words()[(pos & (size - 1)) / 8], word);
	}
}

/* The end of the stream's record that holds position pos. */
static uint64_t
stream_record_end(const stream_t *s, uint64_t pos)
{
	for (unsigned i = 0; i < s->nrecords; i++)
		if (pos < s->base + s->starts[i + 1])
			return (s->base + s->starts[i + 1]);
	return (s->base + s->total);
}

/* Starts an empty lane at position base, as if base bytes had passed. */
static void
place(erx_lane_reader_t *reader, uint64_t size, uint64_t base)
{
	memset(peer_mem, 0, sizeof(peer_mem));
	memset(own_mem, 0, sizeof(own_mem));
	CHECK(erx_lane_reader_init(reader, peer_mem, own_mem, LANE_SIZE),
	    "init", LANE_SIZE, 0);
	reader->size = size;
	reader->pos = base;
	erx_lane_hdr_wpos_store(header(), base);
	erx_lane_rpage_rpos_store(rpage(), base);
}

/* ---------------------------------------------------------------- explore */

static const size_t maxes[] = { 0, 5, 16, BIG };

/*
 * One state of the exploration: the shared words, the reader, and the
 * model of both parties.  The area's bytes are a function of wpos, since
 * the producer writes exactly the stream, so they are not part of the key.
 */
typedef struct world world_t;
struct world {
	erx_lane_reader_t reader;
	uint64_t	 wpos;		/* the producer's own copy */
	uint64_t	 need;
	uint64_t	 wake;
	uint64_t	 rpos;
	uint64_t	 mpos;		/* the model's consumer position */
	unsigned	 record;	/* the model's open record */
	uint64_t	 offset;	/* body bytes of it taken */
	bool		 opened;	/* its header is taken */
	bool		 prod_waiting;	/* need published, rpos not yet reread */
	bool		 prod_parked;
	bool		 cons_parked;
};

typedef struct counts counts_t;
struct counts {
	unsigned long	 states;
	unsigned long	 takes;
	unsigned long	 empty;
	unsigned long	 wraps;
	unsigned long	 partial;
	unsigned long	 header_only;
	unsigned long	 prod_waits;
	unsigned long	 prod_parks;
	unsigned long	 cons_parks;
	unsigned long	 rings_prod;
	unsigned long	 rings_cons;
	unsigned long	 finished;
};

static counts_t counts;
static stream_t stream;

#define TABLE_BITS	19
#define TABLE_SIZE	(1UL << TABLE_BITS)

typedef struct visit_key visit_key_t;
struct visit_key {
	uint64_t	 v[5];
	unsigned	 gen;	/* the scenario that stored it */
};

static visit_key_t *table;
static unsigned table_gen;

static void
world_key(const world_t *w, uint64_t *v)
{
	v[0] = w->wpos;
	v[1] = w->need;
	v[2] = w->wake;
	v[3] = w->mpos;
	v[4] = (uint64_t)w->prod_parked | (uint64_t)w->cons_parked << 1 |
	    (uint64_t)w->opened << 2 | (uint64_t)w->prod_waiting << 3;
}

/* Whether the state is new; records it. */
static bool
visit(const world_t *w)
{
	uint64_t h, v[5];
	size_t slot;

	world_key(w, v);
	h = 1469598103934665603ULL;
	for (int i = 0; i < 5; i++)
		h = (h ^ v[i]) * 1099511628211ULL;
	for (size_t probe = 0; probe < TABLE_SIZE; probe++) {
		slot = (h + probe) & (TABLE_SIZE - 1);
		if (table[slot].gen != table_gen) {
			memcpy(table[slot].v, v, sizeof(v));
			table[slot].gen = table_gen;
			counts.states++;
			return (true);
		}
		if (memcmp(table[slot].v, v, sizeof(v)) == 0)
			return (false);
	}
	fail("state table full", counts.states, 0);
	return (false);
}

/* Makes the shared memory hold w. */
static void
world_restore(const world_t *w)
{
	uint64_t size = w->reader.size;
	uint64_t low;

	low = w->wpos > size ? w->wpos - size : stream.base;
	if (low < stream.base)
		low = stream.base;
	memset(peer_mem + ERX_LANE_SIDE_DATA, 0, size);
	stream_write(&stream, size, low, w->wpos);
	erx_lane_hdr_wpos_store(header(), w->wpos);
	erx_lane_hdr_need_store(header(), w->need);
	erx_lane_rpage_rpos_store(rpage(), w->rpos);
	erx_lane_rpage_wake_store(rpage(), w->wake);
}

static bool
stream_done(const world_t *w)
{
	return (w->wpos == stream.base + stream.total);
}

static bool
consumer_done(const world_t *w)
{
	return (w->mpos == stream.base + stream.total);
}

/* The reader's result, judged against the model; updates both. */
static void
judge_take(world_t *w, erx_lane_status_t st, const erx_lane_part_t *part,
    const unsigned char *buf, size_t max, uint64_t old_rpos)
{
	uint64_t avail, len, n, start, want_rpos;
	bool ring;

	counts.takes++;
	CHECK(st != ERX_LANE_MALFORMED, "a sound lane refused",
	    w->reader.fault, w->mpos);
	if (w->mpos == w->wpos) {
		CHECK(st == ERX_LANE_EMPTY, "empty lane took", w->mpos, st);
		counts.empty++;
		return;
	}
	CHECK(st == ERX_LANE_TOOK, "published bytes not taken", w->mpos, st);
	CHECK(part->opened == !w->opened, "opened", part->opened, w->opened);
	if (!w->opened) {
		w->opened = true;
		w->mpos += 16;
	}
	len = stream.lens[w->record];
	CHECK(part->len == len && part->kind == w->record + 1 &&
	    part->zero == 0x40 + w->record, "header", part->len, len);
	CHECK(part->offset == w->offset, "offset", part->offset, w->offset);
	avail = w->wpos - w->mpos;
	n = len - w->offset;
	if (avail < n)
		n = avail;
	if (max < n)
		n = max;
	CHECK(part->copied == n, "copied", part->copied, n);
	start = (w->mpos & (w->reader.size - 1));
	if (n > 0 && start + n > w->reader.size)
		counts.wraps++;
	for (uint64_t i = 0; i < n; i++)
		CHECK(buf[i] == body_byte(w->record, w->offset + i), "byte",
		    w->offset + i, buf[i]);
	w->offset += n;
	w->mpos += n;
	CHECK(part->closed == (w->offset == len), "closed", part->closed,
	    w->offset);
	if (!part->closed && !part->opened)
		counts.partial++;
	if (part->opened && part->copied == 0 && !part->closed)
		counts.header_only++;
	if (part->closed) {
		w->mpos = grain_up(w->mpos);
		w->record++;
		w->offset = 0;
		w->opened = false;
	}

	CHECK(w->reader.pos == w->mpos, "reader position", w->reader.pos,
	    w->mpos);
	want_rpos = w->mpos & ~UINT64_C(15);
	erx_lane_rpage_rpos_load(rpage(), &w->rpos);
	CHECK(w->rpos == want_rpos, "published rpos", w->rpos, want_rpos);
	CHECK(w->rpos <= w->wpos, "rpos passed wpos", w->rpos, w->wpos);
	ring = old_rpos < w->need && w->need <= w->rpos;
	CHECK(part->ring == ring, "ring", part->ring, ring);
	if (part->ring) {
		counts.rings_prod++;
		w->prod_parked = false;
	}
}

static void
consumer_step(world_t *w, size_t max, bool armed)
{
	unsigned char buf[256];
	erx_lane_part_t part;
	erx_lane_status_t st;
	uint64_t old_rpos = w->rpos;

	st = armed ? erx_lane_take_armed(&w->reader, buf, max, &part) :
	    erx_lane_take(&w->reader, buf, max, &part);
	if (armed) {
		erx_lane_rpage_wake_load(rpage(), &w->wake);
		CHECK(w->wake == (w->mpos & ~UINT64_C(15)) + 1, "wake", w->wake, w->mpos);
	}
	judge_take(w, st, &part, buf, max, old_rpos);
	if (armed && st == ERX_LANE_EMPTY) {
		w->cons_parked = true;
		counts.cons_parks++;
	}
}

/*
 * The producer publishes up to grains grains of what room allows; with no
 * room it publishes the read position it waits for, need, and fences;
 * producer_recheck then reads rpos once more and parks if still short, so
 * the consumer's takes interleave between the two.  After a store of wpos it rings
 * the consumer if the store crossed wake.
 */
static void
producer_step(world_t *w, uint64_t grains)
{
	uint64_t bytes, end, n, old, room, rpos, size = w->reader.size;

	erx_lane_rpage_rpos_load(rpage(), &rpos);
	room = size - (w->wpos - rpos);
	n = stream.base + stream.total - w->wpos;
	if (room < n)
		n = room;
	if (grains * 16 < n)
		n = grains * 16;
	if (n == 0) {
		end = stream_record_end(&stream, w->wpos);
		bytes = end - w->wpos < size / 4 ? end - w->wpos : size / 4;
		w->need = w->wpos + bytes - size;
		erx_lane_hdr_need_store(header(), w->need);
		counts.prod_waits++;
		w->prod_waiting = true;
		return;
	}
	stream_write(&stream, size, w->wpos, w->wpos + n);
	old = w->wpos;
	w->wpos += n;
	erx_lane_hdr_wpos_store(header(), w->wpos);
	if (old < w->wake && w->wake <= w->wpos) {
		counts.rings_cons++;
		w->cons_parked = false;
	}
}

/* The second half of a wait: after the fence, rpos once more. */
static void
producer_recheck(world_t *w)
{
	uint64_t rpos;

	erx_lane_rpage_rpos_load(rpage(), &rpos);
	w->prod_waiting = false;
	if (rpos < w->need) {
		w->prod_parked = true;
		counts.prod_parks++;
	}
}

typedef struct world_stack world_stack_t;
struct world_stack {
	world_t		*items;
	size_t		 n;
	size_t		 cap;
};

static void
push(world_stack_t *s, const world_t *w)
{
	if (!visit(w))
		return;
	if (s->n == s->cap) {
		s->cap = s->cap ? s->cap * 2 : 1024;
		s->items = realloc(s->items, s->cap * sizeof(*s->items));
		CHECK(s->items != NULL, "memory", s->cap, 0);
	}
	s->items[s->n++] = *w;
}

static void
explore_one(uint64_t base)
{
	world_stack_t stack = { 0 };
	world_t start, w;

	memset(&start, 0, sizeof(start));
	place(&start.reader, SMALL, base);
	start.wpos = start.rpos = start.mpos = base;
	table_gen++;
	push(&stack, &start);
	while (stack.n > 0) {
		const world_t cur = stack.items[--stack.n];
		bool stuck;

		stuck = cur.cons_parked && (cur.prod_parked || stream_done(&cur));
		CHECK(!stuck || consumer_done(&cur), "a wait was lost",
		    cur.mpos, cur.wpos);
		if (consumer_done(&cur) && stream_done(&cur))
			counts.finished++;
		if (!cur.cons_parked) {
			for (size_t i = 0; i < sizeof(maxes) / sizeof(maxes[0]);
			    i++) {
				w = cur;
				world_restore(&w);
				consumer_step(&w, maxes[i], false);
				push(&stack, &w);
			}
			if (cur.mpos == cur.wpos) {
				w = cur;
				world_restore(&w);
				consumer_step(&w, BIG, true);
				push(&stack, &w);
			}
		}
		if (cur.prod_waiting) {
			w = cur;
			world_restore(&w);
			producer_recheck(&w);
			push(&stack, &w);
		} else if (!cur.prod_parked && !stream_done(&cur)) {
			w = cur;
			world_restore(&w);
			producer_step(&w, 1);
			push(&stack, &w);
			w = cur;
			world_restore(&w);
			producer_step(&w, SMALL);
			push(&stack, &w);
		}
	}
	free(stack.items);
}

static int
explore(void)
{
	static const uint32_t lens[] = { 0, 1, 16, 17, 40, 100 };
	static const uint32_t triple[] = { 0, 17, 40 };
	static const uint64_t bases[] = { 0, SMALL - 32, SMALL - 16 };
	const unsigned nl = sizeof(lens) / sizeof(lens[0]);
	unsigned long scenarios = 0;
	uint32_t list[3];

	table = calloc(TABLE_SIZE, sizeof(*table));
	CHECK(table != NULL, "memory", 0, 0);
	for (size_t b = 0; b < sizeof(bases) / sizeof(bases[0]); b++) {
		for (unsigned i = 0; i < nl; i++) {
			list[0] = lens[i];
			stream_make(&stream, bases[b], list, 1);
			explore_one(bases[b]);
			scenarios++;
			for (unsigned j = 0; j < nl; j++) {
				list[1] = lens[j];
				stream_make(&stream, bases[b], list, 2);
				explore_one(bases[b]);
				scenarios++;
			}
		}
		for (unsigned i = 0; i < 27; i++) {
			list[0] = triple[i % 3];
			list[1] = triple[i / 3 % 3];
			list[2] = triple[i / 9];
			stream_make(&stream, bases[b], list, 3);
			explore_one(bases[b]);
			scenarios++;
		}
	}
	free(table);
	printf("explore: scenarios=%lu states=%lu takes=%lu empty=%lu "
	    "wraps=%lu partial=%lu header_only=%lu prod_waits=%lu "
	    "prod_parks=%lu cons_parks=%lu rings_prod=%lu rings_cons=%lu "
	    "finished=%lu\n", scenarios, counts.states, counts.takes,
	    counts.empty, counts.wraps, counts.partial, counts.header_only,
	    counts.prod_waits, counts.prod_parks, counts.cons_parks,
	    counts.rings_prod, counts.rings_cons, counts.finished);
	return (0);
}

/* ------------------------------------------------------------------- cuts */

/*
 * Publishes one record with a first cut of cut bytes, then the rest as
 * room returns, and reads it with buffers of max bytes; the body read
 * must equal the body written.
 */
static void
cut_one(uint32_t len, uint64_t base, uint64_t cut, size_t max)
{
	static unsigned char got[MAX_STREAM];
	erx_lane_reader_t reader;
	erx_lane_part_t part;
	erx_lane_status_t st;
	uint64_t end, n, room, rpos, taken, wpos;
	bool closed = false;

	stream_make(&stream, base, &len, 1);
	place(&reader, LANE_SIZE, base);
	end = base + stream.total;
	wpos = base;
	taken = 0;
	n = cut;
	while (!closed) {
		erx_lane_rpage_rpos_load(rpage(), &rpos);
		room = LANE_SIZE - (wpos - rpos);
		if (n > room)
			n = room;
		if (n > end - wpos)
			n = end - wpos;
		stream_write(&stream, LANE_SIZE, wpos, wpos + n);
		wpos += n;
		erx_lane_hdr_wpos_store(header(), wpos);
		n = end - wpos;
		do {
			st = erx_lane_take(&reader, got + taken, max, &part);
			CHECK(st != ERX_LANE_MALFORMED, "cut refused", cut,
			    reader.fault);
			if (st == ERX_LANE_TOOK) {
				CHECK(part.offset == taken, "cut offset",
				    part.offset, taken);
				taken += part.copied;
				closed = part.closed;
			}
		} while (st == ERX_LANE_TOOK && !closed);
	}
	CHECK(taken == len, "cut length", taken, len);
	for (uint64_t i = 0; i < len; i++)
		CHECK(got[i] == body_byte(0, i), "cut byte", cut, i);
	CHECK(reader.pos == end, "cut end", reader.pos, end);
}

static int
cuts(void)
{
	static const uint32_t lens[] = { LANE_SIZE + 40, 1000 };
	static const size_t cut_maxes[] = { BIG, 16, 7 };
	unsigned long runs = 0;
	uint64_t base = LANE_SIZE - 48;

	for (size_t l = 0; l < 2; l++)
		for (uint64_t cut = 16; cut <= 16 + grain_up(lens[l]);
		    cut += 16)
			for (size_t m = 0; m < 3; m++) {
				cut_one(lens[l], base, cut, cut_maxes[m]);
				runs++;
			}
	printf("cuts: runs=%lu\n", runs);
	return (0);
}

/* ----------------------------------------------------------------- limits */

static erx_lane_status_t
take_at(erx_lane_reader_t *reader, uint64_t wpos, size_t max,
    erx_lane_part_t *part)
{
	static unsigned char buf[LANE_SIZE];

	erx_lane_hdr_wpos_store(header(), wpos);
	return (erx_lane_take(reader, buf, max, part));
}

static void
put_header(uint64_t pos, uint32_t len)
{
	uint64_t word = len;

	store_u64(&words()[(pos & (LANE_SIZE - 1)) / 8], word);
	store_u64(&words()[((pos + 8) & (LANE_SIZE - 1)) / 8], 0);
}

static void
expect_fault(erx_lane_reader_t *reader, uint64_t wpos,
    erx_lane_fault_t fault, const char *what)
{
	erx_lane_part_t part;

	CHECK(take_at(reader, wpos, BIG, &part) == ERX_LANE_MALFORMED, what,
	    wpos, reader->fault);
	CHECK(reader->fault == fault, what, reader->fault, fault);
	/* Refusal is permanent: a sound wpos afterwards changes nothing. */
	CHECK(take_at(reader, reader->pos, BIG, &part) == ERX_LANE_MALFORMED,
	    "refusal is permanent", reader->pos, 0);
	CHECK(erx_lane_take_armed(reader, NULL, 0, &part) ==
	    ERX_LANE_MALFORMED, "armed refusal is permanent", reader->pos, 0);
}

static int
limits(void)
{
	static const uint64_t bad_sizes[] = { 0, 16, 2048, LANE_SIZE + 16,
	    3 * LANE_SIZE, 2 * (uint64_t)ERX_LANE_MAX, UINT64_MAX };
	const uint64_t top = UINT64_MAX - 15;	/* the last position */
	erx_lane_reader_t reader;
	erx_lane_part_t part;
	uint64_t need, wake;
	unsigned long cases = 0;

	/* Init refuses every size off the range and every misaligned side. */
	for (size_t i = 0; i < sizeof(bad_sizes) / sizeof(bad_sizes[0]); i++)
		CHECK(!erx_lane_reader_init(&reader, peer_mem, own_mem,
		    bad_sizes[i]), "bad size accepted", bad_sizes[i], 0);
	CHECK(!erx_lane_reader_init(&reader, peer_mem + 8, own_mem, LANE_SIZE),
	    "misaligned peer side", 8, 0);
	CHECK(!erx_lane_reader_init(&reader, peer_mem, own_mem + 16, LANE_SIZE),
	    "misaligned own side", 16, 0);
	CHECK(!erx_lane_reader_init(&reader, NULL, own_mem, LANE_SIZE),
	    "null side", 0, 0);
	CHECK(erx_lane_reader_init(&reader, peer_mem, own_mem, ERX_LANE_MIN) &&
	    erx_lane_reader_init(&reader, peer_mem, own_mem, ERX_LANE_MAX),
	    "bounds of the size range refused", ERX_LANE_MIN, ERX_LANE_MAX);
	cases += 11;

	/* wpos off its bounds, each from a fresh lane at 0 and near the top. */
	static const uint64_t bases[] = { 0, LANE_SIZE - 16, top - 2 * LANE_SIZE };
	for (size_t b = 0; b < 3; b++) {
		uint64_t base = bases[b];

		place(&reader, LANE_SIZE, base);
		expect_fault(&reader, base + 1, ERX_LANE_WPOS_UNALIGNED,
		    "unaligned wpos");
		place(&reader, LANE_SIZE, base);
		expect_fault(&reader, base + 8, ERX_LANE_WPOS_UNALIGNED,
		    "half-grain wpos");
		if (base > 0) {
			place(&reader, LANE_SIZE, base);
			expect_fault(&reader, base - 16, ERX_LANE_WPOS_BEHIND,
			    "wpos behind rpos");
		}
		place(&reader, LANE_SIZE, base);
		expect_fault(&reader, base + LANE_SIZE + 16,
		    ERX_LANE_WPOS_AHEAD, "wpos past the area");
		place(&reader, LANE_SIZE, base);
		expect_fault(&reader, top, ERX_LANE_WPOS_AHEAD, "wpos at the top");
		cases += 5;
	}

	/* wpos exactly the area past rpos is sound: a full lane. */
	place(&reader, LANE_SIZE, 0);
	put_header(0, LANE_SIZE - 16);
	CHECK(take_at(&reader, LANE_SIZE, BIG, &part) == ERX_LANE_TOOK &&
	    part.closed && part.copied == LANE_SIZE - 16, "a full lane",
	    part.copied, reader.fault);
	cases++;

	/* A wpos that falls back inside a granule already read is behind. */
	place(&reader, LANE_SIZE, 0);
	put_header(0, 40);
	CHECK(take_at(&reader, 64, 5, &part) == ERX_LANE_TOOK &&
	    reader.pos == 21, "partial read", reader.pos, 21);
	expect_fault(&reader, 16, ERX_LANE_WPOS_BEHIND, "wpos fell back");
	cases++;

	/* Record lengths at and past ERX_FRAME_MAX. */
	place(&reader, LANE_SIZE, 0);
	put_header(0, ERX_FRAME_MAX);
	CHECK(take_at(&reader, 16, BIG, &part) == ERX_LANE_TOOK &&
	    part.opened && part.len == ERX_FRAME_MAX && part.copied == 0,
	    "ERX_FRAME_MAX refused", reader.fault, 0);
	place(&reader, LANE_SIZE, 0);
	put_header(0, ERX_FRAME_MAX + 1);
	expect_fault(&reader, 16, ERX_LANE_RECORD_TOO_LONG, "len past frame max");
	place(&reader, LANE_SIZE, 0);
	put_header(0, UINT32_MAX);
	expect_fault(&reader, 16, ERX_LANE_RECORD_TOO_LONG, "len of all ones");
	cases += 3;

	/* A record that ends at the last position, and one that would not. */
	place(&reader, LANE_SIZE, top - 64);
	put_header(top - 64, 48);
	CHECK(take_at(&reader, top, BIG, &part) == ERX_LANE_TOOK &&
	    part.closed && reader.pos == top, "record to the top",
	    reader.pos, reader.fault);
	CHECK(take_at(&reader, top, BIG, &part) == ERX_LANE_EMPTY,
	    "nothing past the top", reader.pos, 0);
	place(&reader, LANE_SIZE, top - 64);
	put_header(top - 64, 64);
	expect_fault(&reader, top, ERX_LANE_RECORD_PAST_END,
	    "record past the top");
	place(&reader, LANE_SIZE, top);
	put_header(top, 0);
	CHECK(take_at(&reader, top, BIG, &part) == ERX_LANE_EMPTY,
	    "a lane at the top is empty", reader.pos, 0);
	cases += 4;

	/* need: crossed exactly at rpos, never at the old rpos, 0 or ~0. */
	static const struct { uint64_t need; bool ring; } needs[] = {
		{ 0, false }, { 16, false }, { 17, true }, { 48, true },
		{ 49, false }, { UINT64_MAX, false }
	};
	for (size_t i = 0; i < sizeof(needs) / sizeof(needs[0]); i++) {
		place(&reader, LANE_SIZE, 16);
		put_header(16, 16);
		erx_lane_hdr_need_store(header(), needs[i].need);
		CHECK(take_at(&reader, 48, BIG, &part) == ERX_LANE_TOOK &&
		    part.ring == needs[i].ring, "need crossing", needs[i].need,
		    part.ring);
		erx_lane_rpage_rpos_load(rpage(), &need);
		CHECK(need == 48, "rpos after the record", need, 48);
		cases++;
	}

	/* Armed takes publish wake = rpos + 1, also with pos inside a grain. */
	place(&reader, LANE_SIZE, 32);
	put_header(32, 40);
	CHECK(take_at(&reader, 80, 3, &part) == ERX_LANE_TOOK, "armed setup",
	    reader.fault, 0);
	CHECK(erx_lane_take_armed(&reader, NULL, 0, &part) == ERX_LANE_TOOK,
	    "armed take", reader.fault, 0);
	erx_lane_rpage_wake_load(rpage(), &wake);
	CHECK(wake == 48 + 1, "wake", wake, reader.pos);
	cases++;

	/*
	 * A stopped reader takes up to the wpos it copied and no further, and
	 * a record that copy cuts short stays open; a second stop is no load.
	 */
	place(&reader, LANE_SIZE, 0);
	put_header(0, 40);
	put_header(64, 8);
	erx_lane_hdr_wpos_store(header(), 64);
	CHECK(erx_lane_reader_stop(&reader), "stop", reader.fault, 0);
	CHECK(take_at(&reader, 96, BIG, &part) == ERX_LANE_TOOK &&
	    part.closed && part.len == 40, "take before the stop", part.len, 40);
	CHECK(take_at(&reader, 96, BIG, &part) == ERX_LANE_EMPTY &&
	    reader.pos == 64, "take past the stop", reader.pos, 64);
	CHECK(erx_lane_reader_stop(&reader) && take_at(&reader, 96, BIG,
	    &part) == ERX_LANE_EMPTY, "second stop", reader.pos, 64);
	cases++;
	place(&reader, LANE_SIZE, 0);
	put_header(0, 40);
	erx_lane_hdr_wpos_store(header(), 32);
	CHECK(erx_lane_reader_stop(&reader), "stop in a record", reader.fault,
	    0);
	CHECK(take_at(&reader, 64, BIG, &part) == ERX_LANE_TOOK &&
	    part.copied == 16 && !part.closed, "cut record's part",
	    part.copied, 16);
	CHECK(take_at(&reader, 64, BIG, &part) == ERX_LANE_EMPTY &&
	    reader.phase == ERX_LANE_IN_BODY && reader.body_left == 24,
	    "cut record stays open", reader.body_left, 24);
	cases++;
	/* The stop's one load is checked as a take's is, and refuses for good. */
	place(&reader, LANE_SIZE, 0);
	erx_lane_hdr_wpos_store(header(), 8);
	CHECK(!erx_lane_reader_stop(&reader) &&
	    reader.fault == ERX_LANE_WPOS_UNALIGNED, "unaligned stop",
	    reader.fault, ERX_LANE_WPOS_UNALIGNED);
	CHECK(!erx_lane_reader_stop(&reader) && take_at(&reader, 0, BIG,
	    &part) == ERX_LANE_MALFORMED, "refused stop", reader.fault, 0);
	cases++;
	place(&reader, LANE_SIZE, 0);
	erx_lane_hdr_wpos_store(header(), LANE_SIZE + 16);
	CHECK(!erx_lane_reader_stop(&reader) &&
	    reader.fault == ERX_LANE_WPOS_AHEAD, "stop ahead", reader.fault,
	    ERX_LANE_WPOS_AHEAD);
	cases++;

	printf("limits: cases=%lu\n", cases);
	return (0);
}

/* ----------------------------------------------------------------- writer */

/*
 * The writer against an independent model.  A scenario puts records with
 * the real writer and takes them with the real reader, one party's steps
 * at a time in a fixed schedule, on one thread.  After every put the model
 * says what it must have written from the rpos it read and the reserve:
 * the header when it fits, then whole grains of body or the padded rest;
 * the driver checks the window it wrote byte for byte, that nothing
 * outside it changed, the need an armed put published, and every ring.  A
 * party that is waiting steps only once the other rang it; a schedule in
 * which both wait with records left is a lost wake.
 */

#define WRITER_MAX_BODY	12000

static unsigned char writer_body[WRITER_MAX_BODY];

typedef struct wcounts wcounts_t;
struct wcounts {
	unsigned long	 scenarios, puts, armed, short_puts, empty_puts;
	unsigned long	 header_only, closes, prod_parks, rings_prod;
	unsigned long	 rings_cons, cons_parks, wraps, reserve_held;
	unsigned long	 rearms;
};

static wcounts_t wcounts;

/* The body of record i, cut into three pieces at cut and twice cut. */
static void
writer_item(erx_lane_item_t *item, erx_lane_iov_t iov[3], uint64_t record,
    uint32_t len, uint32_t cut, uint64_t reserve)
{
	uint32_t a = cut < len ? cut : len;
	uint32_t b = 2 * cut < len ? 2 * cut : len;

	for (uint32_t o = 0; o < len; o++)
		writer_body[o] = body_byte(record, o);
	iov[0] = (erx_lane_iov_t){ writer_body, a };
	iov[1] = (erx_lane_iov_t){ writer_body + a, b - a };
	iov[2] = (erx_lane_iov_t){ writer_body + b, len - b };
	*item = (erx_lane_item_t){
		.iov = iov,
		.iovcnt = 3,
		.zero = 0x4000 + record,
		.reserve = reserve,
		.kind = (uint32_t)record + 1
	};
}

/* The byte the model expects at body offset o of record r's window. */
static unsigned char
writer_expect(uint64_t record, uint32_t len, uint64_t window)
{
	uint64_t zero = 0x4000 + record, kind = record + 1;

	if (window < 4)
		return ((unsigned char)(len >> (8 * window)));
	if (window < 8)
		return ((unsigned char)(kind >> (8 * (window - 4))));
	if (window < 16)
		return ((unsigned char)(zero >> (8 * (window - 8))));
	if (window - 16 < len)
		return (body_byte(record, window - 16));
	return (0);
}

static unsigned char
area_byte(uint64_t pos)
{
	return (peer_mem[ERX_LANE_SIDE_DATA + (pos & (LANE_SIZE - 1))]);
}

/*
 * One put, judged.  rec_at is where the record's header sits; the window
 * the put wrote must hold the model's bytes and nothing else may change.
 */
static erx_lane_put_status_t
writer_step(erx_lane_writer_t *w, const erx_lane_item_t *item,
    uint64_t record, uint64_t *rec_at, bool armed, bool *ring)
{
	static unsigned char before[LANE_SIZE];
	erx_lane_put_status_t st;
	erx_lane_put_t put;
	uint64_t free, need, pos0, rpos, unread, want_n, wake, wpos;
	uint64_t reserve = item->reserve, res = grain_up(reserve);
	uint64_t left0 = w->body_left;
	uint32_t len = 0;
	bool open0 = w->phase == ERX_LANE_IN_BODY;

	for (size_t i = 0; i < item->iovcnt; i++)
		len += (uint32_t)item->iov[i].len;
	memcpy(before, peer_mem + ERX_LANE_SIDE_DATA, LANE_SIZE);
	erx_lane_rpage_rpos_load(rpage(), &rpos);
	erx_lane_rpage_wake_load(rpage(), &wake);
	pos0 = w->pos;
	st = armed ? erx_lane_put_armed(w, item, &put) :
	    erx_lane_put(w, item, &put);
	wcounts.puts++;
	CHECK(st == ERX_LANE_PUT_DONE || st == ERX_LANE_PUT_SHORT, "put status",
	    st, w->fault);
	erx_lane_hdr_wpos_load(header(), &wpos);
	CHECK(wpos == w->pos && w->pos % 16 == 0 && w->pos >= pos0, "wpos",
	    wpos, w->pos);
	CHECK(w->pos - rpos <= LANE_SIZE, "unread past the area", w->pos, rpos);
	if (w->pos > pos0 && reserve > 0) {
		CHECK(w->pos - rpos <= LANE_SIZE - res, "reserve taken", w->pos,
		    rpos);
		wcounts.reserve_held++;
	}

	/* The model, for a plain put; an armed one only adds rounds of it. */
	unread = pos0 - rpos;
	free = LANE_SIZE - unread > res ? LANE_SIZE - unread - res : 0;
	if (!armed) {
		want_n = 0;
		if (open0) {
			want_n = grain_up(left0) < free ? grain_up(left0) : free;
		} else if (free >= 16) {
			want_n = 16 + (grain_up(len) < free - 16 ?
			    grain_up(len) : free - 16);
		}
		CHECK(w->pos - pos0 == want_n, "put length", w->pos - pos0,
		    want_n);
	} else if (put.written > 0 || put.opened) {
		wcounts.armed++;
	}
	CHECK(put.opened == (!open0 && w->pos > pos0), "opened", put.opened,
	    open0);
	CHECK((w->pos > pos0) == (put.opened || put.written > 0), "progress",
	    w->pos - pos0, put.written);
	CHECK(put.offset == (open0 ? len - left0 : 0), "offset", put.offset,
	    len - left0);
	CHECK(put.closed == (st == ERX_LANE_PUT_DONE), "closed", put.closed, st);
	CHECK((w->phase == ERX_LANE_IN_BODY) == (!put.closed && (open0 ||
	    put.opened)), "phase", w->phase, put.closed);
	CHECK(put.offset + put.written <= len, "written", put.written, len);

	/* The window holds the model's bytes; the rest of the area is as it was. */
	for (uint64_t p = pos0; p < w->pos; p++)
		before[p & (LANE_SIZE - 1)] = writer_expect(record, len,
		    p - *rec_at);
	if (memcmp(before, peer_mem + ERX_LANE_SIDE_DATA, LANE_SIZE) != 0)
		for (uint64_t p = pos0; p < pos0 + LANE_SIZE; p++)
			CHECK(area_byte(p) == before[p & (LANE_SIZE - 1)],
			    "area byte", p, pos0);
	if ((pos0 & (LANE_SIZE - 1)) > (w->pos & (LANE_SIZE - 1)) &&
	    w->pos > pos0)
		wcounts.wraps++;

	/* Ring when the store crossed wake: wake was not moved meanwhile. */
	CHECK(put.ring == (pos0 < wake && wake <= w->pos), "put ring", wake,
	    w->pos);
	if (put.opened && put.written == 0 && !put.closed)
		wcounts.header_only++;
	if (put.closed)
		wcounts.closes++;
	if (st == ERX_LANE_PUT_SHORT) {
		wcounts.short_puts++;
		if (w->pos == pos0)
			wcounts.empty_puts++;
	}
	if (armed && st == ERX_LANE_PUT_SHORT) {
		uint64_t rest, wanted;

		erx_lane_hdr_need_load(header(), &need);
		rest = w->phase == ERX_LANE_IN_BODY ? grain_up(w->body_left) :
		    16 + grain_up(len);
		/*
		 * At need the room past the reserve first holds what the put
		 * waits for: the rest, a quarter, or all past the reserve.
		 */
		wanted = rest < LANE_SIZE / 4 ? rest : LANE_SIZE / 4;
		if (wanted > LANE_SIZE - res)
			wanted = LANE_SIZE - res;
		CHECK(need <= w->pos && LANE_SIZE - (w->pos - need) >= res +
		    wanted, "need gives too little room", need, w->pos);
		CHECK(need < 16 || LANE_SIZE - (w->pos - need) - 16 < res +
		    wanted, "need waits for too much room", need, w->pos);
		/* A short armed put is waiting: the room is not there yet. */
		CHECK(w->rpos < need, "armed put not waiting", w->rpos, need);
		if (w->pos > pos0 && (put.written > 0 || put.opened))
			wcounts.rearms++;
	}
	if (put.closed)
		*rec_at = w->pos;
	*ring = put.ring;
	return (st);
}

static void
writer_scenario(const uint32_t *lens, unsigned n, uint64_t base,
    uint64_t reserve, size_t max, uint32_t cut, unsigned sched)
{
	static unsigned char buf[WRITER_MAX_BODY];
	erx_lane_reader_t reader;
	erx_lane_writer_t w;
	erx_lane_iov_t iov[3];
	erx_lane_item_t item;
	erx_lane_part_t part;
	erx_lane_status_t st;
	erx_lane_put_status_t pst;
	uint64_t rec_at = base, seen = 0;
	unsigned put_rec = 0, take_rec = 0;
	bool cons_parked = false, prod_parked = false, armed_next = false;
	unsigned prod_steps = 1 + sched % 2, cons_steps = 1 + sched / 2;

	place(&reader, LANE_SIZE, base);
	CHECK(erx_lane_writer_init(&w, peer_mem, own_mem, LANE_SIZE), "winit",
	    0, 0);
	w.pos = w.rpos = base;
	wcounts.scenarios++;
	while (take_rec < n) {
		bool moved = false, ring;

		for (unsigned k = 0; k < prod_steps && put_rec < n &&
		    !prod_parked; k++) {
			writer_item(&item, iov, put_rec, lens[put_rec], cut,
			    reserve);
			pst = writer_step(&w, &item, put_rec, &rec_at, armed_next,
			    &ring);
			moved = true;
			if (ring) {
				CHECK(cons_parked, "rang an awake consumer",
				    w.pos, reader.pos);
				cons_parked = false;
				wcounts.rings_cons++;
			}
			if (armed_next && pst == ERX_LANE_PUT_SHORT) {
				prod_parked = true;
				wcounts.prod_parks++;
			}
			/* A plain put that falls short is followed by an armed one;
			 * an armed put that falls short parks the producer. */
			armed_next = pst == ERX_LANE_PUT_SHORT && !armed_next;
			if (pst == ERX_LANE_PUT_DONE) {
				put_rec++;
				armed_next = false;
			}
		}
		for (unsigned k = 0; k < cons_steps && take_rec < n &&
		    !cons_parked; k++) {
			bool armed = k + 1 == cons_steps;

			st = armed ? erx_lane_take_armed(&reader, buf, max, &part) :
			    erx_lane_take(&reader, buf, max, &part);
			moved = true;
			CHECK(st == ERX_LANE_TOOK || st == ERX_LANE_EMPTY,
			    "take status", st, reader.fault);
			/* An empty plain take goes on to the armed one, which parks. */
			if (st == ERX_LANE_EMPTY && !armed)
				continue;
			if (st == ERX_LANE_EMPTY) {
				cons_parked = true;
				wcounts.cons_parks++;
				break;
			}
			if (part.ring) {
				wcounts.rings_prod++;
				prod_parked = false;
			}
			if (part.opened)
				CHECK(part.len == lens[take_rec] &&
				    part.kind == take_rec + 1 &&
				    part.zero == 0x4000 + take_rec, "header",
				    part.len, take_rec);
			for (size_t b = 0; b < part.copied; b++)
				CHECK(buf[b] == body_byte(take_rec,
				    part.offset + b), "trip byte", take_rec,
				    part.offset + b);
			CHECK(part.offset == seen, "trip offset", part.offset,
			    seen);
			seen += part.copied;
			if (part.closed) {
				CHECK(seen == lens[take_rec], "trip len", seen,
				    take_rec);
				seen = 0;
				take_rec++;
			}
		}
		CHECK(moved || take_rec == n, "lost wake", put_rec, take_rec);
	}
	CHECK(w.phase == ERX_LANE_BETWEEN && reader.phase == ERX_LANE_BETWEEN,
	    "ends between records", w.phase, reader.phase);
}

static int
writer_trips(void)
{
	static const uint32_t set0[] = { 0 }, set1[] = { 1, 15, 16, 17 };
	static const uint32_t set2[] = { 100, 0, 33 }, set3[] = { 4096 };
	static const uint32_t set4[] = { 5000, 7 }, set5[] = { 12000 };
	static const struct { const uint32_t *lens; unsigned n; } sets[] = {
		{ set0, 1 }, { set1, 4 }, { set2, 3 }, { set3, 1 }, { set4, 2 },
		{ set5, 1 }
	};
	static const uint64_t reserves[] = { 0, 1000, 3072 };
	static const size_t wmaxes[] = { 1, 5, 16, BIG };
	static const uint32_t cuts_at[] = { 0, 7 };
	const uint64_t bases[] = { 0, 3 * LANE_SIZE + 2032,
	    (UINT64_MAX - (UINT64_C(1) << 20)) & ~UINT64_C(15) };

	for (size_t s = 0; s < sizeof(sets) / sizeof(sets[0]); s++)
	for (size_t b = 0; b < sizeof(bases) / sizeof(bases[0]); b++)
	for (size_t r = 0; r < sizeof(reserves) / sizeof(reserves[0]); r++)
	for (size_t m = 0; m < sizeof(wmaxes) / sizeof(wmaxes[0]); m++)
	for (size_t c = 0; c < sizeof(cuts_at) / sizeof(cuts_at[0]); c++)
	for (unsigned sched = 0; sched < 4; sched++)
		writer_scenario(sets[s].lens, sets[s].n, bases[b], reserves[r],
		    wmaxes[m], cuts_at[c], sched);
	printf("writer: scenarios=%lu puts=%lu armed=%lu short=%lu empty=%lu "
	    "header_only=%lu closes=%lu prod_parks=%lu rings_prod=%lu "
	    "rings_cons=%lu cons_parks=%lu wraps=%lu reserve_held=%lu "
	    "rearms=%lu\n", wcounts.scenarios, wcounts.puts, wcounts.armed,
	    wcounts.short_puts, wcounts.empty_puts, wcounts.header_only,
	    wcounts.closes, wcounts.prod_parks, wcounts.rings_prod,
	    wcounts.rings_cons, wcounts.cons_parks, wcounts.wraps,
	    wcounts.reserve_held, wcounts.rearms);
	return (0);
}

/* ---------------------------------------------------------------- wlimits */

static unsigned char wl_body[2 * LANE_SIZE];

/* A writer over an empty lane at base, with rpos published as base. */
static void
wplace(erx_lane_writer_t *w, uint64_t base)
{
	memset(peer_mem, 0, sizeof(peer_mem));
	memset(own_mem, 0, sizeof(own_mem));
	CHECK(erx_lane_writer_init(w, peer_mem, own_mem, LANE_SIZE), "winit",
	    0, 0);
	w->pos = w->rpos = base;
	erx_lane_hdr_wpos_store(header(), base);
	erx_lane_rpage_rpos_store(rpage(), base);
}

static erx_lane_put_status_t
wput(erx_lane_writer_t *w, size_t len, uint64_t reserve, bool armed,
    erx_lane_put_t *put)
{
	erx_lane_iov_t iov = { wl_body, len };
	erx_lane_item_t item = { .iov = &iov, .iovcnt = 1, .reserve = reserve };

	return (armed ? erx_lane_put_armed(w, &item, put) :
	    erx_lane_put(w, &item, put));
}

/* An rpos that fails a check refuses the lane, writing nothing, for good. */
static void
expect_wfault(erx_lane_writer_t *w, uint64_t rpos, erx_lane_fault_t fault)
{
	erx_lane_put_t put;
	uint64_t pos = w->pos, wpos;

	erx_lane_rpage_rpos_store(rpage(), rpos);
	CHECK(wput(w, 16, 0, false, &put) == ERX_LANE_PUT_MALFORMED &&
	    w->fault == fault && w->phase == ERX_LANE_REFUSED, "wfault",
	    w->fault, fault);
	erx_lane_rpage_rpos_store(rpage(), pos);
	CHECK(wput(w, 16, 0, false, &put) == ERX_LANE_PUT_MALFORMED &&
	    wput(w, 16, 0, true, &put) == ERX_LANE_PUT_MALFORMED,
	    "refusal is final", w->fault, 0);
	erx_lane_hdr_wpos_load(header(), &wpos);
	CHECK(wpos == pos && w->pos == pos && put.written == 0, "refused wrote",
	    wpos, pos);
}

static int
wlimits(void)
{
	static _Alignas(PAGE) unsigned char spare[PAGE];
	erx_lane_writer_t w;
	erx_lane_put_t put;
	erx_lane_iov_t iov[2];
	erx_lane_item_t item = { .iov = iov, .iovcnt = 2 };
	uint64_t need, top, wpos;
	unsigned long cases = 0;

	/* init refuses what erx_lane_reader_init refuses. */
	CHECK(!erx_lane_writer_init(NULL, peer_mem, own_mem, LANE_SIZE) &&
	    !erx_lane_writer_init(&w, NULL, own_mem, LANE_SIZE) &&
	    !erx_lane_writer_init(&w, peer_mem, NULL, LANE_SIZE) &&
	    !erx_lane_writer_init(&w, peer_mem + 8, own_mem, LANE_SIZE) &&
	    !erx_lane_writer_init(&w, peer_mem, spare + 16, LANE_SIZE) &&
	    !erx_lane_writer_init(&w, peer_mem, own_mem, LANE_SIZE + 16) &&
	    !erx_lane_writer_init(&w, peer_mem, own_mem, ERX_LANE_MIN / 2) &&
	    !erx_lane_writer_init(&w, peer_mem, own_mem, 2 * ERX_LANE_MAX),
	    "winit refusals", 0, 0);
	cases += 8;

	/* Each rpos check, at its bound. */
	wplace(&w, 4096);
	CHECK(wput(&w, 48, 0, false, &put) == ERX_LANE_PUT_DONE, "w64", 0, 0);
	erx_lane_rpage_rpos_store(rpage(), 4096 + 64);
	CHECK(wput(&w, 0, 0, false, &put) == ERX_LANE_PUT_DONE &&
	    w.rpos == 4096 + 64, "rpos == wpos", w.rpos, 0);
	cases++;
	expect_wfault(&w, 4096 + 81, ERX_LANE_RPOS_UNALIGNED);
	wplace(&w, 4096);
	CHECK(wput(&w, 48, 0, false, &put) == ERX_LANE_PUT_DONE, "w64", 0, 0);
	expect_wfault(&w, 4096 + 80, ERX_LANE_RPOS_AHEAD);
	wplace(&w, 4096);
	erx_lane_rpage_rpos_store(rpage(), 4096 + 16);
	expect_wfault(&w, 4096 + 16, ERX_LANE_RPOS_AHEAD);
	wplace(&w, 4096);
	CHECK(wput(&w, 48, 0, false, &put) == ERX_LANE_PUT_DONE, "w64", 0, 0);
	erx_lane_rpage_rpos_store(rpage(), 4096 + 32);
	CHECK(wput(&w, 0, 0, false, &put) == ERX_LANE_PUT_DONE, "w32", 0, 0);
	expect_wfault(&w, 4096 + 16, ERX_LANE_RPOS_BEHIND);
	cases += 4;

	/* Items the writer refuses, leaving everything as it was. */
	wplace(&w, 0);
	iov[0] = (erx_lane_iov_t){ wl_body, ERX_FRAME_MAX };
	iov[1] = (erx_lane_iov_t){ wl_body, 1 };
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_REFUSED &&
	    w.pos == 0 && w.phase == ERX_LANE_BETWEEN, "past FRAME_MAX", 0, 0);
	iov[0] = (erx_lane_iov_t){ wl_body, SIZE_MAX };
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_REFUSED,
	    "pieces that overflow", 0, 0);
	iov[0] = (erx_lane_iov_t){ NULL, 1 };
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_REFUSED,
	    "a piece without a base", 0, 0);
	item.iov = NULL;
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_REFUSED,
	    "pieces without an array", 0, 0);
	CHECK(wput(&w, 0, LANE_SIZE - 15, false, &put) == ERX_LANE_PUT_REFUSED &&
	    wput(&w, 0, LANE_SIZE - 15, true, &put) == ERX_LANE_PUT_REFUSED,
	    "a reserve that leaves no header", 0, 0);
	erx_lane_hdr_wpos_load(header(), &wpos);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(wpos == 0 && need == 0 && w.pos == 0, "refusals wrote", wpos,
	    need);
	cases += 5;

	/* A piece of length 0 needs no base; a reserve of size - 16 holds a header. */
	item.iov = iov;
	iov[0] = (erx_lane_iov_t){ NULL, 0 };
	iov[1] = (erx_lane_iov_t){ wl_body, 0 };
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_DONE &&
	    w.pos == 16, "empty pieces", w.pos, 0);
	CHECK(wput(&w, 0, LANE_SIZE - 32, false, &put) == ERX_LANE_PUT_DONE &&
	    w.pos == 32, "reserve of size - 32", w.pos, 0);
	CHECK(wput(&w, 0, LANE_SIZE - 16, false, &put) == ERX_LANE_PUT_SHORT &&
	    w.pos == 32, "reserve of size - 16, 32 unread", w.pos, 0);
	erx_lane_rpage_rpos_store(rpage(), 32);
	CHECK(wput(&w, 5, LANE_SIZE - 16, false, &put) ==
	    ERX_LANE_PUT_SHORT && put.opened && put.written == 0 &&
	    w.pos == 48, "reserve of size - 16 holds a header", w.pos, 0);
	cases += 4;

	/* An open record takes only its own body, up to ERX_FRAME_MAX. */
	wplace(&w, 0);
	iov[0] = (erx_lane_iov_t){ wl_body, ERX_FRAME_MAX - 1 };
	iov[1] = (erx_lane_iov_t){ wl_body, 1 };
	CHECK(erx_lane_put(&w, &item, &put) == ERX_LANE_PUT_SHORT &&
	    put.opened && put.written == LANE_SIZE - 16, "ERX_FRAME_MAX opens",
	    put.written, 0);
	CHECK(wput(&w, 100, 0, false, &put) == ERX_LANE_PUT_REFUSED &&
	    w.phase == ERX_LANE_IN_BODY, "another body", w.phase, 0);
	cases += 2;

	/* No record ends past the last position; a header alone may. */
	top = UINT64_MAX - 31;
	wplace(&w, top);
	CHECK(wput(&w, 1, 0, false, &put) == ERX_LANE_PUT_REFUSED &&
	    wput(&w, 0, 0, false, &put) == ERX_LANE_PUT_DONE &&
	    w.pos == top + 16, "the last position", w.pos, top);
	cases++;

	/* need: the rest when less than a quarter, else a quarter; capped. */
	wplace(&w, 8192);
	CHECK(wput(&w, LANE_SIZE - 16, 0, false, &put) == ERX_LANE_PUT_DONE,
	    "fill", 0, 0);
	CHECK(wput(&w, 100, 0, true, &put) == ERX_LANE_PUT_SHORT &&
	    put.written == 0 && !put.opened, "armed full", 0, 0);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(need == 8192 + 16 + 112, "need of a short record", need, 0);
	CHECK(wput(&w, 3000, 0, true, &put) == ERX_LANE_PUT_SHORT, "armed", 0, 0);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(need == 8192 + LANE_SIZE / 4, "need of a quarter", need, 0);
	CHECK(wput(&w, 3000, LANE_SIZE - 16, true, &put) == ERX_LANE_PUT_SHORT,
	    "armed", 0, 0);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(need == 8192 + LANE_SIZE, "need capped at the area", need, 0);
	CHECK(wput(&w, 100, 1000, true, &put) == ERX_LANE_PUT_SHORT, "armed",
	    0, 0);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(need == 8192 + 1008 + 128, "need past the reserve", need, 0);
	cases += 4;

	/* An armed put with room for part re-arms from where it stopped. */
	erx_lane_rpage_rpos_store(rpage(), 8192 + 64);
	CHECK(wput(&w, 200, 0, true, &put) == ERX_LANE_PUT_SHORT &&
	    put.opened && put.written == 48, "armed part", put.written, 0);
	erx_lane_hdr_need_load(header(), &need);
	CHECK(need == 8192 + 64 + 160, "need re-armed", need, 0);
	cases++;

	printf("wlimits: cases=%lu\n", cases);
	return (0);
}

/* ------------------------------------------------------------------- race */

/* The second phase's bound, in multiples of the first phase's takes. */
#define RACE_MUTATION_FACTOR	64UL

static atomic_bool race_stop;
static atomic_bool race_writer_stop;
static atomic_bool race_mutate;
static uint64_t race_seed;

static uint64_t
xorshift(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static void *
race_producer(void *arg ERX_UNUSED)
{
	static unsigned char body[300];
	erx_lane_writer_t w;
	erx_lane_iov_t iov[2];
	erx_lane_item_t item = { .iov = iov, .iovcnt = 2, .kind = 1 };
	erx_lane_put_t put;
	erx_lane_put_status_t st;
	uint64_t len, record = 0, state = race_seed;

	CHECK(erx_lane_writer_init(&w, peer_mem, own_mem, LANE_SIZE),
	    "race winit", 0, 0);
	while (!atomic_load(&race_writer_stop)) {
		len = xorshift(&state) % 300;
		for (uint64_t o = 0; o < len; o++)
			body[o] = body_byte(record, o);
		iov[0] = (erx_lane_iov_t){ body, len / 3 };
		iov[1] = (erx_lane_iov_t){ body + len / 3, len - len / 3 };
		do {
			/* No bell here: a waiting writer yields and looks again. */
			st = erx_lane_put(&w, &item, &put);
			if (st == ERX_LANE_PUT_SHORT)
				st = erx_lane_put_armed(&w, &item, &put);
			if (st == ERX_LANE_PUT_SHORT)
				sched_yield();
			if (atomic_load(&race_writer_stop))
				return (NULL);
		} while (st == ERX_LANE_PUT_SHORT);
		CHECK(st == ERX_LANE_PUT_DONE, "race put", st, w.fault);
		record++;
	}
	return (NULL);
}

static void *
race_mutator(void *arg ERX_UNUSED)
{
	uint64_t state = race_seed * 7 + 1, slot;

	while (!atomic_load(&race_stop)) {
		if (!atomic_load(&race_mutate)) {
			sched_yield();
			continue;
		}
		slot = xorshift(&state) % ((ERX_LANE_SIDE_DATA + LANE_SIZE) / 8);
		if (slot >= 2 && slot < ERX_LANE_SIDE_DATA / 8)
			slot %= 2;
		store_u64(&((_Atomic uint64_t *)peer_mem)[slot],
		    xorshift(&state));
	}
	return (NULL);
}

static int
race(uint64_t seed, unsigned long takes)
{
	static unsigned char buf[512];
	pthread_t producer, mutator;
	erx_lane_reader_t reader;
	erx_lane_part_t part;
	erx_lane_status_t st;
	uint64_t last_rpos = 0, record = 0, rpos, seen, state = seed | 1;
	unsigned long malformed = 0, records = 0, phase_takes = 0;

	CHECK(takes <= ULONG_MAX / (RACE_MUTATION_FACTOR + 1), "takes", takes, 0);
	race_seed = seed | 1;
	place(&reader, LANE_SIZE, 0);
	CHECK(pthread_create(&producer, NULL, race_producer, NULL) == 0,
	    "thread", 0, 0);
	CHECK(pthread_create(&mutator, NULL, race_mutator, NULL) == 0,
	    "thread", 0, 0);
	/*
	 * The first phase is takes long. The second ends at the refusal, which
	 * comes once the mutator has run; on a loaded host it may not get a CPU
	 * for many takes, so the bound is generous and only stops a run whose
	 * refusal never comes.
	 */
	seen = 0;
	for (unsigned long i = 0; i < takes * (RACE_MUTATION_FACTOR + 1); i++) {
		size_t max = 1 + xorshift(&state) % sizeof(buf);

		if (i == takes) {
			/* The mutator stands for a hostile producer: the writer stops. */
			atomic_store(&race_writer_stop, true);
			pthread_join(producer, NULL);
			atomic_store(&race_mutate, true);
		}
		st = erx_lane_take(&reader, buf, max, &part);
		phase_takes++;
		CHECK(st == ERX_LANE_TOOK || st == ERX_LANE_EMPTY ||
		    st == ERX_LANE_MALFORMED, "status", st, i);
		erx_lane_rpage_rpos_load(rpage(), &rpos);
		CHECK(rpos >= last_rpos && rpos % 16 == 0 &&
		    rpos == (reader.pos & ~UINT64_C(15)), "rpos", rpos,
		    last_rpos);
		last_rpos = rpos;
		if (st == ERX_LANE_MALFORMED) {
			CHECK(i >= takes, "refused without mutation",
			    reader.fault, i);
			malformed++;
			break;
		}
		if (st != ERX_LANE_TOOK)
			continue;
		/* A copy is whole: its bytes add up to the header it read. */
		CHECK(part.copied <= max && part.offset == seen &&
		    part.offset + part.copied <= part.len, "part", part.offset,
		    seen);
		if (i < takes)
			for (size_t b = 0; b < part.copied; b++)
				CHECK(buf[b] == body_byte(record,
				    part.offset + b), "race byte", record, b);
		seen += part.copied;
		if (part.closed) {
			CHECK(seen == part.len, "whole record", seen, part.len);
			seen = 0;
			record++;
			records++;
		}
	}
	atomic_store(&race_stop, true);
	atomic_store(&race_writer_stop, true);
	if (!atomic_load(&race_mutate))
		pthread_join(producer, NULL);
	pthread_join(mutator, NULL);
	CHECK(records > 0, "no record crossed the race", records, 0);
	printf("race: takes=%lu records=%lu malformed=%lu\n", phase_takes,
	    records, malformed);
	return (0);
}

/* ------------------------------------------------------------------ wrace */

static atomic_bool wrace_garbage;

/*
 * A hostile consumer: it publishes plausible positions, rpos forward
 * within what was published and any wake, then garbage once told to.
 */
static void *
wrace_consumer(void *arg ERX_UNUSED)
{
	uint64_t rpos = 0, state = race_seed * 3 + 1, wpos;

	while (!atomic_load(&race_stop)) {
		if (atomic_load(&wrace_garbage)) {
			rpos = xorshift(&state);
		} else {
			erx_lane_hdr_wpos_load(header(), &wpos);
			if (wpos > rpos)
				rpos += xorshift(&state) %
				    ((wpos - rpos) / 16 + 1) * 16;
		}
		erx_lane_rpage_rpos_store(rpage(), rpos);
		erx_lane_rpage_wake_store(rpage(), xorshift(&state));
	}
	return (NULL);
}

/*
 * The writer against the hostile consumer, on two threads, for TSan:
 * while the consumer is plausible every put writes or waits, and once it
 * publishes garbage the writer refuses the lane, with wpos never past the
 * room a sound rpos gave.
 */
static int
wrace(uint64_t seed, unsigned long puts)
{
	erx_lane_reader_t reader;
	erx_lane_writer_t w;
	erx_lane_iov_t iov;
	erx_lane_item_t item = { .iov = &iov, .iovcnt = 1, .kind = 1 };
	erx_lane_put_t put;
	erx_lane_put_status_t st = ERX_LANE_PUT_DONE;
	pthread_t consumer;
	uint64_t state = seed | 1, wpos;
	unsigned long malformed = 0, records = 0, done = 0;

	CHECK(puts <= ULONG_MAX / (RACE_MUTATION_FACTOR + 1), "puts", puts, 0);
	race_seed = seed | 1;
	place(&reader, LANE_SIZE, 0);
	CHECK(erx_lane_writer_init(&w, peer_mem, own_mem, LANE_SIZE),
	    "wrace winit", 0, 0);
	CHECK(pthread_create(&consumer, NULL, wrace_consumer, NULL) == 0,
	    "thread", 0, 0);
	for (unsigned long i = 0; i < puts * (RACE_MUTATION_FACTOR + 1); i++) {
		if (i == puts)
			atomic_store(&wrace_garbage, true);
		if (st != ERX_LANE_PUT_SHORT)
			iov = (erx_lane_iov_t){ wl_body,
			    xorshift(&state) % sizeof(wl_body) };
		st = (i & 1) != 0 ? erx_lane_put_armed(&w, &item, &put) :
		    erx_lane_put(&w, &item, &put);
		done++;
		erx_lane_hdr_wpos_load(header(), &wpos);
		CHECK(wpos == w.pos && w.pos - w.rpos <= LANE_SIZE, "wrace wpos",
		    wpos, w.rpos);
		if (st == ERX_LANE_PUT_MALFORMED) {
			CHECK(i >= puts, "refused a plausible rpos", w.fault, i);
			malformed++;
			break;
		}
		CHECK(st == ERX_LANE_PUT_DONE || st == ERX_LANE_PUT_SHORT,
		    "wrace status", st, i);
		if (st == ERX_LANE_PUT_DONE)
			records++;
	}
	atomic_store(&race_stop, true);
	pthread_join(consumer, NULL);
	CHECK(records > 0, "no record crossed the race", records, 0);
	printf("wrace: puts=%lu records=%lu malformed=%lu\n", done, records,
	    malformed);
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "explore") == 0)
		return (explore());
	if (argc == 2 && strcmp(argv[1], "cuts") == 0)
		return (cuts());
	if (argc == 2 && strcmp(argv[1], "limits") == 0)
		return (limits());
	if (argc == 2 && strcmp(argv[1], "writer") == 0)
		return (writer_trips());
	if (argc == 2 && strcmp(argv[1], "wlimits") == 0)
		return (wlimits());
	if (argc == 4 && strcmp(argv[1], "race") == 0)
		return (race(strtoull(argv[2], NULL, 10),
		    strtoul(argv[3], NULL, 10)));
	if (argc == 4 && strcmp(argv[1], "wrace") == 0)
		return (wrace(strtoull(argv[2], NULL, 10),
		    strtoul(argv[3], NULL, 10)));
	fprintf(stderr, "usage: lane_driver explore|cuts|limits|writer|wlimits|"
	    "race SEED N|wrace SEED N\n");
	return (2);
}
