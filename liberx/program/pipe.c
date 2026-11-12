/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A program's pipe ends (pipe.h).  An end is made whole by erx_pipe_open
 * from a descriptor the startup message's check accepted, before main and
 * before the executor reads any report; from then on the executor changes
 * it only under its lock, through the handler's reports, and its last
 * reference lets it go in erx_pipe_release.  The NIF's ends
 * (otp/erts/emulator/nifs/erxos/erx_pipe_nif.c) are the same ends over
 * resources; this file keeps the program layer's rules: its memory is
 * whole pages (pages.h), and its notices go through the channel's send.
 *
 * Every value a report or descriptor carries was checked by the profile's
 * generated check, and is checked again here where it indexes or sizes
 * anything: a reader index against ERX_PIPE_READERS_MAX, a lane's size
 * against the two the pipe server makes.
 */

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/etf.h"
#include "erx/lane.h"
#include "erx/pipe.h"
#include "erx/pipe_run.h"
#include "liberx/backend/api.h"
#include "liberx/program/channel.h"
#include "liberx/program/fd.h"
#include "liberx/program/inbound.h"
#include "liberx/program/pages.h"
#include "liberx/program/pipe.h"

_Static_assert(_Alignof(erx_pipe_rmap_t) <= _Alignof(erx_pipe_rlane_t) &&
    _Alignof(erx_pipe_lane_t) <= _Alignof(erx_pipe_rmap_t),
    "a read end's three lane arrays follow each other in one run, each aligned");

/* ---------------------------------------------------------------------
 * Capabilities, doorbells and notices */

/* Closes the capability in *cap once; the slot is ERX_CAP_NULL from then on. */
static void
cap_close(uint64_t *cap)
{
	if (*cap != ERX_CAP_NULL)
		(void)erx_cap_close(*cap);
	*cap = ERX_CAP_NULL;
}

/* A ring of a doorbell whose end has gone fails, which is harmless. */
static void
bell_ring(uint64_t bell)
{
	if (bell != ERX_CAP_NULL)
		(void)erx_irq_trigger(bell);
}

/*
 * Sends the handler {erx_prog, 1, {Tag, Pipe, End}}, or with wend
 * {erx_prog, 1, {Tag, Pipe, End, Wend}}, through the channel's send, which
 * may wait for room.  A send the session refuses changes nothing the end
 * can mend: the handler learns the end is gone from the program's end.
 */
static void
notice_send(const char *tag, const erx_pipe_end_t *e, const uint32_t *wend)
{
	uint8_t frame[64];
	erx_etf_writer_t writer;
	erx_lane_iov_t iov;
	size_t len;

	erx_etf_writer_init(&writer, frame, sizeof(frame));
	erx_etf_put_tuple(&writer, 3);
	erx_etf_put_atom(&writer, "erx_prog", strlen("erx_prog"));
	erx_etf_put_integer(&writer, 1);
	erx_etf_put_tuple(&writer, wend != NULL ? 4 : 3);
	erx_etf_put_atom(&writer, tag, strlen(tag));
	erx_etf_put_integer(&writer, e->pipe);
	erx_etf_put_integer(&writer, e->end);
	if (wend != NULL)
		erx_etf_put_integer(&writer, *wend);
	if (!erx_etf_writer_done(&writer, &len))
		return;
	iov = (erx_lane_iov_t){ frame, len };
	(void)erx_prog_channel_send(&iov, 1);
}

/* ---------------------------------------------------------------------
 * A read end's lanes */

static uint64_t
lanes_bytes(uint32_t room)
{
	return ((uint64_t)room * (sizeof(erx_pipe_rlane_t) + sizeof(erx_pipe_rmap_t) +
	    sizeof(erx_pipe_lane_t)));
}

/*
 * Makes the read end's arrays hold at least want lanes: a new run with the
 * nlanes in use copied, at least twice the old room, and the old run given
 * back.  False, leaving the arrays as they were, when no run can be made.
 */
static bool
lanes_reserve(erx_pipe_rend_t *r, uint32_t want)
{
	uint32_t room;
	unsigned char *run;
	erx_pipe_rlane_t *rlanes;
	erx_pipe_rmap_t *maps;
	erx_pipe_lane_t *lanes;

	if (want <= r->room)
		return (true);
	room = r->room > UINT32_MAX / 2 ? UINT32_MAX : 2 * r->room;
	if (room < want)
		room = want;
	if (room < 4)
		room = 4;
	if ((run = erx_prog_pages_take(lanes_bytes(room))) == NULL)
		return (false);
	rlanes = (erx_pipe_rlane_t *)(void *)run;
	maps = (erx_pipe_rmap_t *)(void *)(rlanes + room);
	lanes = (erx_pipe_lane_t *)(void *)(maps + room);
	if (r->st.nlanes != 0) {
		memcpy(rlanes, r->st.lanes, r->st.nlanes * sizeof(*rlanes));
		memcpy(maps, r->maps, r->st.nlanes * sizeof(*maps));
		memcpy(lanes, r->lanes, r->st.nlanes * sizeof(*lanes));
	}
	erx_prog_pages_give(r->run, lanes_bytes(r->room));
	r->run = run;
	r->room = room;
	r->st.lanes = rlanes;
	r->maps = maps;
	r->lanes = lanes;
	return (true);
}

/* A lane's data area is one of the two sizes the pipe server makes. */
static bool
lane_size_ok(uint32_t size)
{
	return (size == ERX_PIPE_RING_FIRST || size == ERX_PIPE_RING_NEXT);
}

/* The index of write end wend's lane, or nlanes. */
static uint32_t
lane_find(const erx_pipe_rend_t *r, uint32_t wend)
{
	uint32_t at;

	for (at = 0; at < r->st.nlanes; at++)
		if (r->st.lanes[at].wend == wend)
			break;
	return (at);
}

/*
 * Appends write end wend's lane: its ring mapped read-only, its reader page
 * read-write, and the capabilities kept, the writer open with bell or, for
 * bell ERX_CAP_NULL, gone.  False, keeping nothing and closing nothing, when
 * the lane cannot be held; the caller closes the capabilities then.
 */
static bool
lane_add(erx_pipe_rend_t *r, uint32_t wend, uint64_t ring, uint64_t rpage, uint32_t size,
    uint64_t bell)
{
	const uint64_t ring_bytes = (uint64_t)ERX_PIPE_RING_DATA + size;
	unsigned char *ring_map;
	erx_pipe_rpage_t *rpage_map;
	uint32_t at;

	if (!lane_size_ok(size) || r->st.nlanes == UINT32_MAX || !lanes_reserve(r, r->st.nlanes + 1))
		return (false);
	if ((ring_map = erx_prog_object_map(ring, ring_bytes, ERX_PROT_R)) == NULL)
		return (false);
	if ((rpage_map = erx_prog_object_map(rpage, ERX_PAGE_SIZE, ERX_PROT_RW)) == NULL) {
		erx_prog_pages_give(ring_map, ring_bytes);
		return (false);
	}
	at = r->st.nlanes;
	r->st.lanes[at] = (erx_pipe_rlane_t){ .wend = wend, .size = size,
	    .writer = bell != ERX_CAP_NULL ? ERX_PIPE_WRITER_OPEN : ERX_PIPE_WRITER_GONE };
	r->maps[at] = (erx_pipe_rmap_t){ (const erx_lane_hdr_t *)(void *)ring_map,
	    ring_map + ERX_PIPE_RING_DATA, rpage_map };
	r->lanes[at] = (erx_pipe_lane_t){ .ring = ring, .rpage = rpage, .bell = bell };
	r->st.nlanes = at + 1;
	return (true);
}

/* Lets go of lane at's mappings and capabilities; its pages are NULL from then on. */
static void
lane_let_go(erx_pipe_rend_t *r, uint32_t at)
{
	erx_pipe_lane_t *lane = &r->lanes[at];

	erx_prog_pages_give(r->maps[at].hdr, (uint64_t)ERX_PIPE_RING_DATA + r->st.lanes[at].size);
	erx_prog_pages_give(r->maps[at].rpage, ERX_PAGE_SIZE);
	r->maps[at] = (erx_pipe_rmap_t){ NULL, NULL, NULL };
	cap_close(&lane->ring);
	cap_close(&lane->rpage);
	cap_close(&lane->bell);
}

/* ---------------------------------------------------------------------
 * What a read end's run asks of it (erx_pipe_fx_t) */

static uint64_t
fx_clock(void *ctx)
{
	(void)ctx;
	return (erx_clock_ns());
}

static void
fx_ring_reader(void *ctx, uint32_t rix)
{
	const erx_pipe_end_t *e = ctx;

	if (rix < ERX_PIPE_READERS_MAX)
		bell_ring(e->peers[rix]);
}

static void
fx_ring_writer(void *ctx, uint32_t lane)
{
	const erx_pipe_end_t *e = ctx;

	if (lane < e->u.r.st.nlanes)
		bell_ring(e->u.r.lanes[lane].bell);
}

/*
 * A lane drained after its writer went is let go of at once; the run holds
 * the end's lock, where no notice may be sent (the send may wait for room,
 * which only the executor announces, and the executor may wait for this
 * lock), so the {drained} is owed, and sent once the lock is let go.
 */
static void
fx_drained(void *ctx, uint32_t lane)
{
	erx_pipe_end_t *e = ctx;

	if (lane < e->u.r.st.nlanes) {
		lane_let_go(&e->u.r, lane);
		e->u.r.lanes[lane].owed = true;
	}
}

/* A broken lane counts as gone and drained (PI2); the program layer writes no line of its own. */
static void
fx_broken(void *ctx, uint32_t lane, uint64_t fault)
{
	(void)ctx;
	(void)lane;
	(void)fault;
}

static erx_pipe_fx_t
end_fx(erx_pipe_end_t *e)
{
	return ((erx_pipe_fx_t){ e, fx_clock, fx_ring_reader, fx_ring_writer, fx_drained,
	    fx_broken });
}

/* ---------------------------------------------------------------------
 * Set-up */

/* Keeps a read end's doorbell at index rix; false for an index past the bound. */
static bool
peer_keep(erx_pipe_end_t *e, uint8_t rix, uint64_t bell)
{
	if (rix >= ERX_PIPE_READERS_MAX)
		return (false);
	/* A repeated report may carry the value the end holds already: keep it, close nothing. */
	if (e->peers[rix] != bell)
		cap_close(&e->peers[rix]);
	e->peers[rix] = bell;
	return (true);
}

/* {pipe, write, _, #{wend, ring, rpage, size, readers}} */
static int
write_open(erx_pipe_end_t *e, const erx_prog_write_end_t *v)
{
	erx_pipe_wend_t *w = &e->u.w;
	const uint64_t ring_bytes = (uint64_t)ERX_PIPE_RING_DATA + v->size;
	erx_prog_write_readers_iter_t readers = v->readers;
	erx_prog_reader_t reader;
	unsigned char *ring_map;

	w->ring = v->ring;
	w->rpage = v->rpage;
	while (erx_prog_write_readers_next(&readers, &reader)) {
		const bool known = reader.rix < ERX_PIPE_READERS_MAX && e->peers[reader.rix] != ERX_CAP_NULL;

		if (!peer_keep(e, reader.rix, reader.cap)) {
			cap_close(&reader.cap);
			return (ERX_EINVAL);
		}
		if (!known)
			w->st.readers++;
	}
	if (!lane_size_ok(v->size))
		return (ERX_EINVAL);
	/* Set before the ring is mapped: a failed set-up gives the mapping back by this size. */
	w->st.size = v->size;
	if ((ring_map = erx_prog_object_map(w->ring, ring_bytes, ERX_PROT_RW)) == NULL)
		return (ERX_ENOMEM);
	w->map.hdr = (erx_lane_hdr_t *)(void *)ring_map;
	w->map.area = ring_map + ERX_PIPE_RING_DATA;
	if ((w->map.rpage = erx_prog_object_map(w->rpage, ERX_PAGE_SIZE, ERX_PROT_R)) == NULL)
		return (ERX_ENOMEM);
	w->st.chunk = ERX_PIPE_BUF;
	return (ERX_OK);
}

/*
 * {pipe, read, _, #{rix, lock, wends, writers, readers}}: the lock page,
 * every write end's lane, the other read ends' doorbells, and the index
 * last, once the lanes are mapped, since taking it clears its bits there.
 */
static int
read_open(erx_pipe_end_t *e, const erx_prog_read_end_t *v)
{
	erx_pipe_rend_t *r = &e->u.r;
	erx_prog_writers_iter_t writers = v->writers, count = v->writers;
	erx_prog_read_readers_iter_t readers = v->readers;
	erx_prog_reader_t reader;
	erx_prog_writer_t writer;
	uint32_t nwriters = 0;

	r->lock = v->lock;
	if ((r->lockpage = erx_prog_object_map(r->lock, ERX_PAGE_SIZE, ERX_PROT_RW)) == NULL)
		return (ERX_ENOMEM);
	r->st.known = v->wends;
	r->st.batches = ERX_PIPE_BATCHES;
	/* The check bounds the list by 8,192 writers, so the count cannot wrap. */
	while (erx_prog_writers_next(&count, &writer))
		nwriters++;
	if (!lanes_reserve(r, nwriters))
		return (ERX_ENOMEM);
	while (erx_prog_writers_next(&writers, &writer)) {
		/* {Wend, Ring, RPage, Size, {open, Bell} | gone} */
		uint64_t ring = writer.cap_1, rpage = writer.cap_2;
		uint64_t bell = writer.writer_state.which == ERX_PROG_WRITER_STATE_OPEN ?
		    writer.writer_state.u.open.cap : ERX_CAP_NULL;
		/* The check's writers are strictly ascending, so a wend repeats only in a malformed list. */
		const int status = lane_find(r, writer.wend) != r->st.nlanes ? ERX_EINVAL :
		    !lane_add(r, writer.wend, ring, rpage, writer.lane_size, bell) ? ERX_ENOMEM : ERX_OK;

		if (status != ERX_OK) {
			cap_close(&ring);
			cap_close(&rpage);
			cap_close(&bell);
			return (status);
		}
	}
	while (erx_prog_read_readers_next(&readers, &reader)) {
		if (reader.rix == v->rix || !peer_keep(e, reader.rix, reader.cap)) {
			cap_close(&reader.cap);
			return (ERX_EINVAL);
		}
	}
	return (erx_pipe_rtake(&r->st, v->rix, r->maps, r->lockpage) ? ERX_OK : ERX_EINVAL);
}

/*
 * Lets go of everything the end holds; the caller holds its lock or is its
 * only holder.  A read end first runs a read of 0 bytes, which ends the wait
 * its last read left, clearing its bits, before its pages are unmapped; a
 * read end whose index was never taken refuses the run and has no bits.
 */
static void
end_let_go(erx_pipe_end_t *e)
{
	erx_pipe_fx_t fx;

	switch (e->kind) {
	case ERX_PIPE_WRITE:
		erx_prog_pages_give(e->u.w.map.hdr, (uint64_t)ERX_PIPE_RING_DATA + e->u.w.st.size);
		erx_prog_pages_give(e->u.w.map.rpage, ERX_PAGE_SIZE);
		e->u.w.map = (erx_pipe_wmap_t){ NULL, NULL, NULL };
		cap_close(&e->u.w.ring);
		cap_close(&e->u.w.rpage);
		break;
	case ERX_PIPE_READ:
		if (e->u.r.lockpage != NULL) {
			fx = end_fx(e);
			erx_pipe_rstart(&e->u.r.st, 0);
			(void)erx_pipe_rrun(&e->u.r.st, e->u.r.maps, e->u.r.lockpage, NULL, &fx);
		}
		for (uint32_t at = 0; at < e->u.r.st.nlanes; at++)
			lane_let_go(&e->u.r, at);
		erx_prog_pages_give(e->u.r.lockpage, ERX_PAGE_SIZE);
		e->u.r.lockpage = NULL;
		cap_close(&e->u.r.lock);
		break;
	}
	for (uint32_t rix = 0; rix < ERX_PIPE_READERS_MAX; rix++)
		cap_close(&e->peers[rix]);
}

/* Frees an end whose holdings are let go. */
static void
end_free(erx_pipe_end_t *e)
{
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		break;
	case ERX_PIPE_READ:
		erx_prog_pages_give(e->u.r.run, lanes_bytes(e->u.r.room));
		break;
	}
	(void)pthread_mutex_destroy(&e->lock);
	erx_prog_pages_give(e, sizeof(*e));
}

int
erx_pipe_open(const erx_prog_descriptor_t *descriptor, erx_pipe_end_t **out)
{
	erx_pipe_end_t *e;
	int status;

	if ((e = erx_prog_pages_take(sizeof(*e))) == NULL)
		return (ERX_ENOMEM);
	memset(e, 0, sizeof(*e));
	e->obj.kind = ERX_PROG_OBJ_PIPE;
	if (pthread_mutex_init(&e->lock, NULL) != 0) {
		erx_prog_pages_give(e, sizeof(*e));
		return (ERX_ENOMEM);
	}
	switch (descriptor->which) {
	case ERX_PROG_DESCRIPTOR_PIPE_WRITE:
		e->kind = ERX_PIPE_WRITE;
		e->pipe = descriptor->u.pipe_write.pipe_end.pipe_id;
		e->end = descriptor->u.pipe_write.pipe_end.end_id;
		status = write_open(e, &descriptor->u.pipe_write.write_end);
		break;
	case ERX_PROG_DESCRIPTOR_PIPE_READ:
		e->kind = ERX_PIPE_READ;
		e->pipe = descriptor->u.pipe_read.pipe_end.pipe_id;
		e->end = descriptor->u.pipe_read.pipe_end.end_id;
		status = read_open(e, &descriptor->u.pipe_read.read_end);
		break;
	default:
		/* Not a pipe end: the plan refuses it.  A zeroed write end holds nothing to let go. */
		e->kind = ERX_PIPE_WRITE;
		status = ERX_EINVAL;
		break;
	}
	if (status != ERX_OK) {
		end_let_go(e);
		end_free(e);
		return (status);
	}
	*out = e;
	return (ERX_OK);
}

/* ---------------------------------------------------------------------
 * Reports, under the end's lock */

static void
end_lose(erx_pipe_end_t *e)
{
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		e->u.w.st.lost = true;
		break;
	case ERX_PIPE_READ:
		e->u.r.st.lost = true;
		break;
	}
}

/* Closes a capability a report carried unless the lane holds it already, as a repeated report's are. */
static void
cap_close_unless_held(uint64_t *cap, const erx_pipe_lane_t *held)
{
	if (held == NULL || (*cap != held->ring && *cap != held->rpage && *cap != held->bell))
		cap_close(cap);
}

/*
 * {pipe_writer, Pipe, End, Wend, Ring, RPage, Size, Bell, open | gone}: a
 * write end joined.  The read end keeps its lane and raises its count of
 * write ends it knows; an open writer's doorbell is rung once, so a writer
 * that published before this report wakes the reader (PI7), and a gone
 * one's closed at once.  A lane the end cannot hold loses the end, whose
 * reads then fail with EIO, rather than leave it waiting for a writer it
 * was told of.  A write end, or a lane it holds already, keeps nothing, and
 * the report's capabilities close, but for those the lane holds.
 */
static void
writer_join(erx_pipe_end_t *e, const erx_prog_report_t *report)
{
	uint64_t ring = report->u.pipe_writer.cap_1, rpage = report->u.pipe_writer.cap_2;
	uint64_t bell = report->u.pipe_writer.cap_3;
	const uint32_t wend = report->u.pipe_writer.wend;
	const bool open = report->u.pipe_writer.end_state == ERX_PROG_END_STATE_OPEN;
	const erx_pipe_lane_t *held = NULL;
	bool kept = false;
	uint32_t at;

	switch (e->kind) {
	case ERX_PIPE_WRITE:
		break;
	case ERX_PIPE_READ:
		if ((at = lane_find(&e->u.r, wend)) != e->u.r.st.nlanes)
			held = &e->u.r.lanes[at];
		else if (lane_add(&e->u.r, wend, ring, rpage, report->u.pipe_writer.lane_size,
		    open ? bell : ERX_CAP_NULL))
			kept = true;
		else
			end_lose(e);
		break;
	}
	if (!kept) {
		cap_close_unless_held(&ring, held);
		cap_close_unless_held(&rpage, held);
		cap_close_unless_held(&bell, held);
		return;
	}
	if (wend > e->u.r.st.known)
		e->u.r.st.known = wend;
	if (open)
		bell_ring(bell);
	else
		cap_close(&bell);
}

/* {pipe_writer_gone, Pipe, End, Wend}: the lane's writer is gone, and its doorbell closes. */
static void
writer_gone(erx_pipe_end_t *e, uint32_t wend)
{
	uint32_t at;

	switch (e->kind) {
	case ERX_PIPE_WRITE:
		return;
	case ERX_PIPE_READ:
		if ((at = lane_find(&e->u.r, wend)) == e->u.r.st.nlanes)
			return;
		e->u.r.st.lanes[at].writer = ERX_PIPE_WRITER_GONE;
		cap_close(&e->u.r.lanes[at].bell);
		return;
	}
}

/*
 * {pipe_reader, Pipe, End, Rix, Bell, open | gone}: a read end joined.  An
 * open one's doorbell is kept and rung once, and a write end counts it if
 * the index is new; a gone one's, or one naming the end's own index, is
 * closed.
 */
static void
reader_join(erx_pipe_end_t *e, const erx_prog_report_t *report)
{
	uint64_t bell = report->u.pipe_reader.cap;
	const uint8_t rix = report->u.pipe_reader.rix;
	bool known;

	if (report->u.pipe_reader.end_state != ERX_PROG_END_STATE_OPEN ||
	    rix >= ERX_PIPE_READERS_MAX ||
	    (e->kind == ERX_PIPE_READ && rix == e->u.r.st.rix)) {
		cap_close(&bell);
		return;
	}
	known = e->peers[rix] != ERX_CAP_NULL;
	(void)peer_keep(e, rix, bell);
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		if (!known)
			e->u.w.st.readers++;
		break;
	case ERX_PIPE_READ:
		break;
	}
	bell_ring(bell);
}

/* {pipe_reader_gone, Pipe, End, Rix}: a write end counts one read end fewer; its doorbell closes. */
static void
reader_gone(erx_pipe_end_t *e, uint8_t rix)
{
	if (rix >= ERX_PIPE_READERS_MAX || e->peers[rix] == ERX_CAP_NULL)
		return;
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		if (e->u.w.st.readers > 0)
			e->u.w.st.readers--;
		break;
	case ERX_PIPE_READ:
		break;
	}
	cap_close(&e->peers[rix]);
}

/* The pipe and end a report names; false for pipe_server_lost, which names every end. */
static bool
report_end(const erx_prog_report_t *report, uint32_t *pipe, uint32_t *end)
{
	switch (report->which) {
	case ERX_PROG_REPORT_PIPE_WRITER:
		*pipe = report->u.pipe_writer.pipe_id;
		*end = report->u.pipe_writer.end_id;
		return (true);
	case ERX_PROG_REPORT_PIPE_WRITER_GONE:
		*pipe = report->u.pipe_writer_gone.pipe_id;
		*end = report->u.pipe_writer_gone.end_id;
		return (true);
	case ERX_PROG_REPORT_PIPE_READER:
		*pipe = report->u.pipe_reader.pipe_id;
		*end = report->u.pipe_reader.end_id;
		return (true);
	case ERX_PROG_REPORT_PIPE_READER_GONE:
		*pipe = report->u.pipe_reader_gone.pipe_id;
		*end = report->u.pipe_reader_gone.end_id;
		return (true);
	case ERX_PROG_REPORT_PIPE_LOST:
		*pipe = report->u.pipe_lost.pipe_id;
		*end = report->u.pipe_lost.end_id;
		return (true);
	case ERX_PROG_REPORT_PIPE_SERVER_LOST:
		return (false);
	}
	return (false);
}

/* Applies a report to the end it names; the caller holds the end's lock. */
static void
report_apply(erx_pipe_end_t *e, const erx_prog_report_t *report)
{
	switch (report->which) {
	case ERX_PROG_REPORT_PIPE_WRITER:
		writer_join(e, report);
		return;
	case ERX_PROG_REPORT_PIPE_WRITER_GONE:
		writer_gone(e, report->u.pipe_writer_gone.wend);
		return;
	case ERX_PROG_REPORT_PIPE_READER:
		reader_join(e, report);
		return;
	case ERX_PROG_REPORT_PIPE_READER_GONE:
		reader_gone(e, report->u.pipe_reader_gone.rix);
		return;
	case ERX_PROG_REPORT_PIPE_LOST:
		end_lose(e);
		return;
	case ERX_PROG_REPORT_PIPE_SERVER_LOST:
		return;
	}
}

void
erx_pipe_report(const erx_prog_report_t *report)
{
	uint64_t caps[ERX_PROG_REPORT_CAPS];
	erx_pipe_end_t *e;
	uint32_t pipe, end;
	size_t ncaps;

	if (report->which == ERX_PROG_REPORT_PIPE_SERVER_LOST) {
		erx_prog_fd_each_end(end_lose);
		return;
	}
	if (report_end(report, &pipe, &end) && (e = erx_prog_fd_find_end(pipe, end)) != NULL) {
		report_apply(e, report);
		(void)pthread_mutex_unlock(&e->lock);
		return;
	}
	/* An end the program let go of, or never held: what the report installed closes. */
	ncaps = erx_prog_report_caps(report, caps);
	for (size_t at = 0; at < ncaps; at++)
		cap_close(&caps[at]);
}

/* ---------------------------------------------------------------------
 * Release */

void
erx_pipe_release(erx_pipe_end_t *e)
{
	/* An executor that found the end before the table let go of it holds this lock: wait it out. */
	(void)pthread_mutex_lock(&e->lock);
	end_let_go(e);
	(void)pthread_mutex_unlock(&e->lock);
	/* Nothing else holds the end now; its notices go without its lock, drained ones first. */
	switch (e->kind) {
	case ERX_PIPE_WRITE:
		break;
	case ERX_PIPE_READ:
		for (uint32_t at = 0; at < e->u.r.st.nlanes; at++) {
			if (e->u.r.lanes[at].owed) {
				e->u.r.lanes[at].owed = false;
				notice_send("drained", e, &e->u.r.st.lanes[at].wend);
			}
		}
		break;
	}
	notice_send("closed", e, NULL);
	end_free(e);
}
