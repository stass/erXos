/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What the nullcall benchmark's root (nullcall.c) and its test task (program.c) share:
 * the timed loop (nullcall_time.c), the request the service's decoder refuses, and the
 * page the root maps into the task, through which the root names the task's CPU and the
 * task gives back its run.
 */

#ifndef ERX_NATIVE_BENCH_NULLCALL_H
#define ERX_NATIVE_BENCH_NULLCALL_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "test/guest/bench/bench_hist.h"

#if !defined(ERX_BENCH_FAST_WARMUP) || !defined(ERX_BENCH_FAST_SAMPLES)
#error "the build passes the fast profile's sizes"
#endif

/* Operations that span fewer ticks are timed in batches (docs/design-bench.md, "The one clock"). */
#define NULLCALL_SPAN_TICKS	UINT64_C(100)

/* One call of a cell; what it answers, a status or Fiasco's error, is held to the cell's correct result. */
typedef int64_t (*nullcall_fn_t)(void);

/*
 * A timed run: the batch, the smallest power of two of calls whose warm-up median spans
 * NULLCALL_SPAN_TICKS; the samples taken, each a batch's ticks over its calls, rounded
 * down; every call made, warm-up included; and the first answer that was not the correct
 * result, with wrong set.
 */
typedef struct {
	uint64_t	batch;
	uint64_t	taken;
	uint64_t	calls;
	int64_t		answer;
	uint32_t	wrong;
} nullcall_run_t;

/*
 * The page the root maps into the task, whose address is the task's argument. The root
 * writes cpu before the task starts; the task times its run there into run and samples,
 * then raises done, after which it makes no request the decoder refuses, so the root reads
 * the task's count of refusals (erx_fiasco_test_refused) before its join.
 */
typedef struct {
	uint32_t		cpu;
	_Atomic uint32_t	done;
	nullcall_run_t		run;
	uint64_t		samples[ERX_BENCH_FAST_SAMPLES];
} nullcall_page_t;

#define NULLCALL_PAGE_BYTES	((sizeof(nullcall_page_t) + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE)

/*
 * ERX_BENCH_FAST_WARMUP calls one at a time, then ERX_BENCH_FAST_SAMPLES batches into
 * samples; scratch takes the warm-up's histogram. Stops at the first call whose answer
 * is not expected.
 */
nullcall_run_t	nullcall_time(nullcall_fn_t call, int64_t expected, uint64_t *samples, erx_bench_hist_t *scratch);
/*
 * The decoder-refusal request: a call whose request has more than one word, sent with
 * only the caller's word, which the service's decoder answers ERX_EINVAL. Built with
 * ERX_BENCH_SEED_EMPTY_SLOT it goes to the kernel cell's empty slot instead, a failed
 * IPC, which the stub also reports as ERX_EINVAL, but the service never receives.
 */
int64_t	nullcall_refusal(void);

#endif /* ERX_NATIVE_BENCH_NULLCALL_H */
