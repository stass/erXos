/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What the vm benchmark's root (vm.c) and its test task (vm_task.c) share: the cells, the
 * page the root maps into the timed task, through which the root names the task's CPU,
 * acknowledges each step of the task's page check once it has read the free page count,
 * and takes back the runs, and the two arguments the program tells its two tasks apart by.
 */

#ifndef ERX_NATIVE_BENCH_VM_H
#define ERX_NATIVE_BENCH_VM_H

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"

#if !defined(ERX_BENCH_FAST_WARMUP) || !defined(ERX_BENCH_FAST_SAMPLES)
#error "the build passes the fast profile's sizes"
#endif

/* The landing cells, each of one page, in the order the task times and the root prints them. */
typedef enum {
	VM_RESERVE,
	VM_COMMIT,
	VM_TOUCH,
	VM_PROTECT,
	VM_DECOMMIT,
	VM_RELEASE,
	VM_CELLS
} vm_cell_t;

/*
 * The steps of the task's page check at which the root reads the free page count: before
 * the page is reserved, once it is committed, once it is decommitted, and once the range
 * is released after a recommit.
 */
typedef enum {
	VM_STEP_NONE,
	VM_STEP_BEFORE,
	VM_STEP_COMMITTED,
	VM_STEP_DECOMMITTED,
	VM_STEP_RELEASED,
	VM_STEPS
} vm_step_t;

/*
 * A cell's timed run: its batch (erx_bench_batch_for of the warm-up median), the samples
 * taken, each a batch's ticks over its operations, rounded down, and the first answer that
 * was not ERX_OK, which ends the run, or ERX_OK. checked is whether the task's part of the
 * cell's untimed check passed.
 */
typedef struct {
	uint64_t	batch;
	uint64_t	taken;
	int64_t		answer;
	uint32_t	checked;
} vm_run_t;

/*
 * The page the root maps at VM_PAGE_ADDR in the timed task, its argument. The root writes
 * cpu before the task starts. The task raises step at each step of its page check and
 * waits until the root has read the free page count and set answered to that step; it
 * raises progress after each sample, so the root sees it is alive, and done once it has
 * written every run, after which it makes no request.
 */
typedef struct {
	uint32_t		cpu;
	_Atomic uint32_t	step;
	_Atomic uint32_t	answered;
	_Atomic uint32_t	progress;
	_Atomic uint32_t	done;
	vm_run_t		runs[VM_CELLS];
	uint64_t		samples[VM_CELLS][ERX_BENCH_FAST_SAMPLES];
} vm_page_t;

#define VM_PAGE_BYTES	((sizeof(vm_page_t) + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE)

/*
 * The program's argument: VM_PAGE_ADDR makes it the timed task, VM_FAULT_ADDR the
 * disposable task, which commits the page there, writes it, protects it to read-only and
 * writes it again, the write that must fault. The root reserves both addresses in the
 * task it starts; anything else is VM_STATUS_ARGUMENT.
 */
#define VM_PAGE_ADDR		UINT64_C(0x4000400000)
#define VM_FAULT_ADDR		UINT64_C(0x4000800000)
#define VM_STATUS_ARGUMENT	1
#define VM_STATUS_AFFINITY	2
/* The disposable task's status when its write to the read-only page went through, and when a call failed first. */
#define VM_STATUS_WRITTEN	3
#define VM_STATUS_SETUP		4

#endif /* ERX_NATIVE_BENCH_VM_H */
