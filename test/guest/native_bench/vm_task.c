/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The vm benchmark's test task, loaded from the boot image by vm.c (vm.h names its two
 * arguments). As the timed task it times each cell's call on one page, then makes, once
 * and untimed, the check test/guest/native_memory makes for that call; as the disposable
 * task it writes a page it protected to read-only, the write that must fault.
 *
 * A cell's operation runs in batches over the pages of one reserved area: each batch is
 * prepared untimed (the pages committed, say), its operations timed back to back, then
 * undone untimed, so every batch starts from the same state.
 *
 * Built with ERX_BENCH_SEED_PROTECT_IGNORED, every protect answers ERX_OK without calling
 * the service: the timed run and the reads pass, and only the disposable task's write,
 * which then goes through, shows it.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/bench/bench_hist.h"
#include "test/guest/native_bench/vm.h"

#define PAGE	((uint64_t)ERX_PAGE_SIZE)

/* One step of a batch on the page at index at of the area; ERX_OK, or the call's answer. */
typedef int (*vm_act_t)(uint64_t at);

/* A cell's operation: what prepares a page for it, the timed act, and what undoes the act. */
typedef struct {
	vm_act_t	prepare;
	vm_act_t	act;
	vm_act_t	undo;
} vm_op_t;

static erx_bench_hist_t scratch;
/* The area a batch's committing cells work in, and the ranges the reserving cells take. */
static uint64_t area;
static uint64_t ranges[ERX_BENCH_BATCH_MAX];

static int
vm_protect(uint64_t addr, uint32_t prot)
{
#ifdef ERX_BENCH_SEED_PROTECT_IGNORED
	(void)addr;
	(void)prot;
	return (ERX_OK);
#else
	return (erx_space_protect(ERX_CAP_SELF, addr, PAGE, prot));
#endif
}

static uint64_t
page_at(uint64_t at)
{
	return (area + at * PAGE);
}

static void
word_put(uint64_t addr, uint64_t value)
{
	*(volatile uint64_t *)(uintptr_t)addr = value;
}

static uint64_t
word_at(uint64_t addr)
{
	return (*(volatile uint64_t *)(uintptr_t)addr);
}

static int
nothing(uint64_t at)
{
	(void)at;
	return (ERX_OK);
}

static int
reserve_one(uint64_t at)
{
	return (erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &ranges[at]));
}

static int
release_one(uint64_t at)
{
	return (erx_vm_release(ERX_CAP_SELF, ranges[at], PAGE));
}

static int
commit_one(uint64_t at)
{
	return (erx_vm_commit(ERX_CAP_SELF, page_at(at), PAGE));
}

static int
decommit_one(uint64_t at)
{
	return (erx_vm_decommit(ERX_CAP_SELF, page_at(at), PAGE));
}

/* The first write to a committed page. */
static int
touch_one(uint64_t at)
{
	word_put(page_at(at), at + 1);
	return (ERX_OK);
}

static int
protect_read_only(uint64_t at)
{
	return (vm_protect(page_at(at), ERX_PROT_R));
}

static int
unprotect_decommit(uint64_t at)
{
	const int status = vm_protect(page_at(at), ERX_PROT_RW);

	return (status != ERX_OK ? status : decommit_one(at));
}

static const vm_op_t ops[VM_CELLS] = {
	[VM_RESERVE] = { nothing, reserve_one, release_one },
	[VM_COMMIT] = { nothing, commit_one, decommit_one },
	[VM_TOUCH] = { commit_one, touch_one, decommit_one },
	[VM_PROTECT] = { commit_one, protect_read_only, unprotect_decommit },
	[VM_DECOMMIT] = { commit_one, decommit_one, nothing },
	[VM_RELEASE] = { reserve_one, release_one, nothing },
};

/* One batch of n operations: its ticks in *ticks, and ERX_OK, or the first other answer. */
static int
batch_run(const vm_op_t *op, uint64_t n, uint64_t *ticks)
{
	uint64_t start;
	int status = ERX_OK;

	for (uint64_t at = 0; at < n && status == ERX_OK; at++)
		status = op->prepare(at);
	start = erx_fiasco_counter();
	for (uint64_t at = 0; at < n && status == ERX_OK; at++)
		status = op->act(at);
	*ticks = erx_fiasco_counter() - start;
	for (uint64_t at = 0; at < n && status == ERX_OK; at++)
		status = op->undo(at);
	return (status);
}

/* ERX_BENCH_FAST_WARMUP batches of one, then ERX_BENCH_FAST_SAMPLES batches into samples. */
static vm_run_t
cell_time(vm_page_t *page, const vm_op_t *op, uint64_t *samples)
{
	vm_run_t run = { .batch = 1, .taken = 0, .answer = ERX_OK, .checked = 0 };
	uint64_t ticks;

	for (unsigned at = 0; at < ERX_BENCH_HIST_BUCKETS; at++)
		scratch.count[at] = 0;
	scratch.samples = 0;
	for (uint32_t warm = 0; warm < ERX_BENCH_FAST_WARMUP; warm++) {
		run.answer = batch_run(op, 1, &ticks);
		if (run.answer != ERX_OK)
			return (run);
		erx_bench_hist_add(&scratch, ticks);
	}
	run.batch = erx_bench_batch_for(erx_bench_hist_median(&scratch));
	for (; run.taken < ERX_BENCH_FAST_SAMPLES; run.taken++) {
		run.answer = batch_run(op, run.batch, &ticks);
		if (run.answer != ERX_OK)
			return (run);
		samples[run.taken] = ticks / run.batch;
		atomic_fetch_add_explicit(&page->progress, 1, memory_order_release);
	}
	return (run);
}

/* A word at each end of a page, so a wrong page shows wherever it differs. */
static void
page_fill(uint64_t addr, uint64_t seed)
{
	word_put(addr, seed);
	word_put(addr + PAGE - sizeof(uint64_t), ~seed);
}

static bool
page_holds(uint64_t addr, uint64_t seed)
{
	return (word_at(addr) == seed && word_at(addr + PAGE - sizeof(uint64_t)) == ~seed);
}

static bool
page_is_zero(uint64_t addr)
{
	for (uint64_t offset = 0; offset < PAGE; offset += sizeof(uint64_t))
		if (word_at(addr + offset) != 0)
			return (false);
	return (true);
}

/* Raises step and waits until the root has read the free page count for it. */
static void
step_say(vm_page_t *page, vm_step_t step)
{
	atomic_store_explicit(&page->step, step, memory_order_release);
	while (atomic_load_explicit(&page->answered, memory_order_acquire) != step)
		;
}

/*
 * The untimed checks, on a page of its own: committed, it reads zero; written, it reads
 * back, and still does after a protect to read-only and back; decommitted and committed
 * again, it reads zero. The root holds the free page count at each step to the call made
 * before it. A call that fails leaves every later check failed, but every step is still
 * said, so the root's reads stay in order.
 */
static void
cells_check(vm_page_t *page)
{
	uint64_t addr = 0;
	bool reserved, committed, ok;

	step_say(page, VM_STEP_BEFORE);
	reserved = erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &addr) == ERX_OK;
	committed = reserved && erx_vm_commit(ERX_CAP_SELF, addr, PAGE) == ERX_OK;
	page->runs[VM_COMMIT].checked = committed && page_is_zero(addr);
	step_say(page, VM_STEP_COMMITTED);
	if (committed)
		page_fill(addr, 0xd0);
	page->runs[VM_TOUCH].checked = committed && page_holds(addr, 0xd0);
	ok = committed && vm_protect(addr, ERX_PROT_R) == ERX_OK && page_holds(addr, 0xd0) &&
	    vm_protect(addr, ERX_PROT_RW) == ERX_OK && page_holds(addr, 0xd0);
	page->runs[VM_PROTECT].checked = ok;
	ok = committed && erx_vm_decommit(ERX_CAP_SELF, addr, PAGE) == ERX_OK;
	step_say(page, VM_STEP_DECOMMITTED);
	page->runs[VM_DECOMMIT].checked = ok && erx_vm_commit(ERX_CAP_SELF, addr, PAGE) == ERX_OK && page_is_zero(addr);
	ok = reserved && erx_vm_release(ERX_CAP_SELF, addr, PAGE) == ERX_OK;
	page->runs[VM_RESERVE].checked = ok;
	page->runs[VM_RELEASE].checked = ok;
	step_say(page, VM_STEP_RELEASED);
}

static int64_t
timed_task(vm_page_t *page)
{
	if (erx_thread_set_affinity(erx_fiasco_thread_self()->index, UINT64_C(1) << page->cpu) != ERX_OK)
		return (VM_STATUS_AFFINITY);
	if (erx_vm_reserve(ERX_CAP_SELF, 0, ERX_BENCH_BATCH_MAX * PAGE, 0, &area) != ERX_OK)
		return (VM_STATUS_SETUP);
	for (vm_cell_t cell = 0; cell < VM_CELLS; cell++)
		page->runs[cell] = cell_time(page, &ops[cell], page->samples[cell]);
	cells_check(page);
	return (erx_vm_release(ERX_CAP_SELF, area, ERX_BENCH_BATCH_MAX * PAGE) == ERX_OK ? 0 : VM_STATUS_SETUP);
}

/* The disposable task: a write to its read-only page, which must fault, so it never returns from it. */
static int64_t
disposable_task(void)
{
	if (erx_vm_commit(ERX_CAP_SELF, VM_FAULT_ADDR, PAGE) != ERX_OK)
		return (VM_STATUS_SETUP);
	page_fill(VM_FAULT_ADDR, 0xe0);
	if (vm_protect(VM_FAULT_ADDR, ERX_PROT_R) != ERX_OK)
		return (VM_STATUS_SETUP);
	word_put(VM_FAULT_ADDR, 0xe1);
	return (VM_STATUS_WRITTEN);
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	int64_t status;

	switch (args[0]) {
	case VM_PAGE_ADDR: {
		vm_page_t *const page = (vm_page_t *)(uintptr_t)VM_PAGE_ADDR;

		status = timed_task(page);
		atomic_store_explicit(&page->done, 1, memory_order_release);
		return (status);
	}
	case VM_FAULT_ADDR:
		return (disposable_task());
	default:
		return (VM_STATUS_ARGUMENT);
	}
}
