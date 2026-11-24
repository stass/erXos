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
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/root_layout.h"
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
#define YIELD_ROUNDS	1000u
/* MODE_TURNS: the turns it takes the median of, and how long it tries. */
#define TURNS		15u
#define TURNS_DEADLINE_NS	UINT64_C(2000000000)
/* MODE_SHARE: how long its first thread blocks between looks at a spinner it waits for. */
#define SHARE_POLL_NS	UINT64_C(1000000)
/* QEMU virt's fw_cfg and RAM (hw/arm/virt.c), as test/guest/function_api/device_cases.c uses them. */
#define FW_CFG_PHYS	UINT64_C(0x9020000)
#define RAM_PHYS	UINT64_C(0x40000000)
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
	if (erx_vm_reserve(ERX_CAP_SELF, ALIAS_RW, PAGE, ERX_VM_FIXED, &reserved) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, ALIAS_RX, PAGE, ERX_VM_FIXED, &reserved) != ERX_OK)
		return (21);
	if (erx_vm_map(ERX_CAP_SELF, ALIAS_RW, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, ALIAS_RX, PAGE, mem, 0, ERX_PROT_RX) != ERX_OK)
		return (22);
	if (erx_vm_map(ERX_CAP_SELF, ALIAS_RW, PAGE, mem, 0, ERX_PROT_RW | ERX_PROT_RX) != ERX_EINVAL)
		return (23);
	return (0);
}

/* A committed stack of STACK_BYTES, or 0. */
static uint64_t
stack_make(void)
{
	uint64_t stack;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, STACK_BYTES, 0, &stack) != ERX_OK || erx_vm_commit(ERX_CAP_SELF, stack, STACK_BYTES) != ERX_OK)
		return (0);
	return (stack);
}

/*
 * A thread on the committed stack, on the CPU of mask if that CPU exists. Its word to
 * clear is set before it can run, or its exit could pass the word by.
 */
static int64_t
thread_spawn_on(uint64_t stack, void (*entry)(uint64_t), uint64_t argument, uint64_t mask, _Atomic uint32_t *clear,
    uint64_t *thread)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();

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

/* A thread on a committed stack of its own, which it keeps until the task ends. */
static int64_t
thread_spawn(void (*entry)(uint64_t), uint64_t argument, uint64_t mask, _Atomic uint32_t *clear, uint64_t *thread)
{
	const uint64_t stack = stack_make();

	return (stack != 0 ? thread_spawn_on(stack, entry, argument, mask, clear, thread) : 30);
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

static void
sleep_helper(uint64_t value)
{
	(void)value;
	erx_fiasco_sleep_forever();
}

/* Waits for the reaper to clear the word: the thread is gone, and its index on its way back. */
static void
thread_join_word(void)
{
	uint32_t value;

	while ((value = atomic_load_explicit(&clear_word, memory_order_acquire)) != 0)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&clear_word, value, ERX_FIASCO_UMTX_FOREVER);
}

/* Takes each odd count the first thread posts and posts the next even one. */
static void
yield_helper(uint64_t rounds)
{
	for (uint32_t round = 1; round <= rounds; round++) {
		while (atomic_load_explicit(&posted, memory_order_acquire) != 2 * round - 1)
			erx_yield();
		atomic_store_explicit(&posted, 2 * round, memory_order_release);
	}
	erx_thread_exit();
}

/*
 * Two threads pinned to CPU 0 hand a count back and forth, each spinning on erx_yield until
 * the other has moved it. Every wait lasts as long as a yield takes to hand the CPU over, so
 * a yield that keeps the CPU to the end of its time slice makes the case take seconds.
 */
static int64_t
mode_yield(void)
{
	uint64_t thread;
	int64_t step;

	if (erx_thread_set_affinity(erx_fiasco_thread_self()->index, UINT64_C(1)) != ERX_OK)
		return (80);
	atomic_store_explicit(&posted, 0, memory_order_relaxed);
	atomic_store_explicit(&clear_word, 1, memory_order_relaxed);
	step = thread_spawn(yield_helper, YIELD_ROUNDS, UINT64_C(1), &clear_word, &thread);
	if (step != 0)
		return (step);
	for (uint32_t round = 1; round <= YIELD_ROUNDS; round++) {
		atomic_store_explicit(&posted, 2 * round - 1, memory_order_release);
		while (atomic_load_explicit(&posted, memory_order_acquire) != 2 * round)
			erx_yield();
	}
	thread_join_word();
	return (0);
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

	if (erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &addr) != ERX_OK || erx_vm_commit(ERX_CAP_SELF, addr, PAGE) != ERX_OK)
		return (1);
	page = (volatile uint64_t *)(uintptr_t)addr;
	if (*page != 0)
		return (2);
	*page = 0x5a;
	if (erx_vm_decommit(ERX_CAP_SELF, addr, PAGE) != ERX_OK || erx_vm_commit(ERX_CAP_SELF, addr, PAGE) != ERX_OK || *page != 0)
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

/* Spins, counting in spin_counts[index], until the machine's end or the task's: it never stops by itself. */
static void
spin_helper(uint64_t index)
{
	for (;;)
		atomic_fetch_add_explicit(&spin_counts[index], 1, memory_order_relaxed);
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

_Static_assert(SPIN_THREADS <= CPUS_TRIED, "each spinner has its own count");

/*
 * The band case's load: spinners at the app level on CPU 0, the root's, until the root stops
 * the task. Only CPU 0 has the root's thread, so spinners elsewhere would only change the
 * host's load between the case's two windows. Each spinner has run, its count moved, before the
 * next starts and before the task's first thread sleeps.
 */
static int64_t
mode_spin(void)
{
	uint64_t thread;

	for (uint32_t spinner = 0; spinner < SPIN_THREADS; spinner++) {
		const int64_t step = thread_spawn(spin_helper, spinner, UINT64_C(1), NULL, &thread);

		if (step != 0)
			return (step);
		while (atomic_load_explicit(&spin_counts[spinner], memory_order_relaxed) == 0)
			erx_yield();
	}
	erx_fiasco_sleep_forever();
}

/*
 * The quantum case's load (docs/design-fiasco.md, "Bands"): this thread and one spinner, both
 * at the task's level on CPU 0, alone there while the root waits in its join, take the CPU a
 * quantum each in turn. A sample is the clock read between two reads of the spinner's count
 * that agree; a sample whose count differs from the last sample's follows a turn of the
 * spinner, so one turn of this thread runs from a sample after the spinner to the last sample
 * before it ran again. Interrupts and a host holding the vCPU back move no count, so they do
 * not end a turn. It skips its first turn, which began before it measured, and ends with the
 * median of the next TURNS, in microseconds, or a negative status (modes.h).
 */
static int64_t
mode_turns(void)
{
	_Atomic uint32_t *const spun = &spin_counts[0];
	uint64_t turns[TURNS], thread, start, last, now;
	uint32_t taken = 0, seen;
	bool started = false;
	int64_t step;

	if (erx_thread_set_affinity(erx_fiasco_thread_self()->index, UINT64_C(1)) != ERX_OK)
		return (TURNS_PINNED);
	step = thread_spawn(spin_helper, 0, UINT64_C(1), NULL, &thread);
	if (step != 0)
		return (-step);
	seen = atomic_load_explicit(spun, memory_order_relaxed);
	start = last = now = erx_fiasco_clock_ns();
	for (const uint64_t deadline = now + TURNS_DEADLINE_NS; taken < TURNS && now < deadline;) {
		const uint32_t count = atomic_load_explicit(spun, memory_order_relaxed);

		now = erx_fiasco_clock_ns();

		if (atomic_load_explicit(spun, memory_order_relaxed) != count)
			continue;
		if (count != seen) {
			if (started)
				turns[taken++] = last - start;
			started = true;
			start = now;
			seen = count;
		}
		last = now;
	}
	if (taken < TURNS)
		return (TURNS_NONE);
	/* An insertion sort: TURNS is small. */
	for (uint32_t at = 1; at < TURNS; at++)
		for (uint32_t before = at; before > 0 && turns[before - 1] > turns[before]; before--) {
			const uint64_t swap = turns[before];

			turns[before] = turns[before - 1];
			turns[before - 1] = swap;
		}
	return ((int64_t)(turns[TURNS / 2] / 1000));
}

/*
 * MODE_SHARE (docs/design-bench.md, "2. `sched`: how a CPU is shared"). Each recording spinner
 * reads the counter in a loop on the one CPU it shares with the others. A gap is the ticks
 * between two of its reads, the first counted from the plan's start, before any spinner
 * started, so a spinner that starts late shows the wait as a gap. A short gap is a pass of its
 * own loop, a long one a turn of another thread or an interrupt. Its loop period is its
 * shortest gap of a tick or more in the warm-up, which the counter's resolution bounds from
 * below. For each window it keeps its passes, its longest gap and its gaps over
 * SHARE_LOST_LOOPS loop periods, and publishes them; the read that passes a window's end is
 * that window's last, and a window no read fell in was one gap, its whole length, with no
 * pass. The windows are fixed before any spinner starts, so every spinner's windows are the
 * same span of the counter.
 */
typedef struct {
	uint64_t	iterations;
	uint64_t	longest;	/* ticks */
	uint64_t	lost;		/* gaps over SHARE_LOST_LOOPS loop periods */
} share_window_t;

typedef struct {
	uint64_t	start;		/* the counter before the first spinner starts */
	uint64_t	first;		/* the first window's start, after the warm-up */
	uint64_t	window;		/* each window's length, in ticks */
	uint32_t	windows;
} share_plan_t;

static share_plan_t share_plan;
static share_window_t share_windows[SHARE_SPINNERS_MAX][SHARE_WINDOWS_MAX];
/* By spinner: its loop period, UINT64_MAX when the warm-up gave it no gap of a tick or more. */
static uint64_t share_loops[SHARE_SPINNERS_MAX];
/* By spinner: how many of its windows are published, each released after its record. */
static _Atomic uint32_t share_published[SHARE_SPINNERS_MAX];

static uint64_t
share_window_end(uint32_t window)
{
	return (share_plan.first + (uint64_t)(window + 1) * share_plan.window);
}

static void
share_spinner(uint64_t index)
{
	uint64_t last = share_plan.start, loop = UINT64_MAX, lost_after;

	while (last < share_plan.first) {
		const uint64_t now = erx_fiasco_counter();

		if (now != last && now - last < loop)
			loop = now - last;
		last = now;
	}
	share_loops[index] = loop;
	lost_after = loop > UINT64_MAX / SHARE_LOST_LOOPS ? UINT64_MAX : loop * SHARE_LOST_LOOPS;
	for (uint32_t window = 0; window < share_plan.windows; window++) {
		const uint64_t end = share_window_end(window);
		share_window_t kept = { .longest = last < end ? 0 : share_plan.window };

		while (last < end) {
			const uint64_t now = erx_fiasco_counter();
			const uint64_t gap = now - last;

			kept.iterations++;
			if (gap > kept.longest)
				kept.longest = gap;
			if (gap > lost_after)
				kept.lost++;
			last = now;
		}
		share_windows[index][window] = kept;
		atomic_store_explicit(&share_published[index], window + 1, memory_order_release);
	}
	erx_fiasco_sleep_forever();
}

/* One line of SHARE_LINE_BYTES at most, built from text and decimal numbers. */
#define SHARE_LINE_BYTES	160u
/* The longest window line: its text, four 20-digit numbers and two of one digit, and its newline. */
_Static_assert(sizeof("share: window 9 spinner 7 iterations  longest  lost  loop \n") - 1 + 4 * 20 <= SHARE_LINE_BYTES,
    "a window line fits its buffer");
_Static_assert(SHARE_WINDOWS_MAX <= 10 && SHARE_SPINNERS_MAX <= 10, "a window and a spinner are one digit each");

typedef struct {
	char	bytes[SHARE_LINE_BYTES];
	size_t	used;
} share_line_t;

static void
share_text(share_line_t *line, const char *text)
{
	for (; *text != '\0' && line->used < SHARE_LINE_BYTES; text++)
		line->bytes[line->used++] = *text;
}

/* Appends " name value". */
static void
share_number(share_line_t *line, const char *name, uint64_t value)
{
	char digits[20];
	size_t count = 0;

	share_text(line, " ");
	share_text(line, name);
	share_text(line, " ");
	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0 && line->used < SHARE_LINE_BYTES)
		line->bytes[line->used++] = digits[--count];
}

/* Blocks until spinner has published every window, or the patience after the last one's end runs out. */
static bool
share_wait(uint32_t spinner, uint64_t hz)
{
	_Atomic uint32_t *const published = &share_published[spinner];
	const uint64_t patience = share_window_end(share_plan.windows - 1) + hz * SHARE_PATIENCE_MS / 1000;

	for (;;) {
		const uint32_t seen = atomic_load_explicit(published, memory_order_acquire);

		if (seen == share_plan.windows)
			return (true);
		if (erx_fiasco_counter() >= patience)
			return (false);
		(void)erx_umtx_wait((uint64_t)(uintptr_t)published, seen, erx_fiasco_clock_ns() + SHARE_POLL_NS);
	}
}

/*
 * The first thread, on CPU 0, starts the spinners on cpu and, once they have published every
 * window, writes through the task's write one line of the run and then one per window and
 * spinner in that order, which tools/lib/erx/share_windows.rb reads: no line is written while
 * a window runs. It ends with 0 once every line is written.
 */
static int64_t
mode_share(uint64_t argument)
{
	const uint32_t spinners = (uint32_t)(argument >> 8) & 0xffu, cpu = (uint32_t)(argument >> 16) & 0xffu;
	const uint32_t windows = (uint32_t)(argument >> 24) & 0xffu;
	const uint64_t window_ms = argument >> 32, hz = erx_fiasco_counter_hz();
	share_line_t line = { .used = 0 };
	uint64_t thread;

	if (spinners == 0 || spinners > SHARE_SPINNERS_MAX || cpu >= 64 || windows == 0 || windows > SHARE_WINDOWS_MAX ||
	    window_ms == 0 || window_ms > SHARE_WINDOW_MS_MAX)
		return (SHARE_ARGUMENT_BAD);
	if (erx_thread_set_affinity(erx_fiasco_thread_self()->index, UINT64_C(1)) != ERX_OK)
		return (SHARE_PINNED);
	share_plan.start = erx_fiasco_counter();
	share_plan.first = share_plan.start + hz * SHARE_WARMUP_MS / 1000;
	share_plan.window = hz * window_ms / 1000;
	share_plan.windows = windows;
	for (uint32_t spinner = 0; spinner < spinners; spinner++) {
		const int64_t step = thread_spawn(share_spinner, spinner, UINT64_C(1) << cpu, NULL, &thread);

		if (step != 0)
			return (SHARE_SPAWN + step);
	}
	for (uint32_t spinner = 0; spinner < spinners; spinner++)
		if (!share_wait(spinner, hz))
			return (SHARE_STARVED);
	share_text(&line, "share: run");
	share_number(&line, "hz", hz);
	share_number(&line, "spinners", spinners);
	share_number(&line, "cpu", cpu);
	share_number(&line, "windows", windows);
	share_number(&line, "window_ms", window_ms);
	share_text(&line, "\n");
	erx_fiasco_task_write(line.bytes, line.used);
	for (uint32_t window = 0; window < windows; window++)
		for (uint32_t spinner = 0; spinner < spinners; spinner++) {
			const share_window_t *const kept = &share_windows[spinner][window];

			line.used = 0;
			share_text(&line, "share:");
			share_number(&line, "window", window);
			share_number(&line, "spinner", spinner);
			share_number(&line, "iterations", kept->iterations);
			share_number(&line, "longest", kept->longest);
			share_number(&line, "lost", kept->lost);
			share_number(&line, "loop", share_loops[spinner]);
			share_text(&line, "\n");
			erx_fiasco_task_write(line.bytes, line.used);
		}
	return (0);
}

/* Requests until the task ends under it. */
static void
commit_helper(uint64_t addr)
{
	atomic_store_explicit(&posted, 1, memory_order_release);
	for (;;)
		(void)erx_vm_commit(ERX_CAP_SELF, addr, PAGE);
}

static int64_t
mode_race(void)
{
	uint64_t addr, thread;
	int64_t step;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &addr) != ERX_OK)
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
 * A task makes no line, which only the root makes, so a task asks the service directly
 * and that create answers ERX_ENOTSUP. A holder binds and unbinds an object it was given
 * through a handle of its own table, which holds none here, and triggers and acks it on
 * the capability at that handle's IRQ slot, of which it has none: ERX_CAP_NULL names no
 * entry (ERX_ESTALE), and none of the handles 1 to IRQ_SCAN of its own table answers ERX_OK
 * to any of the four, while the root holds an object of its own in its own slots.
 * Last, the task makes a doorbell of its own, which its end takes with it.
 */
static int64_t
mode_irq_refused(void)
{
	const uint64_t caller = erx_fiasco_thread_self()->index;
	const erx_fiasco_irq_create_request_t soft = { .caller = caller, .kind = ERX_IRQ_SOFT };
	const erx_fiasco_irq_create_request_t line = { .caller = caller, .kind = ERX_IRQ_LINE };
	const erx_fiasco_irq_create_request_t msi = { .caller = caller, .kind = ERX_IRQ_MSI };
	const erx_fiasco_irq_bind_request_t bind = { .caller = caller, .irq = ERX_CAP_NULL, .group = ERX_CAP_SELF };
	const erx_fiasco_irq_request_t none = { .caller = caller, .irq = ERX_CAP_NULL };
	erx_fiasco_reply_t reply;

	/* A line and an MSI are the root's alone. */
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &line, sizeof(line), &reply) != ERX_ENOTSUP ||
	    erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &msi, sizeof(msi), &reply) != ERX_ENOTSUP)
		return (81);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &bind, sizeof(bind), &reply) != ERX_ESTALE)
		return (82);
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_UNBIND, &none, sizeof(none), &reply) != ERX_ESTALE)
		return (83);
	if (erx_irq_ack(ERX_CAP_NULL) != ERX_ESTALE)
		return (84);
	if (erx_irq_trigger(ERX_CAP_NULL) != ERX_ESTALE)
		return (85);
	for (uint64_t handle = 1; handle <= IRQ_SCAN; handle++) {
		const erx_fiasco_irq_request_t held = { .caller = caller, .irq = handle };
		const erx_fiasco_irq_bind_request_t held_bind = { .caller = caller, .irq = handle, .group = ERX_CAP_SELF };

		if (erx_irq_ack(handle) == ERX_OK || erx_irq_trigger(handle) == ERX_OK ||
		    erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &held_bind, sizeof(held_bind), &reply) == ERX_OK ||
		    erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_UNBIND, &held, sizeof(held), &reply) == ERX_OK)
			return (100 + (int64_t)handle);
	}
	return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &soft, sizeof(soft), &reply) == ERX_OK ? 0 : 80);
}

/*
 * Only the root makes device memory, which the domain library then passes to a device's
 * holder, so each create from a task answers ERX_ENOTSUP: a physical object over fw_cfg's
 * registers, which nothing else in this machine maps (not the console UART, whose first
 * map would hand the log to the console), and a contiguous run of one page. A physical
 * object over RAM, which the root would get ERX_ERANGE for, is refused the same way, so
 * the refusal comes before the request is read and tells a task nothing about which
 * ranges are device memory. The status says which creates were not refused: 110 plus 1
 * for the physical, plus 2 for the contiguous, plus 4 for the one over RAM.
 */
static int64_t
mode_device_refused(void)
{
	uint64_t mem;
	const bool physical_served = erx_mem_create_physical(0, 0, FW_CFG_PHYS, PAGE,
	    ERX_MEM_ATTR_DEVICE, &mem) != ERX_ENOTSUP;
	const bool contiguous_served = erx_mem_create_contiguous(0, 0, PAGE, 0, &mem) !=
	    ERX_ENOTSUP;
	const bool ram_served = erx_mem_create_physical(0, 0, RAM_PHYS, PAGE,
	    ERX_MEM_ATTR_DEVICE, &mem) != ERX_ENOTSUP;

	if (!physical_served && !contiguous_served && !ram_served)
		return (0);
	return (110 + (physical_served ? 1 : 0) + (contiguous_served ? 2 : 0) +
	    (ram_served ? 4 : 0));
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

/*
 * In a task the root made with erx_space_create, as it makes a domain's: the launcher's
 * create, which would mark a child as a test task, is refused, and so is the raw write
 * of an escape sequence, and the judge finds none of its bytes in the serial log.
 */
static int64_t
mode_write_refused(void)
{
	static const char text[] = WRITE_REFUSED_TEXT;
	const erx_fiasco_space_create_request_t create = { .caller = erx_fiasco_thread_self()->index,
	    .parent = ERX_CAP_SELF, .cap_limit = 16 };
	const erx_fiasco_domain_space_create_request_t domain = { .space = create, .band = ERX_BAND_DRIVER,
	    .space_band = ERX_BAND_DRIVER, .cpuset = 1, .slice_us = ERX_SLICE_MIN_US };
	const erx_fiasco_task_write_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .len = sizeof(text) - 1 };
	erx_fiasco_reply_t reply;

	if (erx_fiasco_service_call(ERX_FIASCO_CALL_TEST_SPACE_CREATE, &create, sizeof(create), &reply) != ERX_ENOTSUP)
		return (141);
	/* Only the domain library, in the root, makes a domain row, whose band a task would otherwise pick. */
	if (erx_fiasco_service_call(ERX_FIASCO_CALL_DOMAIN_SPACE_CREATE, &domain, sizeof(domain), &reply) != ERX_ENOTSUP)
		return (142);
	erx_fiasco_utcb_store_bytes(text, request.len);
	return (erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_WRITE, &request, sizeof(request), &reply) == ERX_ENOTSUP ?
	    0 : 140);
}

/*
 * More thread creates, starts and exits than the threads' share of the root's slot pool
 * holds pairs, one thread at a time on one stack, which the next reuses once the reaper has
 * cleared the word: each exit's reap gives the thread's pair back, or a create runs the
 * share dry and answers ERX_ENOMEM.
 */
static int64_t
mode_pool_rounds(void)
{
	const uint64_t stack = stack_make();
	uint64_t thread;

	if (stack == 0)
		return (140);
	for (uint32_t round = 0; round < ERX_FIASCO_POOL_THREAD_PAIRS + 1; round++) {
		int64_t step;

		atomic_store_explicit(&clear_word, 1, memory_order_relaxed);
		step = thread_spawn_on(stack, said_helper, round, 0, &clear_word, &thread);
		if (step != 0)
			return (step);
		thread_join_word();
	}
	return (0);
}

int64_t
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	const uint64_t argument = args[0];
	int64_t step;

	/* Only MODE_SHARE takes parameters above its mode byte. */
	if ((argument & MODE_BITS) != MODE_SHARE && argument > MODE_BITS)
		return (90);
	switch (argument & MODE_BITS) {
	case MODE_SHARE:
		return (mode_share(argument));
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
	case MODE_SPIN:
		return (mode_spin());
	case MODE_TURNS:
		return (mode_turns());
	case MODE_RACE:
		return (mode_race());
	case MODE_LOG:
		return (mode_log());
	case MODE_WRITE:
		return (mode_write());
	case MODE_WRITE_REFUSED:
		return (mode_write_refused());
	case MODE_WAIT:
		for (uint32_t index = 0; index < WAIT_THREADS; index++) {
			uint64_t thread;

			step = thread_spawn(sleep_helper, 0, 0, NULL, &thread);
			if (step != 0)
				return (step);
		}
		erx_fiasco_sleep_forever();
	case MODE_IRQ_REFUSED:
		return (mode_irq_refused());
	case MODE_DEVICE_REFUSED:
		return (mode_device_refused());
	case MODE_YIELD:
		return (mode_yield());
	case MODE_POOL_ROUNDS:
		return (mode_pool_rounds());
	case MODE_MACHINE_END:
		return (erx_machine_end(0, ERX_END_RESET) == ERX_ENOTSUP ? 0 : 130);
	default:
		return (90);
	}
}
