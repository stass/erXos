/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_TCP_CUT_H
#define ERX_TCP_CUT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The cut of a run into its frames (docs/design-network-fastpath.md, "The cut, in the copy"):
 * the C twin of erx_net_frame:cut/1, which judges it. A run is consecutive TCP segments of one
 * connection over one template, the IP and TCP headers its frames share. Frame i of a run of
 * k frames whose payload holds P bytes carries the payload bytes from i * seg to
 * min(P, (i + 1) * seg), the sequence number seq + i * seg modulo 2^32, and the run's flags,
 * without PSH and FIN on every frame but the last. A run without payload is one frame.
 *
 * erx_tcp_cut_plan is the one function that reads a run's shape, which comes from Erlang and
 * is checked here, once; the others index only memory an accepted plan has bounded.
 */

/*
 * The pieces a run's payload may lie in. A run of more is refused; output makes none, since
 * it ends a run where erx_tcp_sndbuf:range/4 ends it (erx_tcp_output's RUN_PIECES).
 */
#define ERX_TCP_CUT_PIECES_MAX	64u
/* The longest link header in front of a frame: Ethernet's 14 bytes, with room to spare. */
#define ERX_TCP_CUT_LINK_MAX	32u
/* IP_MAXPACKET (FreeBSD's ip.h): a run with its IP and TCP headers fits one IP packet. */
#define ERX_TCP_CUT_PACKET_MAX	65535u
/* The longest headers of a frame: the link header, IPv6, and TCP with the timestamps. */
#define ERX_TCP_CUT_HEADER_MAX	(ERX_TCP_CUT_LINK_MAX + 40u + 32u)

/* One piece of a payload, where it lies. */
typedef struct erx_tcp_cut_piece {
	const uint8_t *data;
	size_t length;
} erx_tcp_cut_piece_t;

/* A run as its transport was handed it: the fields of erx_net_frame.hrl's #run{}. */
typedef struct erx_tcp_run {
	const uint8_t *link;
	size_t link_length;
	const uint8_t *headers;		/* the template: the IP and TCP headers */
	size_t headers_length;
	uint32_t seq;
	uint32_t ack;
	uint32_t flags;			/* the last frame's, 12 bits */
	uint32_t win;			/* 16 bits */
	bool has_ts;
	uint32_t tsval;
	uint32_t tsecr;
	uint32_t seg;			/* the payload bytes of each frame but the last */
	const erx_tcp_cut_piece_t *pieces;
	size_t npieces;
} erx_tcp_run_t;

/*
 * A checked run and what every frame of it shares. It points at the run, which must outlive
 * it unchanged.
 */
typedef struct erx_tcp_cut_plan {
	const erx_tcp_run_t *run;
	size_t ip_length;		/* 20 for IPv4, 40 for IPv6 */
	size_t tcp_length;		/* 20, or 32 with the timestamps */
	size_t header_length;		/* the link header, IP and TCP */
	size_t payload_length;		/* P, the payload's bytes */
	uint32_t frames;		/* k, at least 1 */
	uint16_t address_sum;		/* the sum of the template's two addresses */
} erx_tcp_cut_plan_t;

/*
 * Checks a run and plans its frames into plan. Returns true, or false with plan untouched when
 * the link header is longer than ERX_TCP_CUT_LINK_MAX, the template is not one
 * erx_net_frame:template/2 makes, the timestamps' presence differs from the template's, a
 * field is wider than the wire's, the segment size is zero, the payload has more than
 * ERX_TCP_CUT_PIECES_MAX pieces or a piece without bytes to point at, or the run with its IP
 * and TCP headers exceeds ERX_TCP_CUT_PACKET_MAX. A template the stack makes is IPv4 with a
 * 20-byte header, protocol 6, don't-fragment, offset 0 and identification 0, or IPv6 with
 * next header 6; then TCP with a data offset of 5, or of 8 with NOP NOP TS 10 at its first
 * option byte; and nothing after the TCP header.
 */
bool	erx_tcp_cut_plan(const erx_tcp_run_t *run, erx_tcp_cut_plan_t *plan);

/* The length of frame i of a plan, headers included; 0 when there is no frame i. */
size_t	erx_tcp_cut_length(const erx_tcp_cut_plan_t *plan, uint32_t i);

/*
 * Writes frame i of a plan to dst, which has room bytes: the link header, the template with the
 * plan's values stored, the payload slice copied through erx_inet_copy_sum, the IPv4 header
 * checksum and the TCP checksum. Returns the frame's length, or 0, writing nothing, when there
 * is no frame i or room is shorter than the frame.
 */
size_t	erx_tcp_cut_frame(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room);

/*
 * As erx_tcp_cut_frame, for a medium whose copy is the kernel's: writes only the headers to
 * dst, summing the payload slice where it lies (erx_inet_sum), so the caller hands the kernel
 * the headers and the slice that erx_tcp_cut_slice gives. Returns the headers' length, or 0,
 * writing nothing, when there is no frame i or room is shorter than the headers.
 */
size_t	erx_tcp_cut_header(const erx_tcp_cut_plan_t *plan, uint32_t i, uint8_t *dst, size_t room);

/*
 * The payload slice of frame i as at most ERX_TCP_CUT_PIECES_MAX pieces in out, which has room
 * for that many, in order and without empty pieces. Returns how many: 0 for a frame without
 * payload or when there is no frame i.
 */
size_t	erx_tcp_cut_slice(const erx_tcp_cut_plan_t *plan, uint32_t i, erx_tcp_cut_piece_t *out);

#endif
