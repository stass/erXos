/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The merge of received TCP segments (erx_tcp_merge.h; docs/design-network-fastpath.md, "The
 * merge"), after FreeBSD's tcp_lro_rx_common and tcp_lro_condense (tcp_lro.c). Each frame is
 * first read into a segment_t: a frame that is not TCP over IPv4 or IPv6 directly behind an
 * Ethernet II header is FRAME_OTHER; one whose connection can be read, its addresses and ports,
 * is FRAME_KEYED; and one the rule may merge is FRAME_CANDIDATE. Then a candidate joins the open
 * unit of its connection when joins() says so, and anything else of that connection first
 * closes the unit, so a connection's frames keep their order. Every read is checked against
 * the frame's length before it is made. erXos's ERTS links this file into erx_bytes's BIFs,
 * erx_net's portable library outside erXos links it too, and its fuzz target builds it for the
 * host.
 */

/* memcmp rather than bcmp: ERTS imports only ISO C's (otp/erts/emulator/sys/erxos/imports.txt). */
#include <string.h>

#include "erx_inet_csum.h"
#include "erx_tcp_merge.h"

#define ETHERTYPE_IP		0x0800u
#define ETHERTYPE_IPV6		0x86ddu
#define IPPROTO_TCP		6u
#define IP_MF			0x2000u
#define IP_OFFMASK		0x1fffu
#define IP_HDR			20u
#define IP6_HDR			40u
#define TCP_HDR			20u
#define TH_PUSH			0x008u
#define TH_ACK			0x010u
/* The shortest Ethernet frame without its FCS: an IPv4 packet in fewer bytes is padded to it. */
#define ETHER_MIN		60u
/* The link addresses, destination and source, before the EtherType. */
#define ETHER_ADDRS		12u
/* NOP NOP TS 10, TCP_LRO_TS_OPTION: the timestamps in the only option layout merged. */
#define TS_LAYOUT		0x0101080au
#define TS_OFF			8u

typedef enum frame_kind {
	FRAME_OTHER,		/* no TCP connection can be read from it */
	FRAME_KEYED,		/* a segment of a known connection that is never merged */
	FRAME_CANDIDATE		/* a segment the rule may merge */
} frame_kind_t;

/*
 * What the rule reads of a frame. version, addr, addr_length and tcp place its connection, for
 * a keyed frame and a candidate; the rest is read for a candidate only.
 */
typedef struct segment {
	frame_kind_t kind;
	const uint8_t *frame;
	unsigned version;
	size_t addr;		/* the source address; the destination follows it */
	size_t addr_length;	/* 4 or 16 */
	size_t tcp;		/* the TCP header */
	unsigned off;		/* the TCP data offset, in 32-bit words */
	bool ts;
	uint32_t seq, ack, tsval;
	size_t payload, payload_length;
} segment_t;

/* An open unit: its first frame's segment and what the next member must continue. */
typedef struct unit {
	segment_t first;
	uint16_t index;		/* the first frame's index in the batch */
	uint32_t next_seq, ack, tsval;
	size_t bytes;		/* the payload of its members */
	size_t opened;		/* when it was opened, to close the oldest */
} unit_t;

static uint32_t
be16(const uint8_t *p)
{

	return ((uint32_t)p[0] << 8 | p[1]);
}

static uint32_t
be32(const uint8_t *p)
{

	return ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]);
}

/* One's-complement addition and subtraction of folded sums (RFC 1071). */
static uint16_t
sum_add(uint16_t a, uint32_t b)
{
	uint32_t total = a + b;

	while (total > 0xffffu)
		total = (total & 0xffffu) + (total >> 16);
	return ((uint16_t)total);
}

static uint16_t
sum_sub(uint16_t a, uint16_t b)
{

	return (sum_add(a, 0xffffu - b));
}

/* a is at or after b in sequence space (SEQ_GEQ, also TSTMP_GEQ). */
static bool
seq_geq(uint32_t a, uint32_t b)
{

	return ((uint32_t)(a - b) < 0x80000000u);
}

bool
erx_tcp_merge_within_limit(const erx_tcp_merge_in_t *in, size_t count)
{
	size_t before, i;

	if (count > ERX_TCP_MERGE_FRAMES_MAX)
		return (false);
	before = 0;
	for (i = 0; i < count; i++) {
		if (in[i].length > ERX_TCP_MERGE_BYTES_MAX)
			return (false);
		if (i + 1 < count) {
			before += in[i].length;
			if (before >= ERX_TCP_MERGE_BYTES_MAX)
				return (false);
		}
	}
	return (true);
}

static uint16_t
network_sum(const erx_tcp_merge_in_t *frame)
{

	if (frame->has_sum)
		return (frame->sum);
	if (frame->length <= ERX_TCP_MERGE_LINK_HDR)
		return (0);
	return (erx_inet_sum(0, frame->data + ERX_TCP_MERGE_LINK_HDR,
	    frame->length - ERX_TCP_MERGE_LINK_HDR, 0));
}

/*
 * The TCP header at seg->tcp, of a segment of tcp_length bytes whose checksum has been found
 * right: a candidate when it carries ACK and nothing but ACK and PSH (tcp_lro.c:1006-1014,
 * :1050-1053) and no option or exactly the timestamps in FreeBSD's layout (:996-1005).
 */
static void
parse_tcp(segment_t *seg, size_t tcp_length)
{
	const uint8_t *th = seg->frame + seg->tcp;
	unsigned flags;

	if (tcp_length < TCP_HDR)
		return;
	seg->off = th[12] >> 4;
	flags = (th[12] & 0x0fu) << 8 | th[13];
	if (flags != TH_ACK && flags != (TH_ACK | TH_PUSH))
		return;
	if (seg->off * 4u > tcp_length)
		return;
	if (seg->off == TS_OFF && be32(th + TCP_HDR) == TS_LAYOUT) {
		seg->ts = true;
		seg->tsval = be32(th + TCP_HDR + 4);
	} else if (seg->off != TCP_HDR / 4) {
		return;
	}
	seg->seq = be32(th + 4);
	seg->ack = be32(th + 8);
	seg->payload = seg->tcp + seg->off * 4u;
	seg->payload_length = tcp_length - seg->off * 4u;
	seg->kind = FRAME_CANDIDATE;
}

/*
 * An IPv4 packet in the room bytes after the Ethernet header: keyed when it holds TCP's ports
 * and is no later fragment; a candidate when its header is 20 bytes (tcp_lro.c:276), it is no
 * fragment at all (:279), its total length fits the frame with any bytes after it the padding
 * of a 60-byte frame, and both checksums are right, the TCP one from the network sum less the
 * IP header's and the padding's.
 */
static void
parse_ip4(segment_t *seg, size_t length, uint16_t sum)
{
	const uint8_t *ip = seg->frame + ERX_TCP_MERGE_LINK_HDR;
	size_t room = length - ERX_TCP_MERGE_LINK_HDR, header, total;
	uint32_t frag;
	uint16_t ip_sum, tcp_sum, pseudo;

	if (room < IP_HDR || ip[0] >> 4 != 4 || ip[9] != IPPROTO_TCP)
		return;
	header = (ip[0] & 0x0fu) * 4u;
	frag = be16(ip + 6);
	if (header < IP_HDR || room < header + 4 || (frag & IP_OFFMASK) != 0)
		return;
	seg->kind = FRAME_KEYED;
	seg->version = 4;
	seg->addr = ERX_TCP_MERGE_LINK_HDR + 12;
	seg->addr_length = 4;
	seg->tcp = ERX_TCP_MERGE_LINK_HDR + header;
	total = be16(ip + 2);
	if (header != IP_HDR || (frag & IP_MF) != 0 || total < IP_HDR + TCP_HDR || total > room ||
	    (total < room && length != ETHER_MIN))
		return;
	ip_sum = erx_inet_sum(0, ip, IP_HDR, 0);
	if (ip_sum != 0xffffu)
		return;
	/*
	 * The header's sum is 0xffff, one's-complement zero, so the TCP segment's is the network
	 * sum less the padding's, summed from offset total, whose parity places its first byte.
	 */
	tcp_sum = sum_sub(sum, erx_inet_sum(0, ip + total, room - total, total));
	pseudo = erx_inet_sum(0, ip + 12, 8, 0);
	pseudo = sum_add(pseudo, IPPROTO_TCP + (uint32_t)(total - IP_HDR));
	if (sum_add(tcp_sum, pseudo) != 0xffffu)
		return;
	parse_tcp(seg, total - IP_HDR);
}

/*
 * An IPv6 packet: keyed when TCP's header directly follows the fixed header, so no extension
 * header, and its ports are in the frame; a candidate when its payload length is the rest of
 * the frame and the TCP checksum is right, from the network sum less the fixed header's.
 */
static void
parse_ip6(segment_t *seg, size_t length, uint16_t sum)
{
	const uint8_t *ip = seg->frame + ERX_TCP_MERGE_LINK_HDR;
	size_t room = length - ERX_TCP_MERGE_LINK_HDR, payload;
	uint16_t tcp_sum, pseudo;

	if (room < IP6_HDR + 4 || ip[0] >> 4 != 6 || ip[6] != IPPROTO_TCP)
		return;
	seg->kind = FRAME_KEYED;
	seg->version = 6;
	seg->addr = ERX_TCP_MERGE_LINK_HDR + 8;
	seg->addr_length = 16;
	seg->tcp = ERX_TCP_MERGE_LINK_HDR + IP6_HDR;
	payload = be16(ip + 4);
	if (payload != room - IP6_HDR)
		return;
	tcp_sum = sum_sub(sum, erx_inet_sum(0, ip, IP6_HDR, 0));
	pseudo = erx_inet_sum(0, ip + 8, 32, 0);
	pseudo = sum_add(pseudo, IPPROTO_TCP + (uint32_t)payload);
	if (sum_add(tcp_sum, pseudo) != 0xffffu)
		return;
	parse_tcp(seg, payload);
}

static void
parse(const uint8_t *frame, size_t length, uint16_t sum, segment_t *seg)
{

	*seg = (segment_t){ .kind = FRAME_OTHER, .frame = frame };
	if (length < ERX_TCP_MERGE_LINK_HDR)
		return;
	switch (be16(frame + ETHER_ADDRS)) {
	case ETHERTYPE_IP:
		parse_ip4(seg, length, sum);
		break;
	case ETHERTYPE_IPV6:
		parse_ip6(seg, length, sum);
		break;
	default:
		break;
	}
}

/* The same connection: IP version, addresses and ports. */
static bool
same_connection(const segment_t *a, const segment_t *b)
{

	return (a->version == b->version &&
	    memcmp(a->frame + a->addr, b->frame + b->addr, 2 * a->addr_length) == 0 &&
	    memcmp(a->frame + a->tcp, b->frame + b->tcp, 4) == 0);
}

/*
 * The same flow within the connection: link addresses, header length, and the type-of-service
 * byte, or for IPv6 the traffic class and flow label with the version, so that no CE mark is
 * merged away.
 */
static bool
same_flow(const segment_t *a, const segment_t *b)
{
	const uint8_t *ip_a = a->frame + ERX_TCP_MERGE_LINK_HDR, *ip_b = b->frame + ERX_TCP_MERGE_LINK_HDR;

	if (memcmp(a->frame, b->frame, ETHER_ADDRS) != 0 || a->off != b->off)
		return (false);
	if (a->version == 4)
		return (ip_a[1] == ip_b[1]);
	return (memcmp(ip_a, ip_b, 4) == 0);
}

/*
 * Whether a candidate of u's connection joins u (tcp_lro_condense): the same flow; in order
 * (tcp_lro.c:1065); an acknowledgement at or past the unit's; a pure ACK that does not advance
 * never merged (:1068-1070, :1081-1085), neither joining, when its ACK is the unit's, nor as the
 * first frame, while the unit's ACK is still its own; timestamps not going back (:1054-1063);
 * and the unit's payload below TCP_LRO_LENGTH_MAX (:1032).
 */
static bool
joins(const unit_t *u, const segment_t *seg)
{

	if (!same_flow(&u->first, seg) || seg->seq != u->next_seq || !seq_geq(seg->ack, u->ack))
		return (false);
	if (seg->payload_length == 0 && seg->ack == u->ack)
		return (false);
	if (u->first.payload_length == 0 && seg->ack == u->first.ack)
		return (false);
	if (seg->ts && !seq_geq(seg->tsval, u->tsval))
		return (false);
	return (u->bytes + seg->payload_length < ERX_TCP_MERGE_UNIT_MAX);
}

static unit_t *
find_unit(unit_t *open, size_t count, const segment_t *seg)
{
	size_t i;

	for (i = 0; i < count; i++)
		if (same_connection(&open[i].first, seg))
			return (&open[i]);
	return (NULL);
}

/* Closes u, the last of the open units taking its place. */
static void
close_unit(unit_t *open, size_t *count, unit_t *u)
{

	*u = open[--*count];
}

/* Opens a unit with the candidate at index, closing the oldest when all are open. */
static void
open_unit(unit_t *open, size_t *count, size_t *opened, const segment_t *seg, size_t index)
{
	unit_t *oldest;
	size_t i;

	if (*count == ERX_TCP_MERGE_OPEN_MAX) {
		oldest = &open[0];
		for (i = 1; i < *count; i++)
			if (open[i].opened < oldest->opened)
				oldest = &open[i];
		close_unit(open, count, oldest);
	}
	open[(*count)++] = (unit_t){
		.first = *seg,
		.index = (uint16_t)index,
		.next_seq = seg->seq + (uint32_t)seg->payload_length,
		.ack = seg->ack,
		.tsval = seg->tsval,
		.bytes = seg->payload_length,
		.opened = (*opened)++
	};
}

static void
join_unit(unit_t *u, const segment_t *seg)
{

	u->next_seq += (uint32_t)seg->payload_length;
	u->ack = seg->ack;
	if (seg->ts)
		u->tsval = seg->tsval;
	u->bytes += seg->payload_length;
}

erx_tcp_merge_status_t
erx_tcp_merge(const erx_tcp_merge_in_t *in, size_t count, erx_tcp_merge_out_t *out)
{
	unit_t open[ERX_TCP_MERGE_OPEN_MAX], *u;
	size_t open_count, opened, i;
	segment_t seg;

	if (!erx_tcp_merge_within_limit(in, count))
		return (ERX_TCP_MERGE_BADARG);
	open_count = opened = 0;
	for (i = 0; i < count; i++) {
		out[i] = (erx_tcp_merge_out_t){ .unit = (uint16_t)i, .last = (uint16_t)i,
		    .sum = network_sum(&in[i]) };
		parse(in[i].data, in[i].length, out[i].sum, &seg);
		if (seg.kind == FRAME_CANDIDATE) {
			out[i].payload = (uint32_t)seg.payload;
			out[i].payload_length = (uint32_t)seg.payload_length;
		}
		u = seg.kind == FRAME_OTHER ? NULL : find_unit(open, open_count, &seg);
		if (u != NULL && seg.kind == FRAME_CANDIDATE && joins(u, &seg)) {
			out[i].unit = u->index;
			join_unit(u, &seg);
			continue;
		}
		if (u != NULL)
			close_unit(open, &open_count, u);
		if (seg.kind == FRAME_CANDIDATE)
			open_unit(open, &open_count, &opened, &seg, i);
	}
	for (i = 0; i < count; i++) {
		out[out[i].unit].members++;
		out[out[i].unit].last = (uint16_t)i;
	}
	/* A frame on its own places no payload. */
	for (i = 0; i < count; i++)
		if (out[i].members == 1)
			out[i].payload = out[i].payload_length = 0;
	return (ERX_TCP_MERGE_OK);
}
