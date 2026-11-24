/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The sched benchmark's native cells (docs/design-bench.md, "2. `sched`: how a CPU is
 * shared"): share-equal launches test/guest/native_task's program in MODE_SHARE, its
 * recording spinners on the last CPU, joins it and names the cell its WINDOW lines report
 * (docs/design-bench.md, "A sustained cell"). The cell reads its counter on one CPU; the
 * CLOCK line still calibrates CPU 0 and the last, the pair every native bench boot of more
 * than one CPU is asked for, each side of it by a thread that then sleeps, so nothing but
 * the spinners runs on their CPU during the windows.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/native_bench/bench_root.h"
#include "test/guest/native_task/modes.h"

#if !defined(ERX_BENCH_SUSTAINED_SAMPLES) || !defined(ERX_BENCH_SUSTAINED_WARMUP_MS)
#error "the build passes the sustained profile's landing sizes"
#endif

const char bench_benchmark[] = "sched";

#define PROGRAM		"boot/native-task"
/* share-equal's landing cell's parameters, which tools/lib/erx/benches/sched.rb declares. */
#define THREADS		4u
#define WINDOW_MS	1000u
#define MS_PER_SECOND	UINT64_C(1000)

static const erx_bench_param_t share_params[] = { { "threads", NULL, THREADS }, { "window-ms", NULL, WINDOW_MS } };

/* share-equal's cell, which its WINDOW lines and the root's status complete. */
static erx_bench_cell_t
share_cell(void)
{
	erx_bench_cell_t cell = bench_cell_of("share-equal", "other-cpu");

	cell.params = share_params;
	cell.nparams = sizeof(share_params) / sizeof(share_params[0]);
	cell.sustained = true;
	return (cell);
}

/* Runs the spinner task on last and names its cell: measured when it ended with 0. */
static void
share_equal(uint32_t last, const erx_pack_view_t *pack)
{
	const uint64_t run_ns = (ERX_BENCH_SUSTAINED_WARMUP_MS + ERX_BENCH_SUSTAINED_SAMPLES * WINDOW_MS) *
	    (NS_PER_SECOND / MS_PER_SECOND);
	erx_bench_cell_t cell = share_cell();
	uint64_t task, pc;
	uint32_t entry;
	int64_t status = INT64_MIN;

	if (erx_fiasco_launcher_find(pack, PROGRAM, &entry) != ERX_OK)
		bench_fail("erx: bench: no task program FAILED\n");
	if (erx_fiasco_launch_make(entry, 0, &task, &pc) != ERX_OK ||
	    erx_fiasco_launch_start(task, pc, SHARE_ARGUMENT(THREADS, last, ERX_BENCH_SUSTAINED_SAMPLES, WINDOW_MS)) !=
	    ERX_OK)
		bench_fail("erx: bench: the spinner task did not start FAILED\n");
	if (erx_fiasco_task_join_until(task, erx_fiasco_clock_ns() + run_ns + PATIENCE_NS, &status) != ERX_OK)
		bench_fail("erx: bench: the spinner task did not end FAILED\n");
	if (status == 0)
		cell.windows = ERX_BENCH_SUSTAINED_SAMPLES;
	else {
		cell.status = "failed";
		cell.reason = "the spinner task did not end with 0";
	}
	bench_print(&cell);
}

void
bench_cells(uint32_t cpus, const erx_pack_view_t *pack)
{
	erx_bench_pair_t pair = { .cpus = { 0, cpus - 1 } };

	if (cpus == 1) {
		erx_bench_cell_t cell = share_cell();

		cell.status = "unsupported";
		cell.reason = "the machine has one CPU";
		bench_print(&cell);
		bench_print_clock(NULL, 0);
		return;
	}
	pair.before = bench_calibrate_on(0, cpus - 1);
	share_equal(cpus - 1, pack);
	pair.after = bench_calibrate_on(1, cpus - 1);
	bench_print_clock(&pair, 1);
}
