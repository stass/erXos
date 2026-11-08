/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The lane's reader and writer.  This file is the only one that names a
 * lane's shared layouts (a build check enforces it).  Only erx_lane_take
 * and the two helpers it calls, lane_copy for the data area and
 * lane_release for need, load from the producer's side; only erx_lane_put
 * and lane_publish, for wake, load from the consumer's side.  The checks of
 * what they load are pure functions (lane_check_wpos, lane_check_record,
 * lane_check_rpos, lane_crossed), as are the writer's sums of room and need
 * (lane_free, lane_need); each record state machine, opening, copying and
 * closing, is the short middle of erx_lane_take or erx_lane_put, over the
 * party's private fields.
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
static erx_lane_fault_t lane_check_rpos(uint64_t, uint64_t, uint64_t);
static erx_lane_fault_t lane_check_wpos(uint64_t, uint64_t, uint64_t,
    uint64_t *);
static void lane_copy(const erx_lane_reader_t *, uint64_t, unsigned char *,
    uint64_t);
static bool lane_crossed(uint64_t, uint64_t, uint64_t);
static const _Atomic uint64_t *lane_data(const erx_lane_reader_t *);
static uint64_t lane_room_past(uint64_t, uint64_t, uint64_t);
static void lane_gather(const erx_lane_writer_t *, const erx_lane_item_t *,
    uint64_t, uint64_t, uint64_t);
static uint64_t lane_grain_down(uint64_t);
static uint64_t lane_grain_up(uint64_t);
static const erx_lane_hdr_t *lane_header(const erx_lane_reader_t *);
static bool lane_item_len(const erx_lane_writer_t *, const erx_lane_item_t *,
    uint32_t *);
static uint64_t lane_min(uint64_t, uint64_t);
static uint64_t lane_need(uint64_t, uint64_t, uint64_t, uint64_t);
static bool lane_publish(const erx_lane_writer_t *, uint64_t);
static void lane_put_sum(erx_lane_put_t *, const erx_lane_put_t *, bool);
static erx_lane_status_t lane_refuse(erx_lane_reader_t *, erx_lane_fault_t);
static bool lane_release(const erx_lane_reader_t *, uint64_t);
static uint64_t lane_rest(const erx_lane_writer_t *, uint32_t);
static erx_lane_rpage_t *lane_rpage(const erx_lane_reader_t *);
static bool lane_sides_sound(const void *, const void *, uint64_t);
static bool lane_size_sound(uint64_t);
static erx_lane_hdr_t *lane_writer_header(const erx_lane_writer_t *);
static const erx_lane_rpage_t *lane_writer_rpage(const erx_lane_writer_t *);
static erx_lane_put_status_t lane_writer_refuse(erx_lane_writer_t *,
    erx_lane_fault_t);
static void lane_write(const erx_lane_writer_t *, uint64_t,
    const unsigned char *, uint64_t);
static void lane_write_header(const erx_lane_writer_t *, uint32_t, uint32_t,
    uint64_t);

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

/* Both sides are mapped page-aligned and the area's size is a lane's. */
static bool
lane_sides_sound(const void *a, const void *b, uint64_t size)
{
	return (a != NULL && b != NULL && (uintptr_t)a % ERX_PAGE_SIZE == 0 &&
	    (uintptr_t)b % ERX_PAGE_SIZE == 0 && lane_size_sound(size));
}

/* A power of two from ERX_LANE_MIN to ERX_LANE_MAX. */
static bool
lane_size_sound(uint64_t size)
{
	return (size >= ERX_LANE_MIN && size <= ERX_LANE_MAX &&
	    (size & (size - 1)) == 0);
}

bool
erx_lane_reader_init(erx_lane_reader_t *reader, const void *peer_side,
    void *own_side, uint64_t size)
{
	if (reader == NULL || !lane_sides_sound(peer_side, own_side, size))
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
	if (!lane_size_sound(size))
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

/* ------------------------------------------------------------- the writer */

/*
 * A copied rpos is sound when it is a multiple of 16, at least the rpos
 * the writer read before, and at most the wpos it published, which is all
 * the consumer can have read.  These bounds keep the unread bytes, pos less
 * rpos, at most the area's size, since the writer never writes past the
 * last sound rpos plus the size.
 */
static erx_lane_fault_t
lane_check_rpos(uint64_t pos, uint64_t last, uint64_t rpos)
{
	if ((rpos & (LANE_GRAIN - 1)) != 0)
		return (ERX_LANE_RPOS_UNALIGNED);
	if (rpos < last)
		return (ERX_LANE_RPOS_BEHIND);
	if (rpos > pos)
		return (ERX_LANE_RPOS_AHEAD);
	return (ERX_LANE_SOUND);
}

/*
 * The room past the reserve, given unread bytes of the area; 0
 * when the reserve takes all of it.  Every term is a multiple of 16.
 */
static uint64_t
lane_room_past(uint64_t size, uint64_t unread, uint64_t reserve)
{
	uint64_t room = size - unread;

	return (room > reserve ? room - reserve : 0);
}

/*
 * Copies n bytes of the item's body, from body offset offset, into the
 * data area at position pos.  The caller has checked that the body holds
 * offset plus n bytes.
 */
static void
lane_gather(const erx_lane_writer_t *writer, const erx_lane_item_t *item,
    uint64_t offset, uint64_t pos, uint64_t n)
{
	const erx_lane_iov_t *piece;
	uint64_t chunk;

	for (size_t i = 0; n > 0 && i < item->iovcnt; i++) {
		piece = &item->iov[i];
		if (offset >= piece->len) {
			offset -= piece->len;
			continue;
		}
		chunk = lane_min(piece->len - offset, n);
		lane_write(writer, pos,
		    (const unsigned char *)piece->base + offset, chunk);
		pos += chunk;
		n -= chunk;
		offset = 0;
	}
}

static uint64_t
lane_grain_up(uint64_t value)
{
	return (lane_grain_down(value + LANE_GRAIN - 1));
}

/*
 * The body length of the item, when the writer can write it now: false
 * for a missing piece, a body past ERX_FRAME_MAX, a reserve that leaves no
 * room for a header, a record other than the open one (its length, kind
 * or zero word differ), or a new record
 * that would end past the last position.
 */
static bool
lane_item_len(const erx_lane_writer_t *writer, const erx_lane_item_t *item,
    uint32_t *len)
{
	uint64_t end, total = 0;

	if (item->iovcnt > 0 && item->iov == NULL)
		return (false);
	for (size_t i = 0; i < item->iovcnt; i++) {
		if (item->iov[i].len > ERX_FRAME_MAX - total ||
		    (item->iov[i].len > 0 && item->iov[i].base == NULL))
			return (false);
		total += item->iov[i].len;
	}
	if (item->reserve > writer->size - LANE_GRAIN)
		return (false);
	if (writer->phase == ERX_LANE_IN_BODY) {
		if (total != writer->len || item->kind != writer->kind ||
		    item->zero != writer->zero)
			return (false);
	} else if (__builtin_add_overflow(writer->pos,
	    LANE_GRAIN + lane_grain_up(total), &end)) {
		return (false);
	}
	*len = (uint32_t)total;
	return (true);
}

/*
 * The rpos at which the room past the reserve holds the record's rest
 * bytes or a quarter of the area, whichever is less (or all the area
 * past the reserve): need = pos + reserve + wanted - size, 0 when that
 * is not positive, since every rpos then gives the room.
 */
static uint64_t
lane_need(uint64_t pos, uint64_t size, uint64_t reserve, uint64_t rest)
{
	uint64_t wanted;

	wanted = lane_min(reserve + lane_min(rest, size / 4), size);
	return (pos > size - wanted ? pos - (size - wanted) : 0);
}

/*
 * Publishes the wpos that the writer's pos now holds, when it moved past
 * the one published before this put, and returns whether that store
 * crossed the wake the consumer published, so the caller rings the
 * consumer's bell.
 */
static bool
lane_publish(const erx_lane_writer_t *writer, uint64_t published)
{
	uint64_t wake;

	if (writer->pos == published)
		return (false);

	/*
	 * Release: pairs with the consumer's acquire load of wpos, so every
	 * byte written below wpos is visible to its copies.
	 */
	erx_lane_hdr_wpos_store(lane_writer_header(writer), writer->pos);

	/*
	 * Orders the store of wpos before the load of wake, against the
	 * consumer's store of wake, full fence and load of wpos: one of the
	 * two loads sees the other side's store, so no wait is lost.
	 */
	atomic_thread_fence(memory_order_seq_cst);
	erx_lane_rpage_wake_load(lane_writer_rpage(writer), &wake);
	return (lane_crossed(published, writer->pos, wake));
}

/* Adds one put's part to the parts summed before it, first, when any. */
static void
lane_put_sum(erx_lane_put_t *sum, const erx_lane_put_t *part, bool first)
{
	if (first)
		sum->offset = part->offset;
	sum->written += part->written;
	sum->opened = sum->opened || part->opened;
	sum->closed = part->closed;
	sum->ring = sum->ring || part->ring;
}

/* The bytes the writer must still place for the record of body len. */
static uint64_t
lane_rest(const erx_lane_writer_t *writer, uint32_t len)
{
	if (writer->phase == ERX_LANE_IN_BODY)
		return (lane_grain_up(writer->body_left));
	return (LANE_GRAIN + lane_grain_up(len));
}

static erx_lane_put_status_t
lane_writer_refuse(erx_lane_writer_t *writer, erx_lane_fault_t fault)
{
	writer->phase = ERX_LANE_REFUSED;
	writer->fault = fault;
	return (ERX_LANE_PUT_MALFORMED);
}

static erx_lane_hdr_t *
lane_writer_header(const erx_lane_writer_t *writer)
{
	return ((erx_lane_hdr_t *)writer->own_side);
}

static const erx_lane_rpage_t *
lane_writer_rpage(const erx_lane_writer_t *writer)
{
	return ((const erx_lane_rpage_t *)(writer->peer_side +
	    ERX_LANE_SIDE_RPAGE));
}

/*
 * Writes n bytes from src into the data area at position pos, wrapping at
 * the area's end.  The room it writes is the writer's alone: below the
 * sound rpos plus the size and at or past wpos, so the consumer loads none
 * of it until a later store of wpos publishes it.
 */
static void
lane_write(const erx_lane_writer_t *writer, uint64_t pos,
    const unsigned char *src, uint64_t n)
{
	unsigned char *area;
	uint64_t first, offset;

	if (n == 0)
		return;
	area = writer->own_side + ERX_LANE_SIDE_DATA;
	offset = pos & (writer->size - 1);
	first = lane_min(n, writer->size - offset);
	memcpy(area + offset, src, first);
	if (n > first)
		memcpy(area, src + first, n - first);
}

/* A record header as the wire layout erx_lane_rec places it: little-endian. */
static void
lane_write_header(const erx_lane_writer_t *writer, uint32_t len,
    uint32_t kind, uint64_t zero)
{
	unsigned char header[ERX_LANE_REC_SIZE] = { 0 };

	for (unsigned i = 0; i < sizeof(len); i++) {
		header[ERX_LANE_REC_OFF_LEN + i] = (unsigned char)(len >> (8 * i));
		header[ERX_LANE_REC_OFF_KIND + i] =
		    (unsigned char)(kind >> (8 * i));
	}
	for (unsigned i = 0; i < sizeof(zero); i++)
		header[ERX_LANE_REC_OFF_ZERO + i] =
		    (unsigned char)(zero >> (8 * i));
	lane_write(writer, writer->pos, header, sizeof(header));
}

bool
erx_lane_writer_init(erx_lane_writer_t *writer, void *own_side,
    const void *peer_side, uint64_t size)
{
	if (writer == NULL || !lane_sides_sound(own_side, peer_side, size))
		return (false);

	*writer = (erx_lane_writer_t){
		.own_side = own_side,
		.peer_side = peer_side,
		.size = size,
		.phase = ERX_LANE_BETWEEN
	};
	return (true);
}

erx_lane_put_status_t
erx_lane_put(erx_lane_writer_t *writer, const erx_lane_item_t *item,
    erx_lane_put_t *put)
{
	static const unsigned char zeros[LANE_GRAIN];
	uint64_t copied, n, published, room, rpos;
	erx_lane_fault_t fault;
	uint32_t len;

	*put = (erx_lane_put_t){ 0 };
	if (writer->phase == ERX_LANE_REFUSED)
		return (ERX_LANE_PUT_MALFORMED);
	if (!lane_item_len(writer, item, &len))
		return (ERX_LANE_PUT_REFUSED);

	/*
	 * Acquire: pairs with the consumer's release store of rpos, so its
	 * copies of the room below rpos are done before the writes below.
	 */
	erx_lane_rpage_rpos_load(lane_writer_rpage(writer), &rpos);
	fault = lane_check_rpos(writer->pos, writer->rpos, rpos);
	if (fault != ERX_LANE_SOUND)
		return (lane_writer_refuse(writer, fault));
	writer->rpos = rpos;

	room = lane_room_past(writer->size, writer->pos - rpos,
	    lane_grain_up(item->reserve));
	published = writer->pos;
	if (writer->phase == ERX_LANE_BETWEEN) {
		if (room < LANE_GRAIN)
			return (ERX_LANE_PUT_SHORT);
		lane_write_header(writer, len, item->kind, item->zero);
		writer->pos += LANE_GRAIN;
		room -= LANE_GRAIN;
		writer->len = len;
		writer->kind = item->kind;
		writer->zero = item->zero;
		writer->body_left = len;
		writer->phase = ERX_LANE_IN_BODY;
		put->opened = true;
	}

	/*
	 * room is whole grains, so n is either the body's padded rest, which
	 * closes the record, or whole grains of body short of its end.
	 */
	n = lane_min(lane_grain_up(writer->body_left), room);
	copied = lane_min(n, writer->body_left);
	put->offset = writer->len - writer->body_left;
	lane_gather(writer, item, put->offset, writer->pos, copied);
	lane_write(writer, writer->pos + copied, zeros, n - copied);
	writer->pos += n;
	writer->body_left -= copied;
	put->written = (size_t)copied;
	if (writer->body_left == 0) {
		writer->phase = ERX_LANE_BETWEEN;
		put->closed = true;
	}
	put->ring = lane_publish(writer, published);
	return (put->closed ? ERX_LANE_PUT_DONE : ERX_LANE_PUT_SHORT);
}

erx_lane_put_status_t
erx_lane_put_armed(erx_lane_writer_t *writer, const erx_lane_item_t *item,
    erx_lane_put_t *put)
{
	erx_lane_put_status_t st;
	erx_lane_put_t part;
	uint32_t len;

	*put = (erx_lane_put_t){ 0 };
	for (bool first = true;; first = false) {
		if (writer->phase == ERX_LANE_REFUSED)
			return (ERX_LANE_PUT_MALFORMED);
		if (!lane_item_len(writer, item, &len))
			return (ERX_LANE_PUT_REFUSED);

		/*
		 * Release, then a full fence: orders the store of need before
		 * the load of rpos in erx_lane_put, against the consumer's
		 * release store of rpos, full fence and load of need, so either
		 * that put sees the new rpos or the consumer sees this need and
		 * rings.
		 */
		erx_lane_hdr_need_store(lane_writer_header(writer),
		    lane_need(writer->pos, writer->size,
		    lane_grain_up(item->reserve), lane_rest(writer, len)));
		atomic_thread_fence(memory_order_seq_cst);
		st = erx_lane_put(writer, item, &part);
		lane_put_sum(put, &part, first);

		/*
		 * A put that wrote something moved wpos past the position need
		 * was computed from, and the consumer may have crossed that need
		 * already: publish the need of the new wpos and look again.
		 */
		if (st != ERX_LANE_PUT_SHORT || (part.written == 0 && !part.opened))
			return (st);
	}
}
