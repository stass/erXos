/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The guests' BENCH and CLOCK lines (docs/design-bench.md, "A benchmark"): each formats
 * one line, prefix and JSON object without a newline, into a caller's buffer, and fails
 * whole when the line does not fit, so a cut line is never printed. The host's
 * Erx::BenchMeasurement is the lines' one validator; the strings given here are the
 * guest's own constants, written as they are.
 */

#ifndef ERX_BENCH_LINE_H
#define ERX_BENCH_LINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "bench_clock.h"
#include "bench_hist.h"
#include "bench_periodic.h"
#include "bench_window.h"

#define	ERX_BENCH_LARGEST	16

/* A sample and its sequence number in the run. */
typedef struct {
	uint64_t sequence;
	uint64_t value;
} erx_bench_sample_t;

/* One workload parameter: a name and either a name (text) or, where text is NULL, a count. */
typedef struct {
	const char *name;
	const char *text;
	uint64_t count;
} erx_bench_param_t;

/* One cell. reason is NULL exactly when status is "measured". */
typedef struct {
	const char *benchmark;
	const char *operation;
	const char *load;
	const char *placement;
	const erx_bench_param_t *params;
	size_t nparams;
	const char *clock;
	uint64_t batch;
	uint64_t frequency_hz;
	const char *status;
	const char *reason;
	const erx_bench_hist_t *hist;
	uint64_t min;
	uint64_t max;
	/*
	 * The ERX_BENCH_LARGEST largest samples, or every sample where there are fewer, the
	 * largest first: the host refuses a line with fewer.
	 */
	const erx_bench_sample_t *largest;
	size_t nlargest;
	uint64_t lost;
	uint64_t early;
	uint64_t missed;
	/* An expensive cell's every sample, in order; NULL for the other profiles. */
	const uint64_t *raw;
	size_t nraw;
	/* A one-way cell across CPUs: the half-width of its pair's offset hull. */
	bool has_uncertainty;
	uint64_t uncertainty;
	/* A periodic cell's classification, whose late histogram is hist; NULL otherwise. */
	const erx_bench_periodic_t *periodic;
	/*
	 * A sustained cell: its samples are its windows, which its WINDOW lines carry, and it has
	 * no histogram, extremes or largest samples (docs/design-bench.md, "A sustained cell").
	 */
	bool sustained;
	uint64_t windows;
} erx_bench_cell_t;

/*
 * One pair of CPUs a cell was stamped across, the lower first, and its offset before and
 * after the cells.
 */
typedef struct {
	unsigned cpus[2];
	erx_bench_offset_t before;
	erx_bench_offset_t after;
} erx_bench_pair_t;

typedef struct {
	const char *clock;
	uint64_t frequency_hz;
	uint64_t increment;
	uint64_t read_cost;
	uint64_t wait_rounding;
	/*
	 * The CPU's cycles per counter tick in thousandths; 0 where it is unknown, and written
	 * as unknown above 1000 cycles, the most the host reads.
	 */
	uint64_t cycles_per_tick_milli;
	const erx_bench_pair_t *pairs;
	size_t npairs;
} erx_bench_calibration_t;

/*
 * Each writes its line into buf, NUL-terminated, and returns its length; where the line
 * and its NUL do not fit in size bytes it returns 0, leaving buf an empty string.
 */
size_t erx_bench_line_cell(char *buf, size_t size, const erx_bench_cell_t *cell);
size_t erx_bench_line_clock(char *buf, size_t size, const erx_bench_calibration_t *clock);
/* A sustained cell's WINDOW line for thread's window (docs/design-bench.md, "A sustained cell"). */
size_t erx_bench_line_window(char *buf, size_t size, uint32_t window, uint32_t thread,
    const erx_bench_window_t *kept);

#endif
