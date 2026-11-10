/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>

#include "erx_tcp_merge.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * The input builds one batch for erx_tcp_merge. Its first byte chooses the batch's shape: bit
 * 0 past the frame limit, bit 1 past the byte limit, the rest of the input then ignored but
 * for the count. Each later six bytes describe a frame:
 *   d[0] bits 0-1: the connection (0 and 1 differ only in their ports and share one sequence
 *        space, 2 has other addresses, 3 is IPv6); bit 2: another type of service; bit 3: the
 *        frame is d[1] bytes of the input taken as they are; bits 4-5: no sum, a wrong one, or
 *        the right one; bit 6: padded to 60 bytes; bit 7: other TCP options.
 *   d[1]: the payload's length in 8-byte steps, 0 for none, 255 for 8,960 bytes;
 *   d[2]: the sequence number's skip, 0 for in order;
 *   d[3]: the acknowledgement's step, which may go back;
 *   d[4]: the TCP flags (low 6 bits: ACK below 40, ACK and PSH below 50, d[3] as flags above)
 *        and the timestamp's step (top 2 bits, ts_steps);
 *   d[5]: bit 0 spoils the IP checksum, bit 1 the TCP checksum, bit 2 drops the timestamps.
 * The oracle checks every unit: each frame in exactly one, in order; each frame's sum the one
 * it came with or that of its bytes; and the members of a unit of several candidates whose
 * checksums are right by their sums, of one connection and flow, contiguous in sequence, their
 * acknowledgements not going back, their payloads where the merge placed them and within the
 * unit's limit. Its reading of a frame is its own and shares nothing with the core's.
 */
#define DESCRIPTOR	6
#define ARENA		(2 * ERX_TCP_MERGE_BYTES_MAX + 2 * ERX_TCP_MERGE_FRAMES_MAX * 64)
#define LINK		14

static uint8_t arena[ARENA];
/* The timestamp's steps d[4]'s top bits choose: the same, on by one or two, back by one. */
static const int8_t ts_steps[4] = { 0, 1, 2, -1 };
static erx_tcp_merge_in_t in[ERX_TCP_MERGE_FRAMES_MAX + 1];
static erx_tcp_merge_out_t out[ERX_TCP_MERGE_FRAMES_MAX + 1];

typedef struct connection {
	uint32_t seq, ack, tsval;
} connection_t;

/* The sum of RFC 1071 a byte at a time, from even position start. */
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
put16(uint8_t *p, uint32_t v)
{

	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void
put32(uint8_t *p, uint32_t v)
{

	put16(p, v >> 16);
	put16(p + 2, v);
}

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

/* The pseudo-header's total for a TCP segment of length bytes. */
static uint32_t
pseudo(bool six, const uint8_t *addresses, size_t length)
{
	uint32_t total = bytewise(0, addresses, six ? 32 : 8);

	total = bytewise(total, (const uint8_t[]){ 0, 6 }, 2);
	total += (uint32_t)(length >> 16) + (uint32_t)(length & 0xffffu);
	return ((total & 0xffffu) + (total >> 16));
}

/* Builds the frame d describes at p, returning its length. */
static size_t
build(uint8_t *p, const uint8_t *d, connection_t *conns)
{
	unsigned which = d[0] & 3u, flags_choice = d[4] & 0x3fu;
	bool six = which == 3, ts = (d[5] & 4u) == 0, other = (d[0] & 0x80u) != 0;
	connection_t *conn = &conns[which == 1 ? 0 : which];
	size_t payload = d[1] == 255 ? 8960 : (size_t)d[1] * 8, ip = LINK, header = six ? 40 : 20;
	size_t opts = ts || other ? 12 : 0, tcp = ip + header, length, i;
	uint32_t flags, csum;

	bcopy((const uint8_t[]){ 2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2 }, p, 12);
	put16(p + 12, six ? 0x86ddu : 0x0800u);
	conn->seq += d[2];
	conn->ack += (uint32_t)(int8_t)d[3];
	conn->tsval += (uint32_t)(int32_t)ts_steps[d[4] >> 6];
	flags = flags_choice < 40 ? 0x010u : flags_choice < 50 ? 0x018u : (uint32_t)d[3] << 4 & 0xfffu;
	length = 20 + opts + payload;
	if (six) {
		put32(p + ip, 0x60000000u | ((d[0] & 4u) != 0 ? 0x00400000u : 0));
		put16(p + ip + 4, (uint32_t)length);
		p[ip + 6] = 6;
		p[ip + 7] = 64;
		for (i = 0; i < 32; i++)
			p[ip + 8 + i] = (uint8_t)(i == 15 ? 1 : i == 31 ? 2 : 0);
	} else {
		bzero(p + ip, 20);
		p[ip] = 0x45;
		p[ip + 1] = (d[0] & 4u) != 0 ? 3 : 0;
		put16(p + ip + 2, (uint32_t)(20 + length));
		p[ip + 6] = 0x40;
		p[ip + 8] = 64;
		p[ip + 9] = 6;
		bcopy((const uint8_t[]){ 10, 0, 0, which == 2 ? 3 : 1, 10, 0, 0, 2 }, p + ip + 12, 8);
		csum = ~bytewise(0, p + ip, 20) & 0xffffu;
		put16(p + ip + 10, csum ^ (d[5] & 1u));
	}
	put16(p + tcp, 1000 + which);
	put16(p + tcp + 2, 80);
	put32(p + tcp + 4, conn->seq);
	put32(p + tcp + 8, conn->ack);
	put16(p + tcp + 12, (uint32_t)(5 + opts / 4) << 12 | flags);
	put16(p + tcp + 14, 65535);
	put32(p + tcp + 16, 0);
	if (opts > 0) {
		put32(p + tcp + 20, other ? 0x01010402u : 0x0101080au);
		put32(p + tcp + 24, conn->tsval);
		put32(p + tcp + 28, 5);
	}
	for (i = 0; i < payload; i++)
		p[tcp + 20 + opts + i] = (uint8_t)(i * 31 + d[1]);
	csum = ~bytewise(pseudo(six, p + ip + (six ? 8 : 12), length), p + tcp, length) & 0xffffu;
	put16(p + tcp + 16, csum ^ (d[5] & 2u));
	conn->seq += (uint32_t)payload;
	length += tcp;
	if ((d[0] & 0x40u) != 0 && length < 60) {
		bzero(p + length, 60 - length);
		length = 60;
	}
	return (length);
}

/* The network sum of a frame by its bytes. */
static uint16_t
network(const uint8_t *frame, size_t length)
{

	return (length <= LINK ? 0 : (uint16_t)bytewise(0, frame + LINK, length - LINK));
}

/*
 * The oracle's reading of a member of a unit of several, which must be a candidate: its
 * sequence and acknowledgement numbers and its payload's place, when its checksums are right
 * by sum, the sum it was merged with. A sum is believed: the TCP checksum's total over the
 * bytes, plus sum less the bytes' own network sum, must be zero.
 */
typedef struct member {
	uint32_t seq, ack;
	size_t payload, payload_length;
} member_t;

static bool
read_member(const uint8_t *f, size_t length, uint16_t sum, member_t *m)
{
	bool six;
	size_t header, total, room, off;
	uint32_t flags, verdict;

	if (length < LINK + 40)
		return (false);
	six = get16(f + 12) == 0x86ddu;
	if (!six && get16(f + 12) != 0x0800u)
		return (false);
	room = length - LINK;
	if (six) {
		header = 40;
		total = 40 + get16(f + LINK + 4);
		if ((f[LINK] >> 4) != 6 || f[LINK + 6] != 6 || total != room)
			return (false);
	} else {
		header = 20;
		total = get16(f + LINK + 2);
		if (f[LINK] != 0x45 || f[LINK + 9] != 6 || (get16(f + LINK + 6) & 0x3fffu) != 0 ||
		    total > room || total < 40 || (total < room && length != 60))
			return (false);
		if (bytewise(0, f + LINK, 20) % 0xffffu != 0)
			return (false);
	}
	verdict = bytewise(pseudo(six, f + LINK + (six ? 8 : 12), total - header), f + LINK + header,
	    total - header);
	verdict = (verdict + sum + 0xffffu - network(f, length)) % 0xffffu;
	if (verdict != 0)
		return (false);
	off = (size_t)(f[LINK + header + 12] >> 4) * 4;
	flags = get16(f + LINK + header + 12) & 0xfffu;
	if ((flags != 0x010u && flags != 0x018u) || off > total - header ||
	    (off != 20 && !(off == 32 && get32(f + LINK + header + 20) == 0x0101080au)))
		return (false);
	m->seq = get32(f + LINK + header + 4);
	m->ack = get32(f + LINK + header + 8);
	m->payload = LINK + header + off;
	m->payload_length = total - header - off;
	return (true);
}

/* The same connection and flow: everything but the IP header's checksum, length and ID, TTL
 * and the TCP fields that vary, the link addresses, the type of service and the ports. */
static bool
same_flow(const uint8_t *a, const uint8_t *b)
{
	bool six = get16(a + 12) == 0x86ddu;
	size_t tcp = LINK + (six ? 40 : 20);

	if (bcmp(a, b, 14) != 0 || bcmp(a + tcp, b + tcp, 4) != 0 || a[tcp + 12] >> 4 != b[tcp + 12] >> 4)
		return (false);
	if (six)
		return (bcmp(a + LINK, b + LINK, 4) == 0 && bcmp(a + LINK + 8, b + LINK + 8, 32) == 0);
	return (a[LINK + 1] == b[LINK + 1] && bcmp(a + LINK + 12, b + LINK + 12, 8) == 0);
}

static void
check(size_t count)
{
	member_t m, prev = { 0, 0, 0, 0 };
	size_t i, j, first, bytes;
	bool several;

	for (i = 0; i < count; i++) {
		first = out[i].unit;
		if (first > i || out[first].unit != first)
			abort();
		if (out[i].sum != (in[i].has_sum ? in[i].sum : network(in[i].data, in[i].length)))
			abort();
		if (first != i)
			continue;
		several = false;
		for (j = i + 1; j < count; j++)
			several = several || out[j].unit == i;
		if (!several) {
			if (out[i].payload != 0 || out[i].payload_length != 0)
				abort();
			continue;
		}
		bytes = 0;
		for (j = i; j < count; j++) {
			if (out[j].unit != i)
				continue;
			if (!read_member(in[j].data, in[j].length, out[j].sum, &m) ||
			    !same_flow(in[i].data, in[j].data) || m.payload != out[j].payload ||
			    m.payload_length != out[j].payload_length)
				abort();
			if (j != i && (m.seq != prev.seq + (uint32_t)prev.payload_length ||
			    (uint32_t)(m.ack - prev.ack) >= 0x80000000u))
				abort();
			bytes += m.payload_length;
			prev = m;
		}
		if (bytes > ERX_TCP_MERGE_UNIT_MAX)
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	connection_t conns[4] = { { 0xfffff000u, 7, 100 }, { 0, 0, 0 }, { 0xfffff000u, 7, 100 },
	    { 0xfffff000u, 7, 100 } };
	size_t count, used, before, length, i;
	const uint8_t *d;
	uint8_t *copy;
	unsigned shape;
	erx_tcp_merge_status_t status;
	uint16_t sum;

	if (size < 1)
		return (0);
	count = used = before = 0;
	if ((data[0] & 3u) != 0) {
		/* Past the limit: one frame too many, or 64 KiB before the last. */
		count = (data[0] & 1u) != 0 ? ERX_TCP_MERGE_FRAMES_MAX + 1 : 2;
		for (i = 0; i < count; i++)
			in[i] = (erx_tcp_merge_in_t){ .data = arena,
			    .length = (data[0] & 1u) != 0 ? 60 : ERX_TCP_MERGE_BYTES_MAX };
		if (erx_tcp_merge(in, count, out) != ERX_TCP_MERGE_BADARG)
			abort();
		return (0);
	}
	for (d = data + 1; d + DESCRIPTOR <= data + size && count < ERX_TCP_MERGE_FRAMES_MAX;
	    d += DESCRIPTOR) {
		shape = d[0];
		if ((shape & 8u) != 0) {
			length = d[1];
			if (d + DESCRIPTOR + length > data + size)
				break;
			bcopy(d + DESCRIPTOR, arena + used, length);
			d += length;
		} else {
			length = build(arena + used, d, conns);
		}
		/*
		 * Each frame the merge reads is a block of exactly its length, so a read past its end is
		 * an AddressSanitizer report, not a read of the next frame.
		 */
		copy = malloc(length > 0 ? length : 1);
		if (copy == NULL)
			break;
		bcopy(arena + used, copy, length);
		sum = network(copy, length);
		in[count] = (erx_tcp_merge_in_t){ .data = copy, .length = length,
		    .has_sum = (shape & 0x30u) != 0, .sum = (shape & 0x30u) == 0x10u ? sum ^ 1u : sum };
		before += length;
		used += length;
		count++;
		if (before >= ERX_TCP_MERGE_BYTES_MAX)
			break;
	}
	status = erx_tcp_merge(in, count, out);
	if (status != ERX_TCP_MERGE_OK)
		abort();
	check(count);
	for (i = 0; i < count; i++)
		free((void *)(uintptr_t)in[i].data);
	return (0);
}
