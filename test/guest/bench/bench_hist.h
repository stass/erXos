/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The guests' histogram of intervals in clock ticks (docs/design-bench.md, "The
 * histogram"). Each power of two from 64 up is split into 64 equal buckets, so a bucket is
 * at most 1/64 of its lower bound wide; below 64 every tick count has its own bucket. A
 * reader takes each non-empty bucket's bounds as sent and needs no formula.
 */

#ifndef ERX_BENCH_HIST_H
#define ERX_BENCH_HIST_H

#include <stdint.h>

#define	ERX_BENCH_HIST_SUB	64
/* 64 exact buckets, then 64 for each of the octaves 6 to 63. */
#define	ERX_BENCH_HIST_BUCKETS	(ERX_BENCH_HIST_SUB + (64 - 6) * ERX_BENCH_HIST_SUB)

typedef struct {
	uint64_t count[ERX_BENCH_HIST_BUCKETS];
	uint64_t samples;
} erx_bench_hist_t;

/* The bucket that holds value. */
unsigned erx_bench_hist_index(uint64_t value);
/*
 * Bucket index's bounds: it holds the values from *low to *last, both included. index is
 * below ERX_BENCH_HIST_BUCKETS.
 */
void erx_bench_hist_bounds(unsigned index, uint64_t *low, uint64_t *last);
void erx_bench_hist_add(erx_bench_hist_t *hist, uint64_t value);
/*
 * The upper end of the bucket holding the sample of rank ceil(samples / 2), the median
 * the host's reader derives too; 0 for no samples.
 */
uint64_t erx_bench_hist_median(const erx_bench_hist_t *hist);

/*
 * Short operations are timed in batches (docs/design-bench.md, "Short operations"): the
 * smallest power of two of operations of median ticks each that spans ERX_BENCH_SPAN_TICKS,
 * and at most ERX_BENCH_BATCH_MAX, a batch that spans the clock however fast an operation is.
 */
#define	ERX_BENCH_SPAN_TICKS	UINT64_C(100)
#define	ERX_BENCH_BATCH_MAX	256u
uint64_t erx_bench_batch_for(uint64_t median);

#endif
