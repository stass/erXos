/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Host driver of the lane driver's scratch growth (erx_lane_scratch_grow in
 * otp/erts/emulator/sys/erxos/erx_lane_core.c), for test/host/erx_lane_scratch_test.rb. It
 * grows a scratch with an allocator that succeeds or fails as the argument says, and prints
 *
 *   START RESULT LEN ALLOCS RELEASES SAME_BLOCK
 *
 * each a number: the scratch's length at the start (ERX_FUNNEL_CTL_SCRATCH), erx_lane_scratch_grow's
 * answer, the scratch's length afterwards, how many
 * times the allocator and the releaser were called, and whether the block is still the one
 * the scratch started with. Arguments: WANT (the bytes to grow to) and FAIL (1 to make the
 * allocator return NULL).
 */

#include <stdio.h>
#include <stdlib.h>

#include "erx_lane_core.h"

static int allocs;
static int releases;
static int failing;

static void *
fake_alloc(size_t len)
{
	allocs++;
	return (failing ? NULL : malloc(len));
}

static void
fake_release(void *block)
{
	releases++;
	free(block);
}

int
main(int argc, char **argv)
{
	erx_lane_scratch_t scratch = { .len = ERX_FUNNEL_CTL_SCRATCH };
	uint8_t *const first = malloc(scratch.len);
	bool ok;

	if (argc != 3 || first == NULL)
		return (2);
	scratch.block = first;
	failing = atoi(argv[2]) != 0;
	ok = erx_lane_scratch_grow(&scratch, (size_t)strtoull(argv[1], NULL, 10), fake_alloc, fake_release);
	printf("%zu %d %zu %d %d %d\n", (size_t)ERX_FUNNEL_CTL_SCRATCH, ok, scratch.len, allocs,
	    releases, scratch.block == first);
	if (scratch.block != first)
		free(scratch.block);
	else
		free(first);
	return (0);
}
