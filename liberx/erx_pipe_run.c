/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects of the pipe core's steps on an end's mapped pages
 * (include/erx/pipe_run.h): the shell around erx_pipe_wstep and
 * erx_pipe_rstep that a program's pipe ends and the session's pipe NIF
 * share, so both read and write a lane the same way.
 */

#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#include "erx/pipe_run.h"
#include "erx/shm.h"

/* A record's header: its payload length, its kind and its stamp. */
#define RUN_REC_HEADER	16u
/* The pipe's lock page and a lane's reader page are one page each. */
#define RUN_PAGE	4096u

_Static_assert(offsetof(erx_pipe_lock_t, cur_off) ==
    offsetof(erx_pipe_lock_t, cur) + 4 &&
    offsetof(erx_pipe_lock_t, cur_pos) == offsetof(erx_pipe_lock_t, cur) + 8,
    "the current record is one 16-byte copy");

static erx_pipe_act_t
run_fail(void)
{
	erx_pipe_act_t act;

	memset(&act, 0, sizeof(act));
	act.op = ERX_PIPE_OP_DONE;
	act.result = -EIO;
	return (act);
}

/* One copy of len bytes at offset off of a page another party writes. */
static void
run_copy_field(const void *page, size_t off, void *dst, size_t len)
{
	erx_shm_copy((const _Atomic uint64_t *)page, RUN_PAGE, off, dst, len);
}

static uint64_t
run_copy_word(const void *page, size_t off)
{
	uint64_t value;

	run_copy_field(page, off, &value, sizeof(value));
	return (value);
}

/* Stores n bytes at position pos of a data area of size bytes, wrapping. */
static void
run_area_put(unsigned char *area, uint64_t size, uint64_t pos,
    const unsigned char *src, uint64_t n)
{
	uint64_t first, offset;

	offset = pos & (size - 1);
	first = size - offset < n ? size - offset : n;
	memcpy(area + offset, src, first);
	memcpy(area, src + first, n - first);
}

/* Whether [off, off + n) lies within a buffer of len bytes. */
static bool
run_within(uint64_t off, uint64_t n, uint64_t len)
{
	return (off <= len && n <= len - off);
}

/* A data record of n bytes from buf + off, stamped value, at pos. */
static bool
run_write_rec(const erx_pipe_wstate_t *w, const erx_pipe_wmap_t *map,
    const unsigned char *buf, const erx_pipe_act_t *a)
{
	unsigned char header[RUN_REC_HEADER];
	uint32_t kind, len;

	if (a->n == 0 || a->n > w->chunk || a->pos % RUN_REC_HEADER != 0 ||
	    !run_within(a->off, a->n, w->len) ||
	    erx_ring_span((uint32_t)a->n) > w->size)
		return (false);
	len = (uint32_t)a->n;
	kind = ERX_REC_DATA;
	memcpy(header, &len, 4);
	memcpy(header + 4, &kind, 4);
	memcpy(header + 8, &a->value, 8);
	run_area_put(map->area, w->size, a->pos, header, sizeof(header));
	run_area_put(map->area, w->size, a->pos + RUN_REC_HEADER, buf + a->off,
	    a->n);
	return (true);
}

/* Performs one write end action other than WAIT and DONE; false on a bad one. */
static bool
run_wperform(const erx_pipe_wstate_t *w, const erx_pipe_wmap_t *map,
    const unsigned char *buf, const erx_pipe_fx_t *fx,
    const erx_pipe_act_t *a, erx_pipe_in_t *in)
{
	uint64_t bits;

	switch (a->op) {
	case ERX_PIPE_OP_CLOCK:
		in->value = fx->clock(fx->ctx);
		return (true);
	case ERX_PIPE_OP_LOAD_RPOS:
		return (erx_pipe_rpage_rpos_load(map->rpage, &in->value));
	case ERX_PIPE_OP_COPY_WAKE:
		in->value = run_copy_word(map->rpage,
		    offsetof(erx_pipe_rpage_t, wake));
		return (true);
	case ERX_PIPE_OP_COPY_SLEEPERS:
		in->value = run_copy_word(map->rpage,
		    offsetof(erx_pipe_rpage_t, sleepers));
		return (true);
	case ERX_PIPE_OP_WRITE_REC:
		return (run_write_rec(w, map, buf, a));
	case ERX_PIPE_OP_STORE_WPOS:
		return (erx_lane_hdr_wpos_store(map->hdr, a->value));
	case ERX_PIPE_OP_STORE_NEED:
		return (erx_lane_hdr_need_store(map->hdr, a->value));
	case ERX_PIPE_OP_FENCE:
		atomic_thread_fence(memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_RING_READERS:
		/* Bounded by the 64 bits of the mask, not by the copy. */
		for (bits = a->value; bits != 0; bits &= bits - 1)
			fx->ring_reader(fx->ctx,
			    (uint32_t)__builtin_ctzll(bits));
		return (true);
	default:
		return (false);
	}
}

erx_pipe_act_t
erx_pipe_wrun(erx_pipe_wstate_t *w, const erx_pipe_wmap_t *map,
    const void *buf, const erx_pipe_fx_t *fx)
{
	erx_pipe_act_t act;
	erx_pipe_in_t in;

	memset(&in, 0, sizeof(in));
	for (;;) {
		act = erx_pipe_wstep(w, &in);
		if (act.op == ERX_PIPE_OP_DONE || act.op == ERX_PIPE_OP_WAIT)
			return (act);
		memset(&in, 0, sizeof(in));
		if (!run_wperform(w, map, buf, fx, &act, &in))
			return (run_fail());
	}
}

/* The mapping of the lane an action names, if the end holds it mapped. */
static const erx_pipe_rmap_t *
run_lane(const erx_pipe_rstate_t *r, const erx_pipe_rmap_t *maps,
    const erx_pipe_act_t *a)
{
	const erx_pipe_rmap_t *m;

	if (a->lane >= r->nlanes)
		return (NULL);
	m = &maps[a->lane];
	if (m->hdr == NULL || m->area == NULL || m->rpage == NULL)
		return (NULL);
	return (m);
}

/* The header of the record at a lane's position: len, kind and stamp. */
static bool
run_copy_rec(const erx_pipe_rstate_t *r, const erx_pipe_rmap_t *m,
    const erx_pipe_act_t *a, erx_pipe_in_t *in)
{
	unsigned char header[RUN_REC_HEADER];
	uint64_t size;

	size = r->lanes[a->lane].size;
	if (a->pos % RUN_REC_HEADER != 0 || size < RUN_REC_HEADER)
		return (false);
	erx_shm_copy((const _Atomic uint64_t *)m->area, size, a->pos, header,
	    sizeof(header));
	memcpy(&in->len, header, 4);
	memcpy(&in->kind, header + 4, 4);
	memcpy(&in->stamp, header + 8, 8);
	return (true);
}

/* The lock page's current record, cur, cur_off and cur_pos, in one copy. */
static void
run_copy_cur(const erx_pipe_lock_t *lock, erx_pipe_in_t *in)
{
	unsigned char cur[16];

	run_copy_field(lock, offsetof(erx_pipe_lock_t, cur), cur, sizeof(cur));
	memcpy(&in->cur, cur, 4);
	memcpy(&in->cur_off, cur + 4, 4);
	memcpy(&in->cur_pos, cur + 8, 8);
}

static bool
run_store_cur(const erx_pipe_rstate_t *r, erx_pipe_lock_t *lock,
    const erx_pipe_act_t *a)
{
	uint32_t cur;

	if (a->lane == ERX_PIPE_LANE_NONE)
		cur = ERX_PIPE_NONE;
	else if (a->lane < r->nlanes)
		cur = r->lanes[a->lane].wend;
	else
		return (false);
	if (a->n > UINT32_MAX)
		return (false);
	return (erx_pipe_lock_cur_store(lock, cur) &&
	    erx_pipe_lock_cur_off_store(lock, (uint32_t)a->n) &&
	    erx_pipe_lock_cur_pos_store(lock, a->pos));
}

/* A read end action on one of its lanes; false on a bad one. */
static bool
run_rlane(const erx_pipe_rstate_t *r, const erx_pipe_rmap_t *maps,
    unsigned char *buf, const erx_pipe_fx_t *fx, const erx_pipe_act_t *a,
    erx_pipe_in_t *in)
{
	const erx_pipe_rmap_t *m;
	uint64_t bit;

	if ((m = run_lane(r, maps, a)) == NULL)
		return (false);
	bit = UINT64_C(1) << r->rix;
	switch (a->op) {
	case ERX_PIPE_OP_LOAD_RPOS:
		return (erx_pipe_rpage_rpos_load(m->rpage, &in->value));
	case ERX_PIPE_OP_LOAD_WPOS:
		return (erx_lane_hdr_wpos_load(m->hdr, &in->value));
	case ERX_PIPE_OP_COPY_NEED:
		in->value = run_copy_word(m->hdr, offsetof(erx_lane_hdr_t, need));
		return (true);
	case ERX_PIPE_OP_COPY_REC:
		return (run_copy_rec(r, m, a, in));
	case ERX_PIPE_OP_COPY_DATA:
		if (a->n > r->lanes[a->lane].size ||
		    !run_within(a->off, a->n, r->len))
			return (false);
		erx_shm_copy((const _Atomic uint64_t *)m->area,
		    r->lanes[a->lane].size, a->pos, buf + a->off, a->n);
		return (true);
	case ERX_PIPE_OP_STORE_RPOS:
		return (erx_pipe_rpage_rpos_store(m->rpage, a->value));
	case ERX_PIPE_OP_STORE_WAKE:
		return (erx_pipe_rpage_wake_store(m->rpage, a->value));
	case ERX_PIPE_OP_SET_SLEEPER:
		(void)atomic_fetch_or_explicit(&m->rpage->sleepers, bit,
		    memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_CLEAR_SLEEPER:
		(void)atomic_fetch_and_explicit(&m->rpage->sleepers, ~bit,
		    memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_RING_WRITER:
		fx->ring_writer(fx->ctx, a->lane);
		return (true);
	default:
		return (false);
	}
}

/* Performs one read end action other than WAIT and DONE; false on a bad one. */
static bool
run_rperform(const erx_pipe_rstate_t *r, const erx_pipe_rmap_t *maps,
    erx_pipe_lock_t *lock, unsigned char *buf, const erx_pipe_fx_t *fx,
    const erx_pipe_act_t *a, erx_pipe_in_t *in)
{
	uint64_t bit, bits;
	uint32_t expected;

	bit = UINT64_C(1) << r->rix;
	switch (a->op) {
	case ERX_PIPE_OP_CLOCK:
		in->value = fx->clock(fx->ctx);
		return (true);
	case ERX_PIPE_OP_COPY_CUR:
		run_copy_cur(lock, in);
		return (true);
	case ERX_PIPE_OP_COPY_WENDS: {
		uint32_t wends;

		run_copy_field(lock, offsetof(erx_pipe_lock_t, wends), &wends,
		    sizeof(wends));
		in->value = wends;
		return (true);
	}
	case ERX_PIPE_OP_COPY_WAITERS:
		in->value = run_copy_word(lock, offsetof(erx_pipe_lock_t, waiters));
		return (true);
	case ERX_PIPE_OP_STORE_CUR:
		return (run_store_cur(r, lock, a));
	case ERX_PIPE_OP_SET_WAITER:
		(void)atomic_fetch_or_explicit(&lock->waiters, bit,
		    memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_CLEAR_WAITER:
		(void)atomic_fetch_and_explicit(&lock->waiters, ~bit,
		    memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_TAKE_LOCK:
		expected = 0;
		in->ok = atomic_compare_exchange_strong_explicit(&lock->owner,
		    &expected, 1 + r->rix, memory_order_acq_rel,
		    memory_order_relaxed);
		return (true);
	case ERX_PIPE_OP_RELEASE_LOCK:
		return (erx_pipe_lock_owner_store(lock, 0));
	case ERX_PIPE_OP_FENCE:
		atomic_thread_fence(memory_order_seq_cst);
		return (true);
	case ERX_PIPE_OP_RING_READERS:
		for (bits = a->value & ~bit; bits != 0; bits &= bits - 1)
			fx->ring_reader(fx->ctx,
			    (uint32_t)__builtin_ctzll(bits));
		return (true);
	case ERX_PIPE_OP_DRAINED:
		if (a->lane >= r->nlanes)
			return (false);
		fx->drained(fx->ctx, a->lane);
		return (true);
	case ERX_PIPE_OP_BROKEN:
		if (a->lane >= r->nlanes)
			return (false);
		fx->broken(fx->ctx, a->lane, a->n);
		return (true);
	default:
		return (run_rlane(r, maps, buf, fx, a, in));
	}
}

erx_pipe_act_t
erx_pipe_rrun(erx_pipe_rstate_t *r, const erx_pipe_rmap_t *maps,
    erx_pipe_lock_t *lock, void *buf, const erx_pipe_fx_t *fx)
{
	erx_pipe_act_t act;
	erx_pipe_in_t in;

	if (r->rix >= ERX_PIPE_READERS_MAX)
		return (run_fail());
	memset(&in, 0, sizeof(in));
	for (;;) {
		act = erx_pipe_rstep(r, &in);
		if (act.op == ERX_PIPE_OP_DONE || act.op == ERX_PIPE_OP_WAIT)
			return (act);
		memset(&in, 0, sizeof(in));
		if (!run_rperform(r, maps, lock, buf, fx, &act, &in))
			return (run_fail());
	}
}
