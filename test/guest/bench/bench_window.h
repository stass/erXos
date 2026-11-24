/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A sustained cell's window accounting (docs/design-bench.md, "A sustained cell"): what a
 * recording spinner keeps of one window from its gaps, the ticks between two of its reads
 * of the counter. A pure function of the gaps and the plan, built for the host and tested
 * there by test/host/bench_periodic_test.rb.
 */

#ifndef ERX_BENCH_WINDOW_H
#define ERX_BENCH_WINDOW_H

#include <stdint.h>

typedef struct {
	uint64_t iterations;	/* passes of the spinner's loop */
	uint64_t longest;	/* its longest gap, in ticks */
	uint64_t lost;		/* its lost turns: gaps longer than half the configured slice */
	uint64_t waited;	/* the ticks its lost turns took */
} erx_bench_window_t;

/* Half of a slice of slice_us microseconds, in ticks of a counter at hz: a longer gap is a lost turn. */
uint64_t	erx_bench_window_lost_after(uint64_t hz, uint64_t slice_us);
/* Adds one pass of the loop whose read ended a gap of gap ticks. */
void	erx_bench_window_pass(erx_bench_window_t *window, uint64_t gap, uint64_t lost_after);
/* A window no read fell in: one gap of its whole length, length ticks, with no pass. */
erx_bench_window_t	erx_bench_window_empty(uint64_t length, uint64_t lost_after);

#endif /* ERX_BENCH_WINDOW_H */
