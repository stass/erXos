/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The cut of a run into its frames (erx_tcp_cut.h; docs/design-network-fastpath.md, "The cut,
 * in the copy"). erx_tcp_cut_plan is the only function that reads a run's untrusted shape:
 * every length, count and field width is checked there, once, before anything is written.
 * The others index only what a plan it accepted has bounded. Each frame is written in one
 * pass: the payload slice summed as it is copied (or where it lies), then the link header and
 * the template, the fields the cut stores, and last the two checksums, which cover what was
 * written. The tap NIF links this file, and its fuzz target builds it for the host.
 */

/* memcpy rather than bcopy: ERTS imports only ISO C's (otp/erts/emulator/sys/erxos/imports.txt). */
#include <string.h>

#include "erx_inet_csum.h"
#include "erx_tcp_cut.h"

#define IPPROTO_TCP		6u
#define IP_DF			0x4000u
#define IP_HDR			20u
#define IP6_HDR			40u
#define TCP_HDR			20u
#define TCP_TS_HDR		32u
#define TH_FIN			0x001u
#define TH_PUSH			0x008u
/* NOP NOP TS 10, the timestamps option as FreeBSD lays it out (tcp_output.c:1794). */
#define TS_LAYOUT		0x0101080au

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

static void
put16(uint8_t *p, uint32_t v)
{

	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void
put32(uint8_t *p, uint32_t v)
{

	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

/* The one's-complement sum of a and b, folded to 16 bits; b < 2^31. */
static uint16_t
sum_add(uint16_t a, uint32_t b)
{
	uint32_t total;

	total = a + b;
	while (total > 0xffffu)
		total = (total & 0xffffu) + (total >> 16);
	return ((uint16_t)total);
}

/*
 * The template's IP header length, or 0 when it is not an IP header a template carries or
 * the template is too short to hold it and a TCP header after it.
 */
static size_t
template_ip(const erx_tcp_run_t *run)
{
	const uint8_t *t;

	t = run->headers;
	if (run->headers_length < IP_HDR + TCP_HDR)
		return (0);
	switch (t[0] >> 4) {
	case 4:
		if (t[0] != 0x45u || t[9] != IPPROTO_TCP || be16(t + 4) != 0 || be16(t + 6) != IP_DF)
			return (0);
		return (IP_HDR);
	case 6:
		if (run->headers_length < IP6_HDR + TCP_HDR || t[6] != IPPROTO_TCP)
			return (0);
		return (IP6_HDR);
	default:
		return (0);
	}
}

/*
 * The template's TCP header length after ip bytes of IP header, which hold a TCP header's
 * fixed part after them, or 0 when its options are not a run's or differ from has_ts.
 */
static size_t
template_tcp(const erx_tcp_run_t *run, size_t ip)
{
	const uint8_t *t;

	t = run->headers + ip;
	switch (t[12] >> 4) {
	case TCP_HDR / 4:
		return (run->has_ts ? 0 : TCP_HDR);
	case TCP_TS_HDR / 4:
		if (!run->has_ts || run->headers_length < ip + TCP_TS_HDR ||
		    be32(t + TCP_HDR) != TS_LAYOUT)
			return (0);
		return (TCP_TS_HDR);
	default:
		return (0);
	}
}

/* The payload's bytes, or more than ERX_TCP_CUT_PACKET_MAX when a piece is malformed. */
static size_t
payload_length(const erx_tcp_run_t *run)
{
	size_t i, total;

	total = 0;
	for (i = 0; i < run->npieces; i++) {
		if (run->pieces[i].data == NULL && run->pieces[i].length > 0)
			return (ERX_TCP_CUT_PACKET_MAX + 1);
		if (run->pieces[i].length > ERX_TCP_CUT_PACKET_MAX - total)
			return (ERX_TCP_CUT_PACKET_MAX + 1);
		total += run->pieces[i].length;
	}
	return (total);
}

bool
erx_tcp_cut_plan(const erx_tcp_run_t *run, erx_tcp_cut_plan_t *plan)
{
	size_t ip, tcp, payload;

	if (run->link_length > ERX_TCP_CUT_LINK_MAX || (run->link == NULL && run->link_length > 0))
		return (false);
	if (run->headers == NULL)
		return (false);
	if (run->flags > 0xfffu || run->win > 0xffffu || run->seg == 0)
		return (false);
	if (run->npieces > ERX_TCP_CUT_PIECES_MAX || (run->pieces == NULL && run->npieces > 0))
		return (false);
	if ((ip = template_ip(run)) == 0 || (tcp = template_tcp(run, ip)) == 0)
		return (false);
	if (run->headers_length != ip + tcp)
		return (false);
	payload = payload_length(run);
	if (payload > ERX_TCP_CUT_PACKET_MAX - ip - tcp)
		return (false);
	*plan = (erx_tcp_cut_plan_t){
		.run = run,
		.ip_length = ip,
		.tcp_length = tcp,
		.header_length = run->link_length + ip + tcp,
		.payload_length = payload,
		.frames = payload == 0 ? 1 : (uint32_t)(payload / run->seg + (payload % run->seg != 0)),
		.address_sum = ip == IP_HDR ? erx_inet_sum(0, run->headers + 12, 8, 0) :
		    erx_inet_sum(0, run->headers + 8, 32, 0),
	};
	return (true);
}

/* The payload offset of frame i < plan->frames: below the payload's length, or 0. */
static size_t
slice_offset(const erx_tcp_cut_plan_t *plan, uint32_t i)
{

	return ((size_t)i * plan->run->seg);
}

/* The payload length of frame i < plan->frames: seg, the rest for the last, 0 for none. */
static size_t
slice_length(const erx_tcp_cut_plan_t *plan, uint32_t i)
{
	size_t left;

	left = plan->payload_length - slice_offset(plan, i);
	return (left < plan->run->seg ? left : plan->run->seg);
}

size_t
erx_tcp_cut_length(const erx_tcp_cut_plan_t *plan, uint32_t i)
{

	if (i >= plan->frames)
		return (0);
	return (plan->header_length + slice_length(plan, i));
}

size_t
erx_tcp_cut_slice(const erx_tcp_cut_plan_t *plan, uint32_t i, erx_tcp_cut_piece_t *out)
{
	const erx_tcp_run_t *run;
	size_t skip, want, n, p, take;

	if (i >= plan->frames)
		return (0);
	run = plan->run;
	skip = slice_offset(plan, i);
	want = slice_length(plan, i);
	n = 0;
	for (p = 0; p < run->npieces && want > 0; p++) {
		if (skip >= run->pieces[p].length) {
			skip -= run->pieces[p].length;
			continue;
		}
		take = run->pieces[p].length - skip;
		if (take > want)
			take = want;
		out[n].data = run->pieces[p].data + skip;
		out[n].length = take;
		n++;
		want -= take;
		skip = 0;
	}
	return (n);
}

/*
 * Writes frame i's link header and headers to dst, for a payload slice of length bytes whose
 * sum, taken from an even offset, is payload_sum: the template, the IP length and the IPv4
 * header checksum over it, the TCP fields the cut stores, and the TCP checksum over the
 * pseudo-header, the TCP header and the slice.
 */
static void
write_headers(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t length,
    uint16_t payload_sum)
{
	const erx_tcp_run_t *run;
	uint8_t *ip, *th;
	uint32_t flags, tcp_length;
	uint16_t sum;

	run = plan->run;
	if (run->link_length > 0)
		memcpy(dst, run->link, run->link_length);
	ip = dst + run->link_length;
	memcpy(ip, run->headers, run->headers_length);
	tcp_length = (uint32_t)(plan->tcp_length + length);
	if (plan->ip_length == IP_HDR) {
		put16(ip + 2, IP_HDR + tcp_length);
		put16(ip + 10, 0);
		put16(ip + 10, (uint16_t)~erx_inet_sum(0, ip, IP_HDR, 0));
	} else {
		put16(ip + 4, tcp_length);
	}
	th = ip + plan->ip_length;
	flags = i + 1 == plan->frames ? run->flags : run->flags & ~(uint32_t)(TH_PUSH | TH_FIN);
	put32(th + 4, run->seq + i * run->seg);
	put32(th + 8, run->ack);
	th[12] = (uint8_t)((plan->tcp_length / 4) << 4 | flags >> 8);
	th[13] = (uint8_t)flags;
	put16(th + 14, run->win);
	put16(th + 16, 0);
	put16(th + 18, 0);
	if (run->has_ts) {
		put32(th + 24, run->tsval);
		put32(th + 28, run->tsecr);
	}
	sum = sum_add(plan->address_sum, IPPROTO_TCP + tcp_length);
	sum = sum_add(sum, erx_inet_sum(0, th, plan->tcp_length, 0));
	sum = sum_add(sum, payload_sum);
	put16(th + 16, (uint16_t)~sum);
}

size_t
erx_tcp_cut_frame(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room)
{
	erx_tcp_cut_piece_t pieces[ERX_TCP_CUT_PIECES_MAX];
	size_t length, n, p, at;
	uint16_t sum;

	length = erx_tcp_cut_length(plan, i);
	if (length == 0 || room < length)
		return (0);
	n = erx_tcp_cut_slice(plan, i, pieces);
	sum = 0;
	at = 0;
	for (p = 0; p < n; p++) {
		sum = erx_inet_copy_sum(sum, dst + plan->header_length + at, pieces[p].data,
		    pieces[p].length, at);
		at += pieces[p].length;
	}
	write_headers(plan, i, dst, at, sum);
	return (length);
}

size_t
erx_tcp_cut_header(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room)
{
	erx_tcp_cut_piece_t pieces[ERX_TCP_CUT_PIECES_MAX];
	size_t n, p, at;
	uint16_t sum;

	if (i >= plan->frames || room < plan->header_length)
		return (0);
	n = erx_tcp_cut_slice(plan, i, pieces);
	sum = 0;
	at = 0;
	for (p = 0; p < n; p++) {
		sum = erx_inet_sum(sum, pieces[p].data, pieces[p].length, at);
		at += pieces[p].length;
	}
	write_headers(plan, i, dst, at, sum);
	return (plan->header_length);
}
