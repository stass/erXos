/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The lane writer over a hostile consumer.  The input is a script: one
 * byte of setup (bit 0: an 8 KiB area instead of 4 KiB; bit 1: start the
 * lane just below the last position), then operations, each an opcode
 * byte and its operands:
 *
 *   0  rpos = any 8-byte value
 *   1  rpos = the last rpos the writer accepted plus 16 times a 2-byte count
 *   2  wake = any 8-byte value
 *   3  put, with a 2-byte length, a 1-byte cut and a 2-byte reserve
 *   4  armed put, with the same operands
 *
 * A put continues the open record whatever length it is given, so the
 * harness puts another body only when the length it reads differs, and
 * then expects a refusal.  After every put it checks that the writer wrote
 * exactly the record's bytes in the window between the wpos it had and
 * the wpos it published, changed nothing else, kept the unread bytes
 * within the area and the room past the reserve, rang exactly when its
 * store crossed wake, published the need the handshake asks for, and that
 * a refusal is final.
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
#define FUZZ_BODY_MAX	65536

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static _Alignas(ERX_PAGE_SIZE) unsigned char
    own_side[ERX_LANE_SIDE_DATA + FUZZ_AREA_MAX];
static _Alignas(ERX_PAGE_SIZE) unsigned char peer_side[ERX_LANE_SIDE_DATA];
static unsigned char before[FUZZ_AREA_MAX];
static unsigned char body[FUZZ_BODY_MAX];

typedef struct script script_t;
struct script {
	const uint8_t	*bytes;
	size_t		 length;
	size_t		 at;
};

/* The record the harness is putting, and where its header sits. */
typedef struct record record_t;
struct record {
	uint64_t	 at;
	uint64_t	 index;
	uint32_t	 len;
	bool		 open;
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

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static uint64_t
grain_up(uint64_t value)
{
	return ((value + 15) & ~UINT64_C(15));
}

static unsigned char
body_byte(uint64_t index, uint64_t offset)
{
	return ((unsigned char)(index * 29 + offset * 13 + 3));
}

/* The byte at offset o of the record's header and padded body. */
static unsigned char
record_byte(const record_t *r, uint64_t o)
{
	if (o < 4)
		return ((unsigned char)(r->len >> (8 * o)));
	if (o < 8)
		return ((unsigned char)((r->index + 1) >> (8 * (o - 4))));
	if (o < 16)
		return ((unsigned char)(r->index >> (8 * (o - 8))));
	return (o - 16 < r->len ? body_byte(r->index, o - 16) : 0);
}

static unsigned char *
area(void)
{
	return (own_side + ERX_LANE_SIDE_DATA);
}

/* Judges one put against what it was given and what it saw. */
static void
judge(const erx_lane_writer_t *w, erx_lane_put_status_t st,
    const erx_lane_put_t *put, record_t *r, uint64_t pos0, uint64_t rpos,
    uint64_t wake, uint64_t reserve, bool armed, bool *refused)
{
	erx_lane_hdr_t *header = (erx_lane_hdr_t *)own_side;
	uint64_t mask = w->size - 1, need, rest, wanted, wpos;

	check(st >= ERX_LANE_PUT_DONE && st <= ERX_LANE_PUT_MALFORMED);
	check(!*refused || st == ERX_LANE_PUT_MALFORMED);
	erx_lane_hdr_wpos_load(header, &wpos);
	check(wpos == w->pos && w->pos >= pos0 && w->pos % 16 == 0);
	if (st == ERX_LANE_PUT_MALFORMED) {
		check(w->phase == ERX_LANE_REFUSED &&
		    w->fault != ERX_LANE_SOUND && w->pos == pos0);
		*refused = true;
	}
	if (st == ERX_LANE_PUT_REFUSED || st == ERX_LANE_PUT_MALFORMED) {
		check(w->pos == pos0 && put->written == 0 && !put->ring);
		return;
	}
	check(w->rpos == rpos && w->pos - rpos <= w->size);
	if (w->pos > pos0)
		check(w->pos - rpos <= w->size - grain_up(reserve));

	/* The window holds the record's bytes; nothing else changed. */
	for (uint64_t p = pos0; p < w->pos; p++)
		before[p & mask] = record_byte(r, p - r->at);
	check(memcmp(before, area(), w->size) == 0);
	/* An armed put's rounds are contiguous: its ring is one crossing. */
	check(put->ring == (pos0 < wake && wake <= w->pos));
	check(put->closed == (st == ERX_LANE_PUT_DONE));
	if (put->closed) {
		r->open = false;
		r->index++;
	} else if (w->phase == ERX_LANE_IN_BODY) {
		r->open = true;
	}
	if (armed && st == ERX_LANE_PUT_SHORT) {
		erx_lane_hdr_need_load(header, &need);
		rest = w->phase == ERX_LANE_IN_BODY ? grain_up(w->body_left) :
		    16 + grain_up(r->len);
		/* At need the room past the reserve first holds the wait. */
		wanted = rest < w->size / 4 ? rest : w->size / 4;
		if (wanted > w->size - grain_up(reserve))
			wanted = w->size - grain_up(reserve);
		wanted += grain_up(reserve);
		check(need <= w->pos && w->size - (w->pos - need) >= wanted);
		check(need < 16 || w->size - (w->pos - need) - 16 < wanted);
		check(w->rpos < need);
	}
	if (put->closed)
		r->at = w->pos;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_lane_rpage_t *rpage;
	script_t s = { .bytes = data, .length = size, .at = 0 };
	erx_lane_writer_t w;
	erx_lane_iov_t iov[2];
	erx_lane_item_t item = { .iov = iov, .iovcnt = 2 };
	erx_lane_put_t put;
	erx_lane_put_status_t st;
	record_t r = { 0 };
	uint64_t area_size, base, cut, len, op, pos0, reserve, rpos, value, wake;
	bool other, refused = false;

	if (!script_take(&s, 1, &value))
		return (0);
	area_size = (value & 1) != 0 ? FUZZ_AREA_MAX : ERX_LANE_MIN;
	base = (value & 2) != 0 ? UINT64_MAX - 15 - 2 * area_size : 0;
	memset(own_side, 0, sizeof(own_side));
	memset(peer_side, 0, sizeof(peer_side));
	rpage = (erx_lane_rpage_t *)(peer_side + ERX_LANE_SIDE_RPAGE);
	check(erx_lane_writer_init(&w, own_side, peer_side, area_size));
	/* A lane that starts high: as if base bytes had passed. */
	w.pos = w.rpos = base;
	erx_lane_hdr_wpos_store((erx_lane_hdr_t *)own_side, base);
	erx_lane_rpage_rpos_store(rpage, base);
	r.at = base;

	while (script_take(&s, 1, &op)) {
		switch (op % 5) {
		case 0:
			if (!script_take(&s, 8, &value))
				return (0);
			erx_lane_rpage_rpos_store(rpage, value);
			break;
		case 1:
			if (!script_take(&s, 2, &value))
				return (0);
			erx_lane_rpage_rpos_store(rpage, w.rpos + 16 * value);
			break;
		case 2:
			if (!script_take(&s, 8, &value))
				return (0);
			erx_lane_rpage_wake_store(rpage, value);
			break;
		default:
			if (!script_take(&s, 2, &len) || !script_take(&s, 1, &cut) ||
			    !script_take(&s, 2, &reserve))
				return (0);
			other = r.open && len != r.len;
			if (!r.open)
				r.len = (uint32_t)len;
			for (uint64_t o = 0; o < len; o++)
				body[o] = body_byte(other ? r.index + 7 : r.index, o);
			cut = cut < len ? cut : len;
			iov[0] = (erx_lane_iov_t){ body, cut };
			iov[1] = (erx_lane_iov_t){ body + cut, len - cut };
			item.zero = r.index;
			item.kind = (uint32_t)r.index + 1;
			item.reserve = reserve;
			memcpy(before, area(), area_size);
			erx_lane_rpage_rpos_load(rpage, &rpos);
			erx_lane_rpage_wake_load(rpage, &wake);
			pos0 = w.pos;
			st = op % 5 == 3 ? erx_lane_put(&w, &item, &put) :
			    erx_lane_put_armed(&w, &item, &put);
			check(!other || refused || st == ERX_LANE_PUT_REFUSED);
			check(reserve <= area_size - 16 || refused ||
			    st == ERX_LANE_PUT_REFUSED);
			judge(&w, st, &put, &r, pos0, rpos, wake, reserve,
			    op % 5 == 4, &refused);
			break;
		}
	}
	return (0);
}
