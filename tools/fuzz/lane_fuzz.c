/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The lane reader over a hostile producer.  The input is a script: one
 * byte of setup (bit 0: an 8 KiB area instead of 4 KiB; bit 1: start the
 * lane just below the last position), then operations, each an opcode
 * byte and its operands:
 *
 *   0  wpos = any 8-byte value
 *   1  wpos = the published rpos plus 16 times a 2-byte count
 *   2  a data-area word = an 8-byte value, at a 2-byte word index
 *   3  a record header with a 4-byte len at the reader's next grain
 *   4  need = any 8-byte value
 *   5  take with a 2-byte max
 *   6  armed take with a 2-byte max
 *   7  stop: the reader fixes wpos at what it loads, and every later take
 *      is judged against that copy
 *
 * The harness writes the producer's side only through atomic stores and
 * keeps a plain copy of the area, so after every take it can check that
 * the reader copied exactly the bytes at the positions it claims, never
 * passed the wpos it was shown, published rpos as pos rounded down to 16
 * and only forward, and that a refusal is final.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/lane.h"

#define FUZZ_AREA_MAX	8192
#define FUZZ_BUF	65536

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static _Alignas(ERX_PAGE_SIZE) unsigned char
    peer_side[ERX_LANE_SIDE_DATA + FUZZ_AREA_MAX];
static _Alignas(ERX_PAGE_SIZE) unsigned char own_side[ERX_LANE_SIDE_DATA];
static unsigned char shadow[FUZZ_AREA_MAX];
static unsigned char buf[FUZZ_BUF];

typedef struct script script_t;
struct script {
	const uint8_t	*bytes;
	size_t		 length;
	size_t		 at;
};

static bool
script_take(script_t *s, size_t n, uint64_t *value)
{
	*value = 0;
	if (s->length - s->at < n)
		return (false);
	for (size_t i = 0; i < n; i++)
		*value |= (uint64_t)s->bytes[s->at + i] << (8 * i);
	s->at += n;
	return (true);
}

static _Atomic uint64_t *
area_word(uint64_t index)
{
	return ((_Atomic uint64_t *)(peer_side + ERX_LANE_SIDE_DATA) + index);
}

static void
area_store(uint64_t size, uint64_t pos, uint64_t value)
{
	uint64_t index = (pos & (size - 1)) / 8;

	memcpy(shadow + index * 8, &value, 8);
	atomic_store_explicit(area_word(index), value, memory_order_relaxed);
}

static void
check(bool condition)
{
	if (!condition)
		abort();
}

/* Judges one take against the shadow and the values the harness wrote. */
static void
judge(const erx_lane_reader_t *reader, erx_lane_status_t st,
    const erx_lane_part_t *part, uint64_t before, uint64_t wpos,
    uint64_t *last_rpos, size_t max, bool *refused)
{
	erx_lane_rpage_t *rpage;
	uint64_t rpos, start;

	rpage = (erx_lane_rpage_t *)(own_side + ERX_LANE_SIDE_RPAGE);
	check(st == ERX_LANE_TOOK || st == ERX_LANE_EMPTY ||
	    st == ERX_LANE_MALFORMED);
	check(!*refused || st == ERX_LANE_MALFORMED);
	if (st == ERX_LANE_MALFORMED) {
		check(reader->phase == ERX_LANE_REFUSED &&
		    reader->fault != ERX_LANE_SOUND);
		*refused = true;
		return;
	}
	if (st == ERX_LANE_EMPTY) {
		check(reader->pos == before && wpos == before);
		return;
	}
	check(part->copied <= max && reader->pos <= wpos);
	/* Every part moves pos, but a body part with no room in the buffer. */
	check(reader->pos > before ||
	    (max == 0 && !part->opened && !part->closed));
	check(part->offset + part->copied <= part->len);
	check(!part->closed || part->offset + part->copied == part->len);
	start = part->opened ? before + ERX_LANE_REC_SIZE : before;
	if (part->opened) {
		uint32_t len = 0;

		for (int i = 0; i < 4; i++)
			len |= (uint32_t)shadow[(before + i) & (reader->size - 1)] <<
			    (8 * i);
		check(part->len == len);
	}
	for (size_t i = 0; i < part->copied; i++)
		check(buf[i] == shadow[(start + i) & (reader->size - 1)]);
	erx_lane_rpage_rpos_load(rpage, &rpos);
	if (rpos != *last_rpos)
		check(rpos == (reader->pos & ~UINT64_C(15)) && rpos > *last_rpos);
	check(rpos == (reader->pos & ~UINT64_C(15)));
	*last_rpos = rpos;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_lane_hdr_t *header = (erx_lane_hdr_t *)peer_side;
	erx_lane_rpage_t *rpage;
	script_t s = { .bytes = data, .length = size, .at = 0 };
	erx_lane_reader_t reader;
	erx_lane_part_t part;
	erx_lane_status_t st;
	uint64_t area, base, before, last_rpos, op, value, wake, word, wpos;
	uint64_t stop_wpos = 0;
	bool refused = false, stopped = false;

	if (!script_take(&s, 1, &value))
		return (0);
	area = (value & 1) != 0 ? FUZZ_AREA_MAX : ERX_LANE_MIN;
	base = (value & 2) != 0 ? UINT64_MAX - 15 - 2 * area : 0;
	memset(peer_side, 0, sizeof(peer_side));
	memset(own_side, 0, sizeof(own_side));
	memset(shadow, 0, sizeof(shadow));
	rpage = (erx_lane_rpage_t *)(own_side + ERX_LANE_SIDE_RPAGE);
	check(erx_lane_reader_init(&reader, peer_side, own_side, area));
	/* A lane that starts high: as if base bytes had passed. */
	reader.pos = base;
	erx_lane_rpage_rpos_store(rpage, base);
	erx_lane_hdr_wpos_store(header, base);
	wpos = base;
	last_rpos = base;

	while (script_take(&s, 1, &op)) {
		switch (op % 8) {
		case 0:
			if (!script_take(&s, 8, &wpos))
				return (0);
			erx_lane_hdr_wpos_store(header, wpos);
			break;
		case 1:
			if (!script_take(&s, 2, &value))
				return (0);
			wpos = last_rpos + 16 * value;
			erx_lane_hdr_wpos_store(header, wpos);
			break;
		case 2:
			if (!script_take(&s, 2, &op) || !script_take(&s, 8, &word))
				return (0);
			area_store(area, op * 8, word);
			break;
		case 3:
			if (!script_take(&s, 4, &value))
				return (0);
			area_store(area, reader.pos, value);
			area_store(area, reader.pos + 8, 0);
			break;
		case 4:
			if (!script_take(&s, 8, &value))
				return (0);
			erx_lane_hdr_need_store(header, value);
			break;
		case 7:
			if (erx_lane_reader_stop(&reader)) {
				check(!refused);
				if (!stopped)
					stop_wpos = wpos;
				stopped = true;
			} else {
				check(reader.phase == ERX_LANE_REFUSED);
				refused = true;
			}
			break;
		default:
			if (!script_take(&s, 2, &value))
				return (0);
			before = reader.pos;
			if (op % 8 == 5) {
				st = erx_lane_take(&reader, buf, (size_t)value, &part);
			} else {
				st = erx_lane_take_armed(&reader, buf, (size_t)value,
				    &part);
				erx_lane_rpage_wake_load(rpage, &wake);
				check(refused || wake == (before & ~UINT64_C(15)) + 1);
			}
			judge(&reader, st, &part, before,
			    stopped ? stop_wpos : wpos, &last_rpos, (size_t)value,
			    &refused);
			break;
		}
	}
	return (0);
}
