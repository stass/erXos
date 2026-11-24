/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The nullcall benchmark's timed loop and its request, in the root and in the test task alike (nullcall.h). */

#include <stddef.h>
#include <stdint.h>

#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/generated/calls.h"
#include "test/guest/native_bench/nullcall.h"

int64_t
nullcall_refusal(void)
{
#ifdef ERX_BENCH_SEED_EMPTY_SLOT
	return (erx_fiasco_test_empty_slot_call() != 0 ? ERX_EINVAL : ERX_OK);
#else
	/* VM_COMMIT's request is four words; the decoder refuses one before any body runs. */
	const uint64_t caller = erx_fiasco_thread_self()->index;
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_VM_COMMIT, &caller, sizeof(caller), &reply));
#endif
}

nullcall_run_t
nullcall_time(nullcall_fn_t call, int64_t expected, uint64_t *samples, erx_bench_hist_t *scratch)
{
	nullcall_run_t run = { .batch = 1, .taken = 0, .calls = 0, .answer = expected, .wrong = 0 };

	for (size_t at = 0; at < ERX_BENCH_HIST_BUCKETS; at++)
		scratch->count[at] = 0;
	scratch->samples = 0;
	for (uint32_t warm = 0; warm < ERX_BENCH_FAST_WARMUP; warm++) {
		const uint64_t start = erx_fiasco_counter();

		run.answer = call();
		run.calls++;
		if (run.answer != expected) {
			run.wrong = 1;
			return (run);
		}
		erx_bench_hist_add(scratch, erx_fiasco_counter() - start);
	}
	run.batch = erx_bench_batch_for(erx_bench_hist_median(scratch));
	for (; run.taken < ERX_BENCH_FAST_SAMPLES; run.taken++) {
		const uint64_t start = erx_fiasco_counter();

		for (uint64_t made = 0; made < run.batch; made++) {
			run.answer = call();
			run.calls++;
			if (run.answer != expected) {
				run.wrong = 1;
				return (run);
			}
		}
		samples[run.taken] = (erx_fiasco_counter() - start) / run.batch;
	}
	return (run);
}
