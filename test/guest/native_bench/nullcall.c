/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The nullcall benchmark's cells (docs/design-bench.md, "3. `nullcall`: the
 * decoder-refusal round trip"): the request the root service's decoder refuses, timed from
 * a thread of the root and from a test task (program.c), each on the service's CPU, 0, and
 * on the last; and the kernel's cheapest call, an IPC to an empty slot
 * (erx_fiasco_test_empty_slot_call). Every cell's two stamps are read on one CPU. On more
 * than one CPU the root calibrates CPU 0 against the last, which the CLOCK line reports.
 *
 * ERX_EINVAL alone does not show that the decoder answered, since the stub reports a
 * failed IPC as ERX_EINVAL too, so each root and task cell's run must raise its task's
 * count of refusals (erx_fiasco_test_refused) by exactly the calls it made; otherwise
 * the cell is failed. No other thread of that task makes such a request meanwhile.
 */

#include <stdatomic.h>
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
#include "test/guest/native_bench/bench_root.h"
#include "test/guest/native_bench/nullcall.h"

#define PROGRAM		"boot/native-bench-task"
#define SERVICE_CPU	0u
#ifndef ERX_BENCH_UNCOUNTED
#error "the build passes the reason of a cell whose run did not raise its count by its calls"
#endif

const char bench_benchmark[] = "nullcall";

/* The timed cells, in the order they print. */
typedef enum {
	CELL_ROOT_SERVICE,
	CELL_ROOT_OTHER,
	CELL_TASK_SERVICE,
	CELL_TASK_OTHER,
	CELL_KERNEL,
	CELLS
} cell_index_t;

typedef struct {
	const char	*operation;
	const char	*placement;
	/* Whether the cell needs a second CPU, and so is unsupported on one. */
	bool		other;
} cell_name_t;

static const cell_name_t cell_names[CELLS] = {
	[CELL_ROOT_SERVICE] = { "root-same-space", "service-cpu", false },
	[CELL_ROOT_OTHER] = { "root-same-space", "other-cpu", true },
	[CELL_TASK_SERVICE] = { "root-cross-space", "service-cpu", false },
	[CELL_TASK_OTHER] = { "root-cross-space", "other-cpu", true },
	[CELL_KERNEL] = { "kernel", "same-cpu", false },
};

static uint64_t samples[CELLS][FAST_SAMPLES];
static nullcall_run_t runs[CELLS];
/* Whether the decoder answered every call of the cell's run: the kernel cell's never reach it. */
static bool answered[CELLS] = { [CELL_KERNEL] = true };
static erx_bench_hist_t scratch;
static uint32_t program_entry;
static uint64_t page_object;
static nullcall_page_t *page;
static _Atomic uint32_t other_done;

static int64_t
kernel_call(void)
{
	return ((int64_t)erx_fiasco_test_empty_slot_call());
}

/* A root cell's run on the calling thread, while the root's other threads make no refusal. */
static void
root_cell(cell_index_t cell)
{
	const uint64_t before = erx_fiasco_test_refused(ERX_CAP_SELF);

	runs[cell] = nullcall_time(nullcall_refusal, ERX_EINVAL, samples[cell], &scratch);
	answered[cell] = erx_fiasco_test_refused(ERX_CAP_SELF) - before == runs[cell].calls;
}

/* The thread on the other CPU: B of a calibration before and after its timed run. */
static void
other_main(uint64_t index)
{
	(void)index;
	bench_calibrate_b();
	root_cell(CELL_ROOT_OTHER);
	atomic_store_explicit(&other_done, 1, memory_order_release);
	bench_calibrate_b();
	erx_fiasco_sleep_forever();
}

static erx_bench_pair_t
root_other_cell(uint32_t last)
{
	erx_bench_pair_t pair = { .cpus = { SERVICE_CPU, last } };
	const uint64_t until = erx_fiasco_clock_ns() + PATIENCE_NS;

	bench_thread_start(0, last, ERX_THREAD_CLASS_WORKER, other_main);
	pair.before = bench_calibrate_a();
	while (atomic_load_explicit(&other_done, memory_order_acquire) == 0) {
		if (erx_fiasco_clock_ns() > until)
			bench_fail("erx: bench: the other CPU's thread stopped answering FAILED\n");
		bench_wait_poll();
	}
	pair.after = bench_calibrate_a();
	return (pair);
}

/* The page the task's argument names, mapped in the root for good and into each task. */
static void
page_make(void)
{
	uint64_t addr;

	if (erx_mem_create(0, NULLCALL_PAGE_BYTES, 0, &page_object) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, 0, NULLCALL_PAGE_BYTES, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, NULLCALL_PAGE_BYTES, page_object, 0, ERX_PROT_RW) != ERX_OK)
		bench_fail("erx: bench: no page for the task FAILED\n");
	page = (nullcall_page_t *)(uintptr_t)addr;
}

/* Starts a task on the page that times its run on cpu; its space's handle. */
static uint64_t
task_start(uint32_t cpu)
{
	uint64_t task, pc, addr;

	if (erx_fiasco_launch_make(program_entry, 0, &task, &pc) != ERX_OK)
		bench_fail("erx: bench: no task FAILED\n");
	if (page == NULL)
		page_make();
	page->cpu = cpu;
	atomic_store_explicit(&page->done, 0, memory_order_relaxed);
	if (erx_vm_reserve(task, 0, NULLCALL_PAGE_BYTES, 0, &addr) != ERX_OK ||
	    erx_vm_map(task, addr, NULLCALL_PAGE_BYTES, page_object, 0, ERX_PROT_RW) != ERX_OK)
		bench_fail("erx: bench: the page did not map into the task FAILED\n");
	if (erx_fiasco_launch_start(task, pc, addr) != ERX_OK)
		bench_fail("erx: bench: the task did not start FAILED\n");
	return (task);
}

/* A task cell: its count is read once the task is done, before the join ends the task's row. */
static void
task_cell(cell_index_t cell, uint32_t cpu)
{
	const uint64_t task = task_start(cpu);
	const uint64_t until = erx_fiasco_clock_ns() + PATIENCE_NS;
	int64_t status = INT64_MIN;
	uint64_t refused;

	while (atomic_load_explicit(&page->done, memory_order_acquire) == 0) {
		if (erx_fiasco_clock_ns() > until)
			bench_fail("erx: bench: the timing task stopped answering FAILED\n");
		bench_wait_poll();
	}
	refused = erx_fiasco_test_refused(task);
	if (erx_fiasco_task_join_until(task, erx_fiasco_clock_ns() + PATIENCE_NS, &status) != ERX_OK || status != 0 ||
	    page->run.taken > FAST_SAMPLES)
		bench_fail("erx: bench: the timing task failed FAILED\n");
	runs[cell] = page->run;
	answered[cell] = refused == page->run.calls;
	for (uint64_t at = 0; at < page->run.taken; at++)
		samples[cell][at] = page->samples[at];
}

static void
print_cell(cell_index_t index)
{
	erx_bench_cell_t cell = bench_cell_of(cell_names[index].operation, cell_names[index].placement);
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	const nullcall_run_t *const run = &runs[index];

	cell.batch = run->batch;
	cell.has_total = true;
	cell.total = run->total;
	bench_summarize(&cell, samples[index], run->taken, top);
	if (run->wrong != 0) {
		cell.status = "failed";
		cell.reason = "wrong result";
	} else if (!answered[index]) {
		cell.status = "failed";
		cell.reason = ERX_BENCH_UNCOUNTED;
	}
	bench_print(&cell);
}

void
bench_cells(uint32_t cpus, const erx_pack_view_t *pack)
{
	erx_bench_pair_t pair = { 0 };

	if (erx_fiasco_launcher_find(pack, PROGRAM, &program_entry) != ERX_OK)
		bench_fail("erx: bench: no task program FAILED\n");
	root_cell(CELL_ROOT_SERVICE);
	if (cpus > 1)
		pair = root_other_cell(cpus - 1);
	task_cell(CELL_TASK_SERVICE, SERVICE_CPU);
	if (cpus > 1)
		task_cell(CELL_TASK_OTHER, cpus - 1);
	runs[CELL_KERNEL] = nullcall_time(kernel_call, (int64_t)ERX_FIASCO_TEST_EMPTY_SLOT_ERROR, samples[CELL_KERNEL],
	    &scratch);
	for (cell_index_t index = 0; index < CELLS; index++) {
		if (cell_names[index].other && cpus == 1)
			bench_print_unsupported(bench_cell_of(cell_names[index].operation, cell_names[index].placement),
			    "the machine has one CPU");
		else
			print_cell(index);
	}
	bench_print_clock(cpus > 1 ? &pair : NULL, cpus > 1 ? 1 : 0);
}
