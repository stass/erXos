/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The nullcall benchmark's test task, loaded from the boot image by nullcall.c: the
 * decoder-refusal round trip from a space that is not the service's. Its argument is the
 * address of the page the root mapped into it (nullcall.h), which names the CPU to run on
 * and takes back the timed run. Its status is 0, or STATUS_AFFINITY when it could not
 * move to that CPU.
 */

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/native_bench/nullcall.h"

#define STATUS_AFFINITY	1

static erx_bench_hist_t scratch;

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	nullcall_page_t *const page = (nullcall_page_t *)(uintptr_t)args[0];
	int64_t status = STATUS_AFFINITY;

	if (erx_thread_set_affinity(erx_fiasco_thread_self()->index, UINT64_C(1) << page->cpu) == ERX_OK) {
		page->run = nullcall_time(nullcall_refusal, ERX_EINVAL, page->samples, &scratch);
		status = 0;
	}
	atomic_store_explicit(&page->done, 1, memory_order_release);
	return (status);
}
