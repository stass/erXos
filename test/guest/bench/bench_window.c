/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "bench_window.h"

#define	MICROS_PER_SECOND	UINT64_C(1000000)

uint64_t
erx_bench_window_lost_after(uint64_t hz, uint64_t slice_us)
{
	/* hz is at most 10 GHz and a slice at most seconds long, so the product fits. */
	return (hz * slice_us / MICROS_PER_SECOND / 2);
}

/* A gap of gap ticks: the longest so far, and a lost turn when over lost_after. */
static void
gap_of(erx_bench_window_t *window, uint64_t gap, uint64_t lost_after)
{
	if (gap > window->longest)
		window->longest = gap;
	if (gap > lost_after) {
		window->lost++;
		window->waited += gap;
	}
}

void
erx_bench_window_read(erx_bench_window_t *window, uint64_t start, uint64_t end, uint64_t last, uint64_t now,
    uint64_t lost_after)
{
	if (last >= start || now < end)
		window->iterations++;
	gap_of(window, now - last, lost_after);
}

erx_bench_window_t
erx_bench_window_empty(uint64_t length, uint64_t lost_after)
{
	erx_bench_window_t window = { 0, 0, 0, 0 };

	gap_of(&window, length, lost_after);
	return (window);
}
