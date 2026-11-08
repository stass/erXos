/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The lane's reader.  This file is the only one that names a lane's shared
 * layouts (a build check enforces it), and only erx_lane_take and the two
 * helpers it calls, lane_copy for the data area and lane_release for need,
 * load from the producer's side.  The checks of what they copied are pure
 * functions (lane_check_wpos, lane_check_record, lane_crossed); the record
 * state machine itself, opening, copying and closing, is the short middle
 * of erx_lane_take, over the reader's private fields.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/lane.h"

/* Positions, record headers and the data area are multiples of this. */
#define LANE_GRAIN	UINT64_C(16)

_Static_assert(ERX_LANE_REC_SIZE == LANE_GRAIN, "a record header is one grain");
_Static_assert(ERX_LANE_MIN % LANE_GRAIN == 0, "the area is whole grains");
_Static_assert(ERX_LANE_SIDE_DATA % ERX_PAGE_SIZE == 0 &&
    ERX_LANE_SIDE_RPAGE % ERX_PAGE_SIZE == 0, "a side's parts are pages");

static erx_lane_fault_t lane_check_record(uint64_t, uint32_t);
static erx_lane_fault_t lane_check_wpos(uint64_t, uint64_t, uint64_t,
    uint64_t *);
static void lane_copy(const erx_lane_reader_t *, uint64_t, unsigned char *,
    uint64_t);
static bool lane_crossed(uint64_t, uint64_t, uint64_t);
static const _Atomic uint64_t *lane_data(const erx_lane_reader_t *);
static uint64_t lane_grain_down(uint64_t);
static const erx_lane_hdr_t *lane_header(const erx_lane_reader_t *);
static uint64_t lane_min(uint64_t, uint64_t);
static erx_lane_status_t lane_refuse(erx_lane_reader_t *, erx_lane_fault_t);
static bool lane_release(const erx_lane_reader_t *, uint64_t);
static erx_lane_rpage_t *lane_rpage(const erx_lane_reader_t *);

/*
 * A record that starts at pos is sound when its body fits ERX_FRAME_MAX
 * and its end, header and padded body, is still a position: positions
 * never wrap, so a record that would end past the last one is malformed.
 */
static erx_lane_fault_t
lane_check_record(uint64_t pos, uint32_t len)
{
	uint64_t end, padded;

	if (len > ERX_FRAME_MAX)
		return (ERX_LANE_RECORD_TOO_LONG);
	padded = ((uint64_t)len + LANE_GRAIN - 1) & ~(LANE_GRAIN - 1);
	if (__builtin_add_overflow(pos, LANE_GRAIN + padded, &end))
		return (ERX_LANE_RECORD_PAST_END);
	return (ERX_LANE_SOUND);
}

/*
 * A copied wpos is sound when it is a multiple of 16, at least what the
 * reader has consumed, and at most the area's size past the rpos it last
 * published, which is all the room the producer had.  On success *avail
 * is the bytes published and not yet consumed.
 */
static erx_lane_fault_t
lane_check_wpos(uint64_t pos, uint64_t size, uint64_t wpos, uint64_t *avail)
{
	if ((wpos & (LANE_GRAIN - 1)) != 0)
		return (ERX_LANE_WPOS_UNALIGNED);
	if (wpos < pos)
		return (ERX_LANE_WPOS_BEHIND);
	if (wpos - lane_grain_down(pos) > size)
		return (ERX_LANE_WPOS_AHEAD);
	*avail = wpos - pos;
	return (ERX_LANE_SOUND);
}

/*
 * Copies n bytes from position pos of the data area into dst, wrapping at
 * the area's end.  Every load is an aligned relaxed atomic load of one
 * word, so a producer that rewrites the area concurrently changes what is
 * copied but never makes the copy undefined; each byte is loaded once.
 * The acquire load of wpos that made these bytes available orders them.
 */
static void
lane_copy(const erx_lane_reader_t *reader, uint64_t pos, unsigned char *dst,
    uint64_t n)
{
	const _Atomic uint64_t *words;
	uint64_t chunk, mask, offset, skip, word;

	words = lane_data(reader);
	mask = reader->size - 1;
	while (n > 0) {
		offset = pos & mask;
		skip = offset % sizeof(word);
		chunk = lane_min(sizeof(word) - skip, n);
		word = atomic_load_explicit(&words[offset / sizeof(word)],
		    memory_order_relaxed);
		memcpy(dst, (const unsigned char *)&word + skip, chunk);
		pos += chunk;
		dst += chunk;
		n -= chunk;
	}
}

/* Whether a store moving a position from before to after crossed waited. */
static bool
lane_crossed(uint64_t before, uint64_t after, uint64_t waited)
{
	return (before < waited && waited <= after);
}

static const _Atomic uint64_t *
lane_data(const erx_lane_reader_t *reader)
{
	return ((const _Atomic uint64_t *)(reader->peer_side +
	    ERX_LANE_SIDE_DATA));
}

static uint64_t
lane_grain_down(uint64_t pos)
{
	return (pos & ~(LANE_GRAIN - 1));
}

static const erx_lane_hdr_t *
lane_header(const erx_lane_reader_t *reader)
{
	return ((const erx_lane_hdr_t *)reader->peer_side);
}

static uint64_t
lane_min(uint64_t a, uint64_t b)
{
	return (a < b ? a : b);
}

static erx_lane_status_t
lane_refuse(erx_lane_reader_t *reader, erx_lane_fault_t fault)
{
	reader->phase = ERX_LANE_REFUSED;
	reader->fault = fault;
	return (ERX_LANE_MALFORMED);
}

/*
 * Publishes the rpos that the reader's pos now allows, when it moved past
 * the one the reader published before this take, and returns whether that
 * store crossed the need the producer published, so the caller rings the
 * producer's bell.  Between takes the published rpos is always pos rounded
 * down to 16, which lane_check_wpos relies on.
 */
static bool
lane_release(const erx_lane_reader_t *reader, uint64_t published)
{
	uint64_t need, rpos;

	rpos = lane_grain_down(reader->pos);
	if (rpos == published)
		return (false);

	/*
	 * Release: pairs with the producer's acquire load of rpos, so every
	 * load of the room below rpos is done before the producer writes it.
	 */
	erx_lane_rpage_rpos_store(lane_rpage(reader), rpos);

	/*
	 * Orders the store of rpos before the load of need, against the
	 * producer's store of need, full fence and load of rpos: one of the
	 * two loads sees the other side's store, so no wait is lost.
	 */
	atomic_thread_fence(memory_order_seq_cst);
	erx_lane_hdr_need_load(lane_header(reader), &need);
	return (lane_crossed(published, rpos, need));
}

static erx_lane_rpage_t *
lane_rpage(const erx_lane_reader_t *reader)
{
	return ((erx_lane_rpage_t *)(reader->own_side + ERX_LANE_SIDE_RPAGE));
}

bool
erx_lane_reader_init(erx_lane_reader_t *reader, const void *peer_side,
    void *own_side, uint64_t size)
{
	if (reader == NULL || peer_side == NULL || own_side == NULL)
		return (false);
	if ((uintptr_t)peer_side % ERX_PAGE_SIZE != 0 ||
	    (uintptr_t)own_side % ERX_PAGE_SIZE != 0)
		return (false);
	if (size < ERX_LANE_MIN || size > ERX_LANE_MAX ||
	    (size & (size - 1)) != 0)
		return (false);

	*reader = (erx_lane_reader_t){
		.peer_side = peer_side,
		.own_side = own_side,
		.size = size,
		.phase = ERX_LANE_BETWEEN
	};
	return (true);
}

uint64_t
erx_lane_side_bytes(uint64_t size)
{
	if (size < ERX_LANE_MIN || size > ERX_LANE_MAX || (size & (size - 1)) != 0)
		return (0);
	return (ERX_LANE_SIDE_DATA + size);
}

erx_lane_status_t
erx_lane_take(erx_lane_reader_t *reader, void *buf, size_t max,
    erx_lane_part_t *part)
{
	unsigned char header[ERX_LANE_REC_SIZE];
	erx_lane_rec_t record = { 0 };
	uint64_t avail, n, published, wpos;
	erx_lane_fault_t fault;

	*part = (erx_lane_part_t){ 0 };
	if (reader->phase == ERX_LANE_REFUSED)
		return (ERX_LANE_MALFORMED);

	/*
	 * Acquire: pairs with the producer's release store of wpos, so every
	 * byte it wrote below wpos is visible to the copies below.
	 */
	erx_lane_hdr_wpos_load(lane_header(reader), &wpos);
	fault = lane_check_wpos(reader->pos, reader->size, wpos, &avail);
	if (fault != ERX_LANE_SOUND)
		return (lane_refuse(reader, fault));
	if (avail == 0)
		return (ERX_LANE_EMPTY);

	published = lane_grain_down(reader->pos);
	if (reader->phase == ERX_LANE_BETWEEN) {
		/*
		 * Between records pos and wpos are both multiples of 16, so a
		 * published header is published whole.
		 */
		lane_copy(reader, reader->pos, header, sizeof(header));
		/* Cannot fail: the copy is a whole header. */
		erx_lane_rec_decode(header, sizeof(header), &record);
		fault = lane_check_record(reader->pos, record.len);
		if (fault != ERX_LANE_SOUND)
			return (lane_refuse(reader, fault));
		reader->pos += sizeof(header);
		avail -= sizeof(header);
		reader->len = record.len;
		reader->kind = record.kind;
		reader->zero = record.zero;
		reader->body_left = record.len;
		reader->phase = ERX_LANE_IN_BODY;
		part->opened = true;
	}

	n = lane_min(lane_min(avail, reader->body_left), max);
	lane_copy(reader, reader->pos, buf, n);
	part->offset = reader->len - reader->body_left;
	part->copied = (size_t)n;
	reader->pos += n;
	reader->body_left -= n;
	if (reader->body_left == 0) {
		/*
		 * The padding ends on a multiple of 16 at or below wpos, so it
		 * is published with the body's last byte.
		 */
		reader->pos = lane_grain_down(reader->pos + LANE_GRAIN - 1);
		reader->phase = ERX_LANE_BETWEEN;
		part->closed = true;
	}
	part->len = reader->len;
	part->kind = reader->kind;
	part->zero = reader->zero;
	part->ring = lane_release(reader, published);
	return (ERX_LANE_TOOK);
}

erx_lane_status_t
erx_lane_take_armed(erx_lane_reader_t *reader, void *buf, size_t max,
    erx_lane_part_t *part)
{
	if (reader->phase == ERX_LANE_REFUSED)
		return (ERX_LANE_MALFORMED);

	/*
	 * Release, then a full fence: orders the store of wake before the
	 * load of wpos in erx_lane_take, against the producer's release store
	 * of wpos, full fence and load of wake, so either this take sees the
	 * new wpos or the producer sees this wake and rings.
	 */
	erx_lane_rpage_wake_store(lane_rpage(reader),
	    lane_grain_down(reader->pos) + 1);
	atomic_thread_fence(memory_order_seq_cst);
	return (erx_lane_take(reader, buf, max, part));
}
