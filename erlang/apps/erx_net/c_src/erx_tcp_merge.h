/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_TCP_MERGE_H
#define ERX_TCP_MERGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The merge of received TCP segments, the core of erx_bytes:tcp_merge/1
 * (docs/design-network-fastpath.md, "The merge"): FreeBSD's large receive offload rule
 * (tcp_lro_rx_common and tcp_lro_condense, tcp_lro.c) over one batch of Ethernet frames. It
 * decides only which frames belong together; it writes no header and copies no byte, and every
 * value TCP acts on is decoded again by Erlang from the frames themselves.
 *
 * The limit of one call: at most ERX_TCP_MERGE_FRAMES_MAX frames, the frames before the last
 * holding fewer than ERX_TCP_MERGE_BYTES_MAX bytes in all, and no frame more than
 * ERX_TCP_MERGE_BYTES_MAX bytes. So a call reads at most twice ERX_TCP_MERGE_BYTES_MAX bytes and
 * runs on a normal scheduler. erx_bytes:tcp_merge_limit/0 answers the first two constants, and
 * erx_net_driver cuts every batch of its transport to them.
 */
#define ERX_TCP_MERGE_FRAMES_MAX	256u
#define ERX_TCP_MERGE_BYTES_MAX		65536u

/* TCP_LRO_LENGTH_MAX (tcp_lro.h): a unit holds less payload, so it fits one IP packet. */
#define ERX_TCP_MERGE_UNIT_MAX		65280u
/* TCP_LRO_ENTRIES (tcp_lro.h): the units open at once, one per connection. */
#define ERX_TCP_MERGE_OPEN_MAX		8u

/* The bytes of a frame before its network sum's: the Ethernet II header. */
#define ERX_TCP_MERGE_LINK_HDR		14u

/* One frame of a batch as the transport handed it. */
typedef struct erx_tcp_merge_in {
	const uint8_t *data;
	size_t length;
	bool has_sum;		/* sum is the copy's network sum of the frame */
	uint16_t sum;
} erx_tcp_merge_in_t;

/*
 * What the merge decided for one frame. unit is the index of the frame that its unit starts
 * with, the frame's own index when it starts one; a frame on its own starts a unit of one. sum
 * is the frame's network sum, the one it came with or the one the merge computed: the RFC 1071
 * sum, folded and not complemented, of its bytes after the Ethernet header, 0 for a frame
 * without them. payload and payload_length place the TCP payload of a member of a unit of
 * several in the frame; both are 0 for a frame on its own. For a unit's first frame, members
 * counts the unit's frames, itself included, and last is the index of its last; members is 0
 * for every other frame.
 */
typedef struct erx_tcp_merge_out {
	uint16_t unit;
	uint16_t members;
	uint16_t last;
	uint16_t sum;
	uint32_t payload;
	uint32_t payload_length;
} erx_tcp_merge_out_t;

typedef enum erx_tcp_merge_status {
	ERX_TCP_MERGE_OK,
	ERX_TCP_MERGE_BADARG	/* the batch is past the limit; out is untouched */
} erx_tcp_merge_status_t;

/* Whether count frames of in are within the limit; it reads only their lengths. */
bool erx_tcp_merge_within_limit(const erx_tcp_merge_in_t *in, size_t count);

/*
 * The merge of count frames of in into out, one entry each, in order. Pure: it reads only the
 * frames' bytes, which must not change during the call, and writes only out. A unit's members
 * are in order of arrival, and a unit starts where its first frame stood, so the units in
 * order of their first frames keep every connection's segments in the order they came.
 */
erx_tcp_merge_status_t erx_tcp_merge(const erx_tcp_merge_in_t *in, size_t count,
    erx_tcp_merge_out_t *out);

/*
 * The bytes a call over in reads, for its charge in reductions: every byte of a frame it sums,
 * and for every frame the headers it reads, counted as ERX_TCP_MERGE_READ bytes.
 */
#define ERX_TCP_MERGE_READ	128u

static inline size_t
erx_tcp_merge_bytes_read(const erx_tcp_merge_in_t *in, size_t count)
{
	size_t bytes = 0, i;

	for (i = 0; i < count; i++)
		bytes += ERX_TCP_MERGE_READ + (in[i].has_sum ? 0 : in[i].length);
	return (bytes);
}

#endif
