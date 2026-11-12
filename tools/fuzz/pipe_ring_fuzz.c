/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The consumer's check of a pipe's ring (liberx/erx_pipe_check.c) over a
 * hostile writer.  The input is a size selector, rpos and wpos, then the
 * bytes of the data area, which hold whatever record header sits at rpos.
 * The harness copies the header out of the area through erx_shm_copy, as a
 * read end does, checks it, and on a sound record copies the record whole:
 * every accept must satisfy the bounds docs/design-pipes.md states, and the
 * copy must stay inside the area.
 */

#include <stdalign.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/pipe.h"
#include "erx/shm.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static unsigned char payload[ERX_PIPE_BUF];

static uint64_t
take_u64(const uint8_t **data, size_t *size)
{
	uint64_t value = 0;
	size_t i;

	for (i = 0; i < 8 && *size > 0; i++, (*data)++, (*size)--)
		value |= (uint64_t)**data << (8 * i);
	return (value);
}

static void
check(int held)
{
	if (!held)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	_Atomic uint64_t *area;
	erx_ring_copy_t copy;
	erx_ring_fault_t fault;
	unsigned char header[ERX_LANE_REC_SIZE];
	erx_lane_rec_t rec;
	uint64_t ring_size, avail;
	uint64_t grain = ERX_LANE_REC_SIZE;
	uint32_t len, kind;
	int sound;

	if (size < 1)
		return (0);
	/* One grain to the first ring's 65,536, every power of two between. */
	ring_size = grain << (data[0] % 13);
	data++;
	size--;
	copy.rpos = take_u64(&data, &size);
	copy.wpos = take_u64(&data, &size);
	/* Exactly the ring's size, so a read past it is one ASan sees. */
	area = calloc(1, ring_size);
	if (area == NULL)
		return (0);
	memcpy((void *)area, data, size < ring_size ? size : ring_size);

	erx_shm_copy(area, ring_size, copy.rpos, header, sizeof(header));
	if (!erx_lane_rec_decode(header, sizeof(header), &rec)) {
		free(area);
		return (0);
	}
	len = rec.len;
	kind = rec.kind;
	copy.len = len;
	copy.kind = kind;
	fault = erx_ring_check(ring_size, &copy);

	/* The design's bullets, written out again: sound exactly when they hold. */
	avail = copy.wpos - copy.rpos;
	sound = copy.rpos % grain == 0 && copy.wpos % grain == 0 &&
	    copy.rpos <= copy.wpos && avail <= ring_size;
	if (sound && avail > 0)
		sound = ((kind == ERX_REC_DATA && len >= 1 && len <= ERX_PIPE_BUF) ||
		    (kind == ERX_REC_CONTROL && len >= ERX_PIPE_TICKET &&
		    len <= ERX_PIPE_CONTROL_MAX && len % ERX_PIPE_TICKET == 0)) &&
		    grain + ((uint64_t)len + grain - 1) / grain * grain <= avail;
	check(sound == (fault == ERX_RING_SOUND));
	if (!sound || avail == 0) {
		free(area);
		return (0);
	}
	check(erx_ring_span(len) <= avail && erx_ring_span(len) <= ring_size);
	/* The reader copies the payload whole, from past the header. */
	erx_shm_copy(area, ring_size, copy.rpos + grain, payload, len);
	free(area);
	return (0);
}
