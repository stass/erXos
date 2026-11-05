/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The second task's program, loaded from the boot image by test/guest/native_task/guest.c.
 * It reaches the root only through the service, so its way to report is its status, or
 * the crash frame of a fault: 0 is success, and any other status names the first step
 * that went wrong. What it logs and writes is what those cases' judges read, not a report.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/generated/calls.h"
#include "test/guest/native_task/modes.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define STACK_BYTES	(4 * PAGE)
#define CPUS_TRIED	4u
#define REWRITE_ROUNDS	2000u
/* movz w0, #value; ret */
#define INSN_MOVZ_W0(value)	(UINT32_C(0x52800000) | (((uint32_t)(value) & 0xffffu) << 5))
#define INSN_RET		UINT32_C(0xd65f03c0)

static _Atomic uint32_t posted, seen, helper_failed, thread_said;
static _Atomic uint32_t clear_word;
static _Atomic uint32_t spin_counts[CPUS_TRIED];

static void
code_write(uint32_t value)
{
	volatile uint32_t *const code = (volatile uint32_t *)(uintptr_t)ALIAS_RW;

	code[0] = INSN_MOVZ_W0(value);
	code[1] = INSN_RET;
	erx_fiasco_cache_make_coherent((uintptr_t)ALIAS_RX, 2 * sizeof(uint32_t));
}

static uint32_t
code_run(void)
{
	uint32_t (*const code)(void) = (uint32_t (*)(void))(uintptr_t)ALIAS_RX;

	return (code());
}

/* One page mapped twice, read-write and read-execute. */
static int64_t
aliases_map(void)
{
	uint64_t mem, reserved;

	if (erx_mem_create(0, PAGE, ERX_MEM_JIT, &mem) != ERX_OK)
		return (20);
	if (erx_vm_reserve(ALIAS_RW, PAGE, ERX_VM_FIXED, &reserved) != ERX_OK ||
	    erx_vm_reserve(ALIAS_RX, PAGE, ERX_VM_FIXED, &reserved) != ERX_OK)
		return (21);
	if (erx_vm_map(ERX_CAP_SELF, ALIAS_RW, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, ALIAS_RX, PAGE, mem, 0, ERX_PROT_RX) != ERX_OK)
		return (22);
	if (erx_vm_map(ERX_CAP_SELF, ALIAS_RW, PAGE, mem, 0, ERX_PROT_RW | ERX_PROT_RX) != ERX_EINVAL)
		return (23);
	return (0);
}

/*
 * A thread on its own committed stack, on the CPU of mask if that CPU exists. Its word to
 * clear is set before it can run, or its exit could pass the word by.
 */
static int64_t
thread_spawn(void (*entry)(uint64_t), uint64_t argument, uint64_t mask, _Atomic uint32_t *clear, uint64_t *thread)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t stack;

	if (erx_vm_reserve(0, STACK_BYTES, 0, &stack) != ERX_OK || erx_vm_commit(stack, STACK_BYTES) != ERX_OK)
		return (30);
	start.regs.gpr[0] = argument;
	start.regs.sp = stack + STACK_BYTES;
	start.regs.pc = (uint64_t)(uintptr_t)entry;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	if (erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, thread) != ERX_OK)
		return (31);
	if (clear != NULL && erx_fiasco_thread_set_clear_word(*thread, (uint64_t)(uintptr_t)clear) != ERX_OK)
		return (33);
	if (mask != 0)
		(void)erx_thread_set_affinity(*thread, mask);
	if (erx_thread_start(*thread) != ERX_OK)
		return (32);
	return (0);
}

/* The handshake is the order: each round's code is complete before its post. */
static void
rewrite_helper(uint64_t rounds)
{
	for (uint32_t round = 1; round <= rounds; round++) {
		while (atomic_load_explicit(&posted, memory_order_acquire) < round)
			erx_yield();
		__asm__ volatile("isb");
		if (code_run() != round)
			atomic_fetch_add_explicit(&helper_failed, 1, memory_order_relaxed);
		atomic_store_explicit(&seen, round, memory_order_release);
	}
	erx_thread_exit();
}

static void
said_helper(uint64_t value)
{
	atomic_store_explicit(&thread_said, (uint32_t)value, memory_order_release);
	erx_thread_exit();
}

/* Waits for the reaper to clear the word: the thread is gone, and its index on its way back. */
static void
thread_join_word(void)
{
	uint32_t value;

	while ((value = atomic_load_explicit(&clear_word, memory_order_acquire)) != 0)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&clear_word, value, ERX_FIASCO_UMTX_FOREVER);
}

/* Rewrites on this thread's CPU, and runs on the helper's, which the mask names. */
static int64_t
rewrite_across(uint64_t mask)
{
	uint64_t thread;
	int64_t step;

	atomic_store_explicit(&posted, 0, memory_order_relaxed);
	atomic_store_explicit(&seen, 0, memory_order_relaxed);
	atomic_store_explicit(&clear_word, 1, memory_order_relaxed);
	step = thread_spawn(rewrite_helper, REWRITE_ROUNDS, mask, &clear_word, &thread);
	if (step != 0)
		return (step);
	for (uint32_t round = 1; round <= REWRITE_ROUNDS; round++) {
		code_write(round);
		atomic_store_explicit(&posted, round, memory_order_release);
		while (atomic_load_explicit(&seen, memory_order_acquire) < round)
			erx_yield();
	}
	thread_join_word();
	return (atomic_load_explicit(&helper_failed, memory_order_relaxed) != 0 ? 41 : 0);
}

static int64_t
mode_service(void)
{
	volatile uint64_t *page;
	uint64_t addr, thread;
	int64_t step;

	if (erx_vm_reserve(0, PAGE, 0, &addr) != ERX_OK || erx_vm_commit(addr, PAGE) != ERX_OK)
		return (1);
	page = (volatile uint64_t *)(uintptr_t)addr;
	if (*page != 0)
		return (2);
	*page = 0x5a;
	if (erx_vm_decommit(addr, PAGE) != ERX_OK || erx_vm_commit(addr, PAGE) != ERX_OK || *page != 0)
		return (3);

	atomic_store_explicit(&clear_word, 1, memory_order_relaxed);
	step = thread_spawn(said_helper, 77, 0, &clear_word, &thread);
	if (step != 0)
		return (step);
	thread_join_word();
	if (atomic_load_explicit(&thread_said, memory_order_acquire) != 77)
		return (11);

	step = aliases_map();
	if (step != 0)
		return (step);
	code_write(42);
	if (code_run() != 42)
		return (24);
	code_write(43);
	if (code_run() != 43)
		return (25);

	/* Each other CPU in turn; a CPU that does not exist leaves the helper on this one. */
	for (uint32_t cpu = 1; cpu < CPUS_TRIED; cpu++) {
		step = rewrite_across(UINT64_C(1) << cpu);
		if (step != 0)
			return (step);
	}
	return (0);
}

/* Spins until the machine's end or the task's: it never stops by itself. */
static void
spin_helper(uint64_t cpu)
{
	for (;;)
		atomic_fetch_add_explicit(&spin_counts[cpu], 1, memory_order_relaxed);
}

static int64_t
mode_spin_stop(void)
{
	uint64_t thread;

	for (uint32_t cpu = 0; cpu < CPUS_TRIED; cpu++) {
		const int64_t step = thread_spawn(spin_helper, cpu, UINT64_C(1) << cpu, NULL, &thread);

		if (step != 0)
			return (step);
		while (atomic_load_explicit(&spin_counts[cpu], memory_order_relaxed) == 0)
			erx_yield();
	}
	return (STATUS_SPIN_STOP);
}

/* Requests until the task ends under it. */
static void
commit_helper(uint64_t addr)
{
	atomic_store_explicit(&posted, 1, memory_order_release);
	for (;;)
		(void)erx_vm_commit(addr, PAGE);
}

static int64_t
mode_race(void)
{
	uint64_t addr, thread;
	int64_t step;

	if (erx_vm_reserve(0, PAGE, 0, &addr) != ERX_OK)
		return (50);
	step = thread_spawn(commit_helper, addr, 0, NULL, &thread);
	if (step != 0)
		return (step);
	while (atomic_load_explicit(&posted, memory_order_acquire) == 0)
		erx_yield();
	(void)*(volatile uint64_t *)(uintptr_t)ALIAS_RW;
	return (51);
}

/*
 * Only the root binds IRQ objects: the stubs live in the root, so a task asks the service
 * directly. Each request names handle 0, which no object holds, so without the refusal
 * these calls answer ERX_EINVAL, not ERX_ENOTSUP.
 */
static int64_t
mode_irq_refused(void)
{
	const uint64_t caller = erx_fiasco_thread_self()->index;
	const erx_fiasco_irq_create_request_t create = { .caller = caller, .kind = ERX_IRQ_SOFT };
	const erx_fiasco_irq_bind_request_t bind = { .caller = caller };
	const erx_fiasco_irq_request_t object = { .caller = caller };
	erx_fiasco_reply_t reply;

	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &create, sizeof(create), &reply) != ERX_ENOTSUP)
		return (80);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &bind, sizeof(bind), &reply) != ERX_ENOTSUP)
		return (81);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_ACK, &object, sizeof(object), &reply) != ERX_ENOTSUP)
		return (82);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_TRIGGER, &object, sizeof(object), &reply) != ERX_ENOTSUP)
		return (83);
	return (0);
}

/*
 * The forgery goes out with its newlines and an escape sequence, and the judge reads
 * the serial log for it. A length past the UTCB, one past its register's width and a
 * thread index past the table are refused, and the longest line is not.
 */
static int64_t
mode_log(void)
{
	static const char forged[] = "\n" LOG_FORGED_LINE "\n\033[2J";
	erx_utcb_t *const utcb = erx_utcb_self();
	const uint64_t self = erx_fiasco_thread_self()->index;
	const erx_fiasco_debug_log_request_t wide = { .caller = self, .len = UINT64_C(1) << 32 };
	const erx_fiasco_debug_log_request_t past_table = { .caller = ERX_FIASCO_THREADS_MAX, .len = 1 };
	erx_fiasco_reply_t reply;

	for (size_t done = 0; done < sizeof(forged) - 1; done += sizeof(uint64_t)) {
		const size_t left = sizeof(forged) - 1 - done;
		uint64_t word = 0;

		__builtin_memcpy(&word, forged + done, left < sizeof(word) ? left : sizeof(word));
		(void)erx_utcb_mr_store(utcb, done / sizeof(word), word);
	}
	if (erx_debug_log((erx_utcb_length_t){ .raw = sizeof(forged) - 1 }) != ERX_OK)
		return (80);
	if (erx_debug_log((erx_utcb_length_t){ .raw = ERX_UTCB_BYTES_MAX + 1 }) != ERX_EINVAL)
		return (81);
	if (erx_fiasco_service_call(ERX_CALL_DEBUG_LOG, &wide, sizeof(wide), &reply) != ERX_EINVAL)
		return (82);
	if (erx_fiasco_service_call(ERX_CALL_DEBUG_LOG, &past_table, sizeof(past_table), &reply) != ERX_EINVAL)
		return (83);
	return (erx_debug_log((erx_utcb_length_t){ .raw = ERX_UTCB_BYTES_MAX }) == ERX_OK ? 0 : 84);
}

/*
 * The judge compares the serial log with these bytes. A length past the UTCB, one past
 * its register's width and an index past the thread table are refused, and nothing is written.
 */
static int64_t
mode_write(void)
{
	static uint8_t bytes[sizeof(WRITE_HEAD) - 1 + WRITE_RUN_BYTES + 1];
	const uint64_t self = erx_fiasco_thread_self()->index;
	const erx_fiasco_task_write_request_t past = { .caller = self, .len = ERX_UTCB_BYTES_MAX + 1 };
	const erx_fiasco_task_write_request_t wide = { .caller = self, .len = UINT64_C(1) << 32 };
	const erx_fiasco_task_write_request_t past_table = { .caller = ERX_FIASCO_THREADS_MAX, .len = 1 };
	erx_fiasco_reply_t reply;

	__builtin_memcpy(bytes, WRITE_HEAD, sizeof(WRITE_HEAD) - 1);
	for (uint32_t index = 0; index < WRITE_RUN_BYTES; index++)
		bytes[sizeof(WRITE_HEAD) - 1 + index] = (uint8_t)index;
	bytes[sizeof(bytes) - 1] = '\n';
	erx_fiasco_task_write(bytes, sizeof(bytes));
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_WRITE, &past, sizeof(past), &reply) != ERX_EINVAL)
		return (90);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_WRITE, &wide, sizeof(wide), &reply) != ERX_EINVAL)
		return (91);
	return (erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_WRITE, &past_table, sizeof(past_table), &reply) == ERX_EINVAL ? 0 : 92);
}

int64_t
erx_task_main(uint64_t argument)
{
	int64_t step;

	switch (argument) {
	case MODE_SERVICE:
		return (mode_service());
	case MODE_WRITE_RX:
		step = aliases_map();
		if (step != 0)
			return (step);
		*(volatile uint64_t *)(uintptr_t)ALIAS_RX = 1;
		return (60);
	case MODE_RUN_RW:
		step = aliases_map();
		if (step != 0)
			return (step);
		code_write(42);
		return (((uint32_t (*)(void))(uintptr_t)ALIAS_RW)() != 0 ? 61 : 62);
	case MODE_NO_JIT: {
		uint64_t mem;

		return (erx_mem_create(0, PAGE, ERX_MEM_JIT, &mem) == ERX_ERIGHTS ? 0 : 70);
	}
	case MODE_SPIN_STOP:
		return (mode_spin_stop());
	case MODE_RACE:
		return (mode_race());
	case MODE_LOG:
		return (mode_log());
	case MODE_WRITE:
		return (mode_write());
	case MODE_WAIT:
		erx_fiasco_sleep_forever();
	case MODE_IRQ_REFUSED:
		return (mode_irq_refused());
	default:
		return (90);
	}
}
