/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The pipe's checks of shared fields (liberx/erx_pipe_check.c), the one
 * shared-page copy (erx/shm.h) and the doorbell label (erx/pipe.h), at
 * every boundary docs/design-pipes.md states.  Each failed expectation
 * prints "FAIL <case>"; test/host/pipe_check_test.rb names the case a
 * seeded fault must fail.  The run ends with "pipe_check done" and exits 0
 * only when every case held.
 */

#include <stdalign.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/pipe.h"
#include "erx/shm.h"

static int failures;

static void
expect(const char *name, bool held)
{
	if (!held) {
		printf("FAIL %s\n", name);
		failures++;
	}
}

/* The consumer's check of rpos, wpos and the record header at rpos. */
static erx_ring_fault_t
ring(uint64_t size, uint64_t rpos, uint64_t wpos, uint32_t kind, uint32_t len)
{
	erx_ring_copy_t copy = { .rpos = rpos, .wpos = wpos, .kind = kind,
	    .len = len };

	return (erx_ring_check(size, &copy));
}

static void
ring_positions(void)
{
	const uint64_t size = ERX_PIPE_RING_NEXT;

	expect("ring empty", ring(size, 64, 64, 0, 0) == ERX_RING_SOUND);
	expect("ring wpos behind",
	    ring(size, 64, 48, ERX_REC_DATA, 1) == ERX_RING_BEHIND);
	expect("ring full",
	    ring(size, 64, 64 + size, ERX_REC_DATA, 1) == ERX_RING_SOUND);
	expect("ring wpos ahead",
	    ring(size, 64, 64 + size + 16, ERX_REC_DATA, 1) == ERX_RING_AHEAD);
	expect("ring rpos unaligned",
	    ring(size, 72, 96, ERX_REC_DATA, 1) == ERX_RING_UNALIGNED);
	/* A header at an rpos 8 bytes before the end would straddle it. */
	expect("ring header straddles the end",
	    ring(size, size - 8, size + 48, ERX_REC_DATA, 1) == ERX_RING_UNALIGNED);
	expect("ring rpos unaligned when empty",
	    ring(size, 8, 8, 0, 0) == ERX_RING_UNALIGNED);
	expect("ring wpos unaligned",
	    ring(size, 64, 64 + 40, ERX_REC_DATA, 1) == ERX_RING_UNALIGNED);
	/* Positions never wrap: a wpos past the top reads as behind rpos. */
	expect("ring wpos wrapped", ring(size, UINT64_C(0xfffffffffffffff0), 0,
	    ERX_REC_DATA, 1) == ERX_RING_BEHIND);
	/* A record just below the top is checked as any. */
	expect("ring last record", ring(size, UINT64_C(0xffffffffffffffc0),
	    UINT64_C(0xffffffffffffffe0), ERX_REC_DATA, 1) == ERX_RING_SOUND);
}

static void
ring_records(void)
{
	const uint64_t size = ERX_PIPE_RING_FIRST;

	expect("ring data", ring(size, 0, 32, ERX_REC_DATA, 1) ==
	    ERX_RING_SOUND);
	expect("ring control", ring(size, 0, 32, ERX_REC_CONTROL, 8) ==
	    ERX_RING_SOUND);
	expect("ring frame kind",
	    ring(size, 0, 32, 1, 8) == ERX_RING_KIND);
	expect("ring kind zero",
	    ring(size, 0, 32, 0, 8) == ERX_RING_KIND);
	expect("ring kind past control",
	    ring(size, 0, 32, ERX_REC_CONTROL + 1, 8) == ERX_RING_KIND);
	expect("ring data empty",
	    ring(size, 0, 32, ERX_REC_DATA, 0) == ERX_RING_LENGTH);
	expect("ring data pipe_buf", ring(size, 0, 16 + ERX_PIPE_BUF,
	    ERX_REC_DATA, ERX_PIPE_BUF) == ERX_RING_SOUND);
	expect("ring data past pipe_buf", ring(size, 0, 32 + ERX_PIPE_BUF,
	    ERX_REC_DATA, ERX_PIPE_BUF + 1) == ERX_RING_LENGTH);
	expect("ring control empty",
	    ring(size, 0, 32, ERX_REC_CONTROL, 0) == ERX_RING_LENGTH);
	expect("ring control part ticket",
	    ring(size, 0, 32, ERX_REC_CONTROL, 12) == ERX_RING_LENGTH);
	expect("ring control below max", ring(size, 0, 16 + 128,
	    ERX_REC_CONTROL, 120) == ERX_RING_SOUND);
	expect("ring control max", ring(size, 0, 16 + ERX_PIPE_CONTROL_MAX,
	    ERX_REC_CONTROL, ERX_PIPE_CONTROL_MAX) == ERX_RING_SOUND);
	expect("ring control past max", ring(size, 0,
	    16 + ERX_PIPE_CONTROL_MAX + 16, ERX_REC_CONTROL,
	    ERX_PIPE_CONTROL_MAX + ERX_PIPE_TICKET) == ERX_RING_LENGTH);
	/* A record of 17 bytes takes a header and 32: 48 published. */
	expect("ring record fills what is published",
	    ring(size, 0, 48, ERX_REC_DATA, 17) == ERX_RING_SOUND);
	expect("ring record past wpos",
	    ring(size, 0, 32, ERX_REC_DATA, 17) == ERX_RING_UNPUBLISHED);
	expect("ring header alone",
	    ring(size, 0, 16, ERX_REC_DATA, 1) == ERX_RING_UNPUBLISHED);
	expect("ring span", erx_ring_span(1) == 32 && erx_ring_span(16) == 32 &&
	    erx_ring_span(17) == 48 && erx_ring_span(ERX_PIPE_BUF) ==
	    16 + ERX_PIPE_BUF);
}

/* The producer's check of rpos: a refused rpos is a full ring. */
static void
ring_room(void)
{
	const uint64_t size = ERX_PIPE_RING_NEXT;
	const uint64_t wpos = 3 * size;

	expect("room empty", erx_ring_room(size, wpos, wpos) == size);
	expect("room some", erx_ring_room(size, wpos, wpos - 48) == size - 48);
	expect("room full", erx_ring_room(size, wpos, wpos - size) == 0);
	expect("room rpos behind the area",
	    erx_ring_room(size, wpos, wpos - size - 16) == 0);
	expect("room rpos past wpos", erx_ring_room(size, wpos, wpos + 16) == 0);
	expect("room rpos unaligned", erx_ring_room(size, wpos, wpos - 8) == 0);
	expect("room fresh", erx_ring_room(size, 0, 0) == size);
}

/* The lock page's holder index. */
static void
lock_owner(void)
{
	uint32_t index;

	index = 99;
	expect("owner free", erx_pipe_owner_check(0, &index) ==
	    ERX_PIPE_OWNER_FREE && index == 99);
	expect("owner first", erx_pipe_owner_check(1, &index) ==
	    ERX_PIPE_OWNER_HELD && index == 0);
	expect("owner last", erx_pipe_owner_check(ERX_PIPE_READERS_MAX, &index) ==
	    ERX_PIPE_OWNER_HELD && index == ERX_PIPE_READERS_MAX - 1);
	expect("owner past last",
	    erx_pipe_owner_check(ERX_PIPE_READERS_MAX + 1, &index) ==
	    ERX_PIPE_OWNER_BROKEN);
	expect("owner top", erx_pipe_owner_check(UINT32_MAX, &index) ==
	    ERX_PIPE_OWNER_BROKEN);
}

static erx_pipe_settle_t
settle(uint32_t cur, uint32_t cur_off, uint64_t cur_pos, bool held,
    uint64_t rpos, bool record, uint32_t len)
{
	erx_pipe_cur_copy_t copy = { .cur = cur, .cur_off = cur_off,
	    .cur_pos = cur_pos, .held = held, .rpos = rpos, .record_sound = record,
	    .len = len };

	return (erx_pipe_settle(&copy));
}

/* The settle table's four rows, each at its edges. */
static void
lock_settle(void)
{
	expect("settle continue",
	    settle(2, 0, 64, true, 64, true, 10) == ERX_PIPE_SETTLE_CONTINUE);
	expect("settle continue last byte",
	    settle(2, 9, 64, true, 64, true, 10) == ERX_PIPE_SETTLE_CONTINUE);
	expect("settle retire",
	    settle(2, 10, 64, true, 64, true, 10) == ERX_PIPE_SETTLE_RETIRE);
	expect("settle claimed past the record",
	    settle(2, 11, 64, true, 64, true, 10) == ERX_PIPE_SETTLE_NONE);
	expect("settle finished",
	    settle(2, 3, 64, true, 80, false, 0) == ERX_PIPE_SETTLE_FINISHED);
	expect("settle rpos behind",
	    settle(2, 3, 64, true, 48, true, 10) == ERX_PIPE_SETTLE_NONE);
	expect("settle lane not held",
	    settle(2, 3, 64, false, 64, true, 10) == ERX_PIPE_SETTLE_NONE);
	expect("settle no record",
	    settle(2, 3, 64, true, 64, false, 10) == ERX_PIPE_SETTLE_NONE);
	expect("settle none named", settle(ERX_PIPE_NONE, 3, 64, true, 64, true,
	    10) == ERX_PIPE_SETTLE_NONE);
	expect("settle fresh page",
	    settle(0, 0, 0, true, 0, true, 10) == ERX_PIPE_SETTLE_NONE);
}

/* The copy wraps at the area's end and loads only what it is asked for. */
static void
shm_copy(void)
{
	alignas(8) _Atomic uint64_t area[4];
	unsigned char bytes[sizeof(area)], out[40];
	unsigned i;

	for (i = 0; i < sizeof(bytes); i++)
		bytes[i] = (unsigned char)(i + 1);
	memcpy((void *)area, bytes, sizeof(bytes));
	memset(out, 0xee, sizeof(out));
	erx_shm_copy(area, sizeof(area), 3, out, 5);
	expect("copy inside", memcmp(out, bytes + 3, 5) == 0 && out[5] == 0xee);
	memset(out, 0xee, sizeof(out));
	erx_shm_copy(area, sizeof(area), 29, out, 7);
	expect("copy wraps", memcmp(out, bytes + 29, 3) == 0 &&
	    memcmp(out + 3, bytes, 4) == 0 && out[7] == 0xee);
	memset(out, 0xee, sizeof(out));
	erx_shm_copy(area, sizeof(area), UINT64_C(1) << 40, out, 8);
	expect("copy masks the position", memcmp(out, bytes, 8) == 0);
	memset(out, 0xee, sizeof(out));
	erx_shm_copy(area, sizeof(area), 5, out, 0);
	expect("copy nothing", out[0] == 0xee);
}

/* A pipe end's doorbell label, built and taken apart by the one helper. */
static void
label(void)
{
	uint64_t made, pipe, end;

	expect("label shift", ERX_PIPE_LABEL_SHIFT == 32);
	expect("label made", erx_pipe_label(1, 5, &made) &&
	    made == ((UINT64_C(1) << ERX_PIPE_LABEL_SHIFT) | 5));
	expect("label parts", erx_pipe_label_parts(made, &pipe, &end) &&
	    pipe == 1 && end == 5);
	expect("label widest", erx_pipe_label(UINT32_MAX, UINT32_MAX, &made) &&
	    made == UINT64_MAX && erx_pipe_label_parts(made, &pipe, &end) &&
	    pipe == UINT32_MAX && end == UINT32_MAX);
	expect("label pipe zero", !erx_pipe_label(0, 5, &made));
	expect("label pipe too wide",
	    !erx_pipe_label(UINT64_C(1) << 32, 5, &made));
	expect("label end too wide",
	    !erx_pipe_label(1, UINT64_C(1) << 32, &made));
	expect("label channel is no pipe end's",
	    !erx_pipe_label_parts(ERX_PROG_CHANNEL_LABEL, &pipe, &end));
	expect("label below every pipe's",
	    !erx_pipe_label_parts(UINT32_MAX, &pipe, &end));
}

int
main(void)
{
	ring_positions();
	ring_records();
	ring_room();
	lock_owner();
	lock_settle();
	shm_copy();
	label();
	printf("pipe_check done\n");
	return (failures == 0 ? 0 : 1);
}
