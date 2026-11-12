/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The holder task of the interrupt suite (docs/design-stopgap.md, "Device records"),
 * loaded from the boot image by test/guest/native_irq/guest.c. The root made a device's
 * objects and passed them, as the domain library does for a device another domain holds;
 * here the holder maps the register window and the contiguous run, asks the run's DMA
 * address, binds the line to its own group and takes one delivery, acks it and unbinds.
 * Whatever names a group it does not home is refused. Its status is 0 on success, and
 * otherwise names the first step that went wrong; the root says which.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "test/guest/native_irq/holder.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define STACK_BYTES	(4 * PAGE)
/* How long the executor waits for the harness's character before the case fails. */
#define PATIENCE_NS	(UINT64_C(30000) * UINT64_C(1000000))
/* The executor's status while it runs. */
#define RUNNING		INT64_MIN

static uint64_t handles[HOLDER_HANDLES];
static _Atomic int64_t executor_status = RUNNING;

/* size bytes of the caller's space, reserved and neither committed nor mapped, at an address the service picks. */
static bool
reserve(uint64_t size, uint64_t *addr)
{
	return (erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr) == ERX_OK);
}

/*
 * The window maps read-write, as a driver maps its registers, and never as code. No
 * register is touched: only erx_device reaches a register window, and the root reads
 * the byte through its own.
 */
static int64_t
window_map(void)
{
	uint64_t addr;

	if (!reserve(PAGE, &addr))
		return (10);
	if (erx_vm_map(ERX_CAP_SELF, addr, PAGE, handles[HOLDER_WINDOW], 0, ERX_PROT_RX) != ERX_ERIGHTS)
		return (11);
	if (erx_vm_map(ERX_CAP_SELF, addr, PAGE, handles[HOLDER_WINDOW], 0, ERX_PROT_RW) != ERX_OK)
		return (12);
	return (0);
}

/*
 * The run maps, and its DMA address is the one the root got and wrote into its first
 * word; past its end it is ERX_ERANGE, and the window, which is no run, is ERX_ETYPE.
 */
static int64_t
run_check(void)
{
	uint64_t addr, dma, unused;

	if (!reserve(HOLDER_RUN_BYTES, &addr) ||
	    erx_vm_map(ERX_CAP_SELF, addr, HOLDER_RUN_BYTES, handles[HOLDER_RUN], 0, ERX_PROT_RW) != ERX_OK)
		return (20);
	if (erx_mem_dma_addr(handles[HOLDER_RUN], PAGE, &dma) != ERX_OK ||
	    dma != *(volatile const uint64_t *)(uintptr_t)addr + PAGE)
		return (21);
	if (erx_mem_dma_addr(handles[HOLDER_RUN], HOLDER_RUN_BYTES, &unused) != ERX_ERANGE)
		return (22);
	if (erx_mem_dma_addr(handles[HOLDER_WINDOW], 0, &unused) != ERX_ETYPE)
		return (23);
	return (0);
}

/*
 * A group the holder does not home is ERX_ETYPE, both as a bind's target and as the
 * group the root's own object is bound to, which the holder neither moves nor unbinds.
 */
static int64_t
foreign_groups_refused(void)
{
	if (erx_irq_bind(handles[HOLDER_LINE], handles[HOLDER_ROOT_GROUP], HOLDER_LABEL) != ERX_ETYPE)
		return (30);
	if (erx_irq_bind(handles[HOLDER_ROOT_SOFT], ERX_CAP_SELF, HOLDER_LABEL) != ERX_ETYPE)
		return (31);
	if (erx_irq_bind(handles[HOLDER_ROOT_SOFT], ERX_CAP_NULL, 0) != ERX_ETYPE)
		return (32);
	return (0);
}

/* The one label the executor takes once the line fires, or 0 when the patience runs out or a park fails. */
static uint64_t
line_label(void)
{
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;
	const erx_group_stat_t *const status = erx_fiasco_group_status();
	const uint64_t deadline = erx_time_monotonic_ns() + PATIENCE_NS;

	for (;;) {
		const uint64_t group = atomic_load_explicit(&status->epoch, memory_order_acquire);
		const uint64_t own = atomic_load_explicit(&status->exec[slot].epoch, memory_order_acquire);

		if (erx_group_take_ready(1) == 1)
			return (atomic_load_explicit(&erx_utcb_self()->mr[0], memory_order_relaxed));
		if (erx_park(group, own, deadline) != ERX_OK)
			return (0);
	}
}

/*
 * The bind and a second bind that moves the label, then the prompt for the harness's
 * character, its label and its ack. The line is level and its byte stays unread until
 * the root reads it, so the line fires again once the ack unmasks it, which shows the
 * holder's ack opened it; then an unbind.
 */
static int64_t
line_take(void)
{
	if (erx_irq_bind(handles[HOLDER_LINE], ERX_CAP_SELF, HOLDER_LABEL_FIRST) != ERX_OK)
		return (40);
	if (erx_irq_bind(handles[HOLDER_LINE], ERX_CAP_SELF, HOLDER_LABEL) != ERX_OK)
		return (41);
	erx_fiasco_task_write(HOLDER_PROMPT, sizeof(HOLDER_PROMPT) - 1);
	if (line_label() != HOLDER_LABEL)
		return (50);
	if (erx_irq_ack(handles[HOLDER_LINE]) != ERX_OK)
		return (60);
	if (line_label() != HOLDER_LABEL)
		return (61);
	if (erx_irq_bind(handles[HOLDER_LINE], ERX_CAP_NULL, 0) != ERX_OK)
		return (70);
	return (0);
}

static void
executor_main(uint64_t unused)
{
	int64_t status;

	(void)unused;
	status = window_map();
	if (status == 0)
		status = run_check();
	if (status == 0)
		status = foreign_groups_refused();
	if (status == 0)
		status = line_take();
	atomic_store_explicit(&executor_status, status, memory_order_release);
	erx_fiasco_sleep_forever();
}

/* A take needs an executor, and the first thread the root made is a worker. */
static int64_t
executor_start(void)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t stack, thread;

	if (!reserve(STACK_BYTES, &stack) || erx_vm_commit(ERX_CAP_SELF, stack, STACK_BYTES) != ERX_OK)
		return (1);
	start.regs.sp = stack + STACK_BYTES;
	start.regs.pc = (uint64_t)(uintptr_t)executor_main;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	if (erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK || erx_thread_start(thread) != ERX_OK)
		return (2);
	return (0);
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	const uint64_t argument = args[0];
	int64_t status;

	for (uint32_t index = 0; index < HOLDER_HANDLES; index++)
		handles[index] = (argument >> (index * HOLDER_HANDLE_BITS)) & HOLDER_HANDLE_MASK;
	status = executor_start();
	if (status != 0)
		return (status);
	while ((status = atomic_load_explicit(&executor_status, memory_order_acquire)) == RUNNING)
		erx_yield();
	return (status);
}
