/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>

#include "erx_tcp_cut.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * The input builds one run for erx_tcp_cut_plan. Its first HEAD bytes:
 *   d[0] bit 0: IPv6; bit 1: the template carries the timestamps; bit 2: the run's timestamps
 *        differ from the template's; bit 3: the template is d[1] bytes of the input after the
 *        head, taken as they are; bits 4-5: the template spoiled (none, byte d[1] % its length
 *        xored with d[2] | 1, its last d[1] % 8 + 1 bytes dropped, d[1] % 4 + 1 zero bytes
 *        added); bit 6: the link header is d[2] % 40 bytes rather than 14; bit 7: a field out
 *        of range, d[3] % 5 choosing which (flags, window, a NULL piece with bytes, a NULL link
 *        with a length, more than 64 pieces);
 *   d[4..7] seq, d[8..11] ack, d[12..13] flags (12 bits kept), d[14..15] the window,
 *   d[16..19] TSval, d[20..23] TSecr, d[24..25] the segment size, d[26..27] the payload's
 *        length, d[28] the number of pieces, d[29] the template's type of service and d[30]
 *        its hop limit, d[31] a seed for the addresses and ports;
 * then, after the raw template when there is one, two bytes for each cut of the payload into
 * pieces, the cut at their value modulo the length plus one, so pieces may be empty.
 * The payload's bytes are a pattern of its length and offset, so a short input makes a long run.
 *
 * The oracle is its own reading of the run, sharing nothing with the core: it decides whether
 * the plan must accept the run, then re-derives every frame from the input, its length, the
 * link header, the template's bytes, the IP length, the sequence number, the flags, the
 * timestamps, the payload slice and both checksums, summed a byte at a time; and the header
 * that erx_tcp_cut_header writes followed by erx_tcp_cut_slice's pieces must be that frame.
 * Every buffer the core reads or writes is allocated to its exact length, so the address
 * sanitizer sees a byte past it.
 */
#define HEAD		32
#define LINK		14
#define PIECES		80

/* The field d[0] bit 7 puts out of range, chosen by d[3] % 5. */
enum wide {
	WIDE_NONE,
	WIDE_FLAGS,
	WIDE_WINDOW,
	WIDE_NULL_PIECE,
	WIDE_NULL_LINK,
	WIDE_PIECES
};

/* How d[0] bits 4-5 spoil the template. */
enum spoil {
	SPOIL_NONE,
	SPOIL_BYTE,
	SPOIL_SHORT,
	SPOIL_LONG
};

static erx_tcp_cut_piece_t pieces[PIECES];
static uint8_t *piece_copies[PIECES];
static size_t cut_at[PIECES];
static erx_tcp_cut_piece_t spare[ERX_TCP_CUT_PIECES_MAX];
static uint8_t payload[ERX_TCP_CUT_PACKET_MAX + 1];

static uint32_t
get16(const uint8_t *p)
{

	return ((uint32_t)p[0] << 8 | p[1]);
}

static uint32_t
get32(const uint8_t *p)
{

	return (get16(p) << 16 | get16(p + 2));
}

/* The sum of RFC 1071 a byte at a time, continued from total at an even position. */
static uint32_t
bytewise(uint32_t total, const uint8_t *data, size_t length)
{
	size_t i;

	for (i = 0; i < length; i++) {
		total += i % 2 == 0 ? (uint32_t)data[i] << 8 : data[i];
		total = (total & 0xffffu) + (total >> 16);
	}
	return (total);
}

static void
check(bool ok)
{

	if (!ok)
		abort();
}

static int
compare_size(const void *a, const void *b)
{
	size_t x = *(const size_t *)a, y = *(const size_t *)b;

	return (x < y ? -1 : x > y);
}

/* The template the stack makes for d, at t, which has room for 72 bytes; returns its length. */
static size_t
build_template(uint8_t *t, const uint8_t *d)
{
	bool six = (d[0] & 1u) != 0, ts = (d[0] & 2u) != 0;
	size_t ip = six ? 40 : 20, i;
	uint8_t *th;

	bzero(t, 72);
	if (six) {
		t[0] = (uint8_t)(0x60u | d[29] >> 4);
		t[1] = (uint8_t)(d[29] << 4 | (d[31] & 0xfu));
		t[6] = 6;
		t[7] = d[30];
		for (i = 0; i < 32; i++)
			t[8 + i] = (uint8_t)(d[31] + i * 37);
	} else {
		t[0] = 0x45;
		t[1] = d[29];
		t[6] = 0x40;
		t[8] = d[30];
		t[9] = 6;
		for (i = 0; i < 8; i++)
			t[12 + i] = (uint8_t)(d[31] + i * 37);
	}
	th = t + ip;
	th[0] = d[31];
	th[1] = 1;
	th[2] = (uint8_t)~d[31];
	th[3] = 2;
	th[12] = ts ? 0x80 : 0x50;
	if (ts) {
		th[20] = 1;
		th[21] = 1;
		th[22] = 8;
		th[23] = 10;
	}
	return (ip + (ts ? 32 : 20));
}

/* The oracle's own reading of a template: its IP and TCP lengths, or false for a bad one. */
static bool
read_template(const uint8_t *t, size_t length, bool has_ts, size_t *ip, size_t *tcp)
{

	if (length >= 40 && t[0] == 0x45 && t[9] == 6 && get16(t + 4) == 0 && get16(t + 6) == 0x4000)
		*ip = 20;
	else if (length >= 60 && t[0] >> 4 == 6 && t[6] == 6)
		*ip = 40;
	else
		return (false);
	if (t[*ip + 12] >> 4 == 5 && !has_ts)
		*tcp = 20;
	else if (t[*ip + 12] >> 4 == 8 && has_ts && length >= *ip + 32 &&
	    get32(t + *ip + 20) == 0x0101080au)
		*tcp = 32;
	else
		return (false);
	return (length == *ip + *tcp);
}

/* Checks frame i of a run the plan accepted against the oracle's own derivation of it. */
static void
check_frame(const erx_tcp_cut_plan_t *plan, const erx_tcp_run_t *run, size_t ip, size_t tcp,
    size_t total, uint32_t frames, uint32_t i)
{
	erx_tcp_cut_piece_t slice[ERX_TCP_CUT_PIECES_MAX];
	size_t link = run->link_length, off = (size_t)i * run->seg, take, length, n, p, at;
	uint32_t flags, sum;
	uint8_t *frame, *header, *th;

	take = total - off < run->seg ? total - off : run->seg;
	length = link + ip + tcp + take;
	check(erx_tcp_cut_length(plan, i) == length);
	frame = malloc(length);
	header = malloc(link + ip + tcp);
	check(frame != NULL && header != NULL);
	check(erx_tcp_cut_frame(plan, i, frame, length - 1) == 0);
	check(erx_tcp_cut_frame(plan, i, frame, length) == length);

	check(link == 0 || bcmp(frame, run->link, link) == 0);
	th = frame + link + ip;
	if (ip == 20) {
		check(bcmp(frame + link, run->headers, 2) == 0 && get16(frame + link + 2) == ip + tcp + take);
		check(bcmp(frame + link + 4, run->headers + 4, 6) == 0);
		check(bcmp(frame + link + 12, run->headers + 12, 8) == 0);
		check(bytewise(0, frame + link, 20) == 0xffffu);
		sum = bytewise(0, frame + link + 12, 8);
	} else {
		check(bcmp(frame + link, run->headers, 4) == 0 && get16(frame + link + 4) == tcp + take);
		check(bcmp(frame + link + 6, run->headers + 6, 34) == 0);
		sum = bytewise(0, frame + link + 8, 32);
	}
	flags = i + 1 == frames ? run->flags : run->flags & ~0x009u;
	check(bcmp(th, run->headers + ip, 4) == 0);
	check(get32(th + 4) == (uint32_t)(run->seq + (uint64_t)i * run->seg));
	check(get32(th + 8) == run->ack);
	check(th[12] >> 4 == tcp / 4 && ((uint32_t)(th[12] & 0xfu) << 8 | th[13]) == flags);
	check(get16(th + 14) == run->win && get16(th + 18) == 0);
	if (tcp == 32)
		check(get32(th + 20) == 0x0101080au && get32(th + 24) == run->tsval &&
		    get32(th + 28) == run->tsecr);
	check(take == 0 || bcmp(th + tcp, payload + off, take) == 0);
	sum = bytewise(sum, (const uint8_t[]){ 0, 6 }, 2);
	sum += (uint32_t)(tcp + take);
	sum = (sum & 0xffffu) + (sum >> 16);
	check(bytewise(sum, th, tcp + take) == 0xffffu);

	/* The header and the slice, as the tap hands them to writev, are the same frame. */
	check(erx_tcp_cut_header(plan, i, header, link + ip + tcp - 1) == 0);
	check(erx_tcp_cut_header(plan, i, header, link + ip + tcp) == link + ip + tcp);
	check(bcmp(header, frame, link + ip + tcp) == 0);
	n = erx_tcp_cut_slice(plan, i, slice);
	check(n <= ERX_TCP_CUT_PIECES_MAX);
	for (p = 0, at = link + ip + tcp; p < n; at += slice[p].length, p++)
		check(slice[p].length > 0 && at + slice[p].length <= length &&
		    bcmp(slice[p].data, frame + at, slice[p].length) == 0);
	check(at == length);
	free(header);
	free(frame);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t built[72], *template, *link;
	const uint8_t *raw, *cuts;
	erx_tcp_cut_plan_t plan;
	erx_tcp_run_t run;
	size_t template_length, link_length, total, npieces, ncuts, ip, tcp, i, from;
	uint32_t frames, f;
	enum spoil spoil;
	enum wide wide;
	bool accept, has_ts;

	if (size < HEAD)
		return (0);
	raw = data + HEAD;
	if ((data[0] & 8u) != 0) {
		template_length = data[1] < size - HEAD ? data[1] : size - HEAD;
		bcopy(raw, built, template_length < 72 ? template_length : 72);
		template_length = template_length < 72 ? template_length : 72;
		cuts = raw + template_length;
	} else {
		template_length = build_template(built, data);
		cuts = raw;
	}
	spoil = (enum spoil)(data[0] >> 4 & 3u);
	if (spoil == SPOIL_BYTE && template_length > 0)
		built[data[1] % template_length] ^= (uint8_t)(data[2] | 1u);
	else if (spoil == SPOIL_SHORT)
		template_length -= template_length < data[1] % 8u + 1 ? template_length : data[1] % 8u + 1;
	else if (spoil == SPOIL_LONG && template_length + data[1] % 4u + 1 <= 72)
		template_length += data[1] % 4u + 1;
	link_length = (data[0] & 0x40u) != 0 ? data[2] % 40u : LINK;
	has_ts = ((data[0] & 2u) != 0) != ((data[0] & 4u) != 0);
	wide = (data[0] & 0x80u) != 0 ? (enum wide)(data[3] % 5u + 1) : WIDE_NONE;

	/* The payload in pieces, each in an allocation of its own exact length. */
	total = get16(data + 26);
	npieces = data[28] % PIECES;
	if (wide == WIDE_PIECES)
		npieces = ERX_TCP_CUT_PIECES_MAX + 1;
	if (npieces == 0)
		total = 0;
	for (i = 0; i < total; i++)
		payload[i] = (uint8_t)(i * 7 + (i >> 8) + total);
	ncuts = npieces > 0 ? npieces - 1 : 0;
	for (i = 0; i < ncuts; i++) {
		from = (size_t)(cuts - data) + 2 * i;
		cut_at[i] = from + 2 <= size ? get16(data + from) % (total + 1) : total;
	}
	qsort(cut_at, ncuts, sizeof(cut_at[0]), compare_size);
	for (i = 0; i < npieces; i++) {
		from = i == 0 ? 0 : cut_at[i - 1];
		pieces[i].length = (i == ncuts ? total : cut_at[i]) - from;
		piece_copies[i] = malloc(pieces[i].length > 0 ? pieces[i].length : 1);
		check(piece_copies[i] != NULL);
		bcopy(payload + from, piece_copies[i], pieces[i].length);
		pieces[i].data = piece_copies[i];
	}
	if (wide == WIDE_NULL_PIECE && npieces > 0 && pieces[0].length > 0)
		pieces[0].data = NULL;
	else if (wide == WIDE_NULL_PIECE || (wide == WIDE_NULL_LINK && link_length == 0))
		wide = WIDE_NONE;

	template = malloc(template_length > 0 ? template_length : 1);
	link = malloc(link_length > 0 ? link_length : 1);
	check(template != NULL && link != NULL);
	bcopy(built, template, template_length);
	for (i = 0; i < link_length; i++)
		link[i] = (uint8_t)(0xa0u + i);
	run = (erx_tcp_run_t){
		.link = wide == WIDE_NULL_LINK && link_length > 0 ? NULL : link,
		.link_length = link_length,
		.headers = template,
		.headers_length = template_length,
		.seq = get32(data + 4),
		.ack = get32(data + 8),
		.flags = (get16(data + 12) & 0xfffu) | (wide == WIDE_FLAGS ? 0x1000u : 0),
		.win = get16(data + 14) | (wide == WIDE_WINDOW ? 0x10000u : 0),
		.has_ts = has_ts,
		.tsval = get32(data + 16),
		.tsecr = get32(data + 20),
		.seg = get16(data + 24),
		.pieces = pieces,
		.npieces = npieces,
	};

	accept = wide == WIDE_NONE && link_length <= ERX_TCP_CUT_LINK_MAX && run.seg > 0 &&
	    npieces <= ERX_TCP_CUT_PIECES_MAX &&
	    read_template(template, template_length, has_ts, &ip, &tcp) &&
	    total + ip + tcp <= ERX_TCP_CUT_PACKET_MAX;
	check(erx_tcp_cut_plan(&run, &plan) == accept);
	if (accept) {
		frames = total == 0 ? 1 : (uint32_t)((total + run.seg - 1) / run.seg);
		check(plan.frames == frames);
		for (f = 0; f < frames; f++)
			check_frame(&plan, &run, ip, tcp, total, frames, f);
		check(erx_tcp_cut_length(&plan, frames) == 0);
		check(erx_tcp_cut_slice(&plan, frames, spare) == 0);
	}
	for (i = 0; i < npieces; i++)
		free(piece_copies[i]);
	free(template);
	free(link);
	return (0);
}
