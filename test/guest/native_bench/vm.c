/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The vm benchmark's cells (docs/design-bench.md, "4. `vm`: what memory costs"): reserve,
 * commit, touch, protect, decommit and release of one page, timed from a test task
 * (vm_task.c) on the service's CPU, 0, each followed by its untimed check. At each step of
 * the task's check the root reads the free page count and holds it to the call before; and, since a
 * protect that does nothing leaves a page that no read can tell from a protected one, a
 * disposable task, whose records come to a fault gate of the root's, writes its read-only
 * page, and the root expects that task's fault record at the page's address.
 *
 * On more than one CPU the root calibrates CPU 0 against the last before and after the
 * cells, the pair every native bench boot's CLOCK line carries.
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
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_bench/bench_root.h"
#include "test/guest/native_bench/vm.h"

#define PROGRAM		"boot/native-bench-task"
#define SERVICE_CPU	0u
#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define TASK_CAP_LIMIT	64u
#define FAULT_LABEL	UINT64_C(0x5e000000000b0000)
/* The status the root stops the faulted disposable task with. */
#define FAULT_STATUS	79
#ifndef ERX_BENCH_UNFAULTED
#error "the build passes the reason of a protect cell whose disposable task did not fault"
#endif

const char bench_benchmark[] = "vm";

static const char *const cell_names[VM_CELLS] = {
	[VM_RESERVE] = "reserve",
	[VM_COMMIT] = "commit",
	[VM_TOUCH] = "touch",
	[VM_PROTECT] = "protect",
	[VM_DECOMMIT] = "decommit",
	[VM_RELEASE] = "release",
};

static uint64_t samples[VM_CELLS][FAST_SAMPLES];
static vm_run_t runs[VM_CELLS];
/* The free page count at each step of the task's check. */
static uint64_t free_at[VM_STEPS];
static uint32_t program_entry;
static vm_page_t *page;

static int
handle_close(uint64_t handle)
{
	return (erx_cap_close((erx_cap_t){ .raw = handle }));
}

/* Starts the timed task on cpu, the page mapped at VM_PAGE_ADDR in it; its space's handle. */
static uint64_t
timed_start(uint32_t cpu)
{
	uint64_t task, pc, object, addr;

	if (erx_mem_create(0, VM_PAGE_BYTES, 0, &object) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, 0, VM_PAGE_BYTES, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, VM_PAGE_BYTES, object, 0, ERX_PROT_RW) != ERX_OK)
		bench_fail("erx: bench: no page for the task FAILED\n");
	page = (vm_page_t *)(uintptr_t)addr;
	page->cpu = cpu;
	if (erx_fiasco_launch_make(program_entry, 0, &task, &pc) != ERX_OK ||
	    erx_vm_reserve(task, VM_PAGE_ADDR, VM_PAGE_BYTES, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) != ERX_OK ||
	    erx_vm_map(task, VM_PAGE_ADDR, VM_PAGE_BYTES, object, 0, ERX_PROT_RW) != ERX_OK ||
	    erx_fiasco_launch_start(task, pc, VM_PAGE_ADDR) != ERX_OK)
		bench_fail("erx: bench: the timing task did not start FAILED\n");
	return (task);
}

/*
 * Waits for the timed task's runs, reading the free page count at each step its check
 * says; the task must say each step in order and make progress within PATIENCE_NS.
 */
static void
timed_wait(uint64_t task)
{
	uint64_t until = erx_fiasco_clock_ns() + PATIENCE_NS;
	uint32_t answered = VM_STEP_NONE, progress = 0;
	int64_t status = INT64_MIN;

	while (atomic_load_explicit(&page->done, memory_order_acquire) == 0) {
		const uint32_t step = atomic_load_explicit(&page->step, memory_order_acquire);
		const uint32_t done = atomic_load_explicit(&page->progress, memory_order_acquire);
		bool moved = done != progress;

		if (step != answered) {
			if (step != answered + 1 || step >= VM_STEPS)
				bench_fail("erx: bench: the timing task said a step out of order FAILED\n");
			free_at[step] = erx_fiasco_vm_free_pages();
			answered = step;
			atomic_store_explicit(&page->answered, step, memory_order_release);
			moved = true;
		}
		if (moved) {
			progress = done;
			until = erx_fiasco_clock_ns() + PATIENCE_NS;
		} else if (erx_fiasco_clock_ns() > until) {
			bench_fail("erx: bench: the timing task stopped answering FAILED\n");
		}
		bench_wait_poll();
	}
	if (erx_fiasco_task_join_until(task, erx_fiasco_clock_ns() + PATIENCE_NS, &status) != ERX_OK || status != 0 ||
	    answered != VM_STEP_RELEASED)
		bench_fail("erx: bench: the timing task failed FAILED\n");
	for (vm_cell_t cell = 0; cell < VM_CELLS; cell++) {
		runs[cell] = page->runs[cell];
		if (runs[cell].taken > FAST_SAMPLES || runs[cell].batch == 0 || runs[cell].batch > ERX_BENCH_BATCH_MAX)
			bench_fail("erx: bench: the timing task's run does not fit FAILED\n");
		for (uint64_t at = 0; at < runs[cell].taken; at++)
			samples[cell][at] = page->samples[cell][at];
	}
}

/* The next record at the gates bound to the root's thread, with its label: a record's words and no items. */
static bool
record_wait(uint64_t deadline, erx_fault_t *record, uint64_t *label)
{
	const erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];
	erx_msgtag_t tag;

	if (erx_ipc_wait(deadline, &tag, label) != ERX_OK ||
	    erx_msgtag_raw_words_get(tag.raw) != sizeof(words) / sizeof(words[0]) ||
	    erx_msgtag_raw_items_get(tag.raw) != 0)
		return (false);
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	__builtin_memcpy(record, words, sizeof(words));
	return (true);
}

/*
 * Whether the disposable task's write to its read-only page faulted at that page. The
 * task's records come to a gate bound to the root's thread: a faulted task stays blocked
 * in its fault until the root stops it, and its exit record follows; a task whose write
 * went through ends by itself with VM_STATUS_WRITTEN, and its exit record comes first.
 * Any other record is a setup failure, never an answer for the cell.
 */
static bool
protect_faults(void)
{
	uint64_t gate, space, pc, label;
	erx_fault_t record;
	int64_t status = INT64_MIN;
	bool faulted, written, ended;

	if (erx_gate_create(0, &gate) != ERX_OK || erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK ||
	    erx_space_create(0, ERX_CAP_SELF, gate, FAULT_LABEL, 0, TASK_CAP_LIMIT, &space) != ERX_OK ||
	    erx_image_map(space, 0, program_entry, &pc) != ERX_OK ||
	    erx_vm_reserve(space, VM_FAULT_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) != ERX_OK ||
	    erx_fiasco_launch_start(space, pc, VM_FAULT_ADDR) != ERX_OK)
		bench_fail("erx: bench: the disposable task did not start FAILED\n");
	if (!record_wait(erx_fiasco_clock_ns() + PATIENCE_NS, &record, &label) || label != FAULT_LABEL)
		bench_fail("erx: bench: the disposable task sent no record FAILED\n");
	faulted = record.kind == ERX_FAULT_MEMORY && record.addr == VM_FAULT_ADDR;
	written = record.kind == ERX_FAULT_EXIT && record.status == VM_STATUS_WRITTEN;
	if (!faulted && !written)
		bench_fail("erx: bench: the disposable task neither faulted at its page nor wrote it FAILED\n");
	ended = written || (erx_space_stop(space, FAULT_STATUS) == ERX_OK &&
	    record_wait(erx_fiasco_clock_ns() + PATIENCE_NS, &record, &label) && label == FAULT_LABEL &&
	    record.kind == ERX_FAULT_EXIT && record.status == FAULT_STATUS);
	if (!ended || erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + PATIENCE_NS, &status) != ERX_OK ||
	    status != record.status || erx_object_destroy(gate) != ERX_OK || handle_close(gate) != ERX_OK)
		bench_fail("erx: bench: the disposable task did not end FAILED\n");
	return (faulted);
}

/* The root's part of each cell's check: the free page count at each step, held to the call before it. */
static bool
counts_hold(vm_cell_t cell)
{
	const uint64_t before = free_at[VM_STEP_BEFORE];

	switch (cell) {
	case VM_COMMIT:
		return (free_at[VM_STEP_COMMITTED] == before - 1);
	case VM_DECOMMIT:
		return (free_at[VM_STEP_DECOMMITTED] == before);
	case VM_RESERVE:
	case VM_RELEASE:
		return (free_at[VM_STEP_RELEASED] == before);
	case VM_TOUCH:
	case VM_PROTECT:
	case VM_CELLS:
		return (true);
	}
	return (true);
}

static void
print_cell(vm_cell_t index, bool faulted)
{
	erx_bench_cell_t cell = bench_cell_of(cell_names[index], "service-cpu");
	erx_bench_sample_t top[ERX_BENCH_LARGEST];
	const vm_run_t *const run = &runs[index];

	if (run->answer == ERX_ENOTSUP) {
		bench_print_unsupported(cell, "the Fiasco backend answers ERX_ENOTSUP");
		return;
	}
	cell.batch = run->batch;
	bench_summarize(&cell, samples[index], run->taken, top);
	if (run->answer != ERX_OK) {
		cell.status = "failed";
		cell.reason = "wrong result";
	} else if (run->checked == 0 || !counts_hold(index)) {
		cell.status = "failed";
		cell.reason = "the untimed check failed";
	} else if (index == VM_PROTECT && !faulted) {
		cell.status = "failed";
		cell.reason = ERX_BENCH_UNFAULTED;
	}
	bench_print(&cell);
}

void
bench_cells(uint32_t cpus, const erx_pack_view_t *pack)
{
	erx_bench_pair_t pair = { .cpus = { SERVICE_CPU, cpus - 1 } };
	bool faulted;

	if (erx_fiasco_launcher_find(pack, PROGRAM, &program_entry) != ERX_OK)
		bench_fail("erx: bench: no task program FAILED\n");
	if (cpus > 1)
		pair.before = bench_calibrate_on(0, cpus - 1);
	timed_wait(timed_start(SERVICE_CPU));
	faulted = protect_faults();
	if (cpus > 1)
		pair.after = bench_calibrate_on(1, cpus - 1);
	for (vm_cell_t index = 0; index < VM_CELLS; index++)
		print_cell(index, faulted);
	bench_print_clock(cpus > 1 ? &pair : NULL, cpus > 1 ? 1 : 0);
}
