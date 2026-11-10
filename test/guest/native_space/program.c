/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The tasks of the mapping suite, loaded from the boot image by
 * test/guest/native_space/guest.c, which maps their pages, or passes them a handle to
 * map, before their first thread runs. The status is the report: 0 is success, any
 * other names the first step that went wrong, and a revoked reader's fault goes to
 * its fault gate, where it stays blocked until the root stops it.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PAGE	((uint64_t)ERX_PAGE_SIZE)
/* The handle table of each space the creator makes. */
#define CREATED_CAP_LIMIT	16u

int64_t	erx_task_main(uint64_t);

/* A word of the program's writable data, of which each task has its own copy. */
static volatile uint64_t data_word = DATA_PATTERN;

static uint64_t
shared_word(uint64_t page)
{
	return (atomic_load_explicit((_Atomic uint64_t *)(uintptr_t)(SHARED_ADDR + page * PAGE), memory_order_acquire));
}

/* Writes the writer's pattern on each page after finding the root's there. */
static int64_t
mode_writer(void)
{
	for (uint64_t page = 0; page < SHARED_PAGES; page++) {
		if (shared_word(page) != ROOT_PATTERN + page)
			return (10);
		atomic_store_explicit((_Atomic uint64_t *)(uintptr_t)(SHARED_ADDR + page * PAGE), WRITER_PATTERN + page,
		    memory_order_release);
	}
	return (erx_vm_release(ERX_CAP_SELF, SHARED_ADDR, SHARED_PAGES * PAGE) == ERX_OK ? 0 : 11);
}

static int64_t
mode_reader(void)
{
	for (uint64_t page = 0; page < SHARED_PAGES; page++)
		if (shared_word(page) != WRITER_PATTERN + page)
			return (20);
	return (erx_vm_release(ERX_CAP_SELF, SHARED_ADDR, SHARED_PAGES * PAGE) == ERX_OK ? 0 : 21);
}

/* Reads until the root's destroy revokes the page, so the next read faults at the task's gate. */
static int64_t
mode_revoked(uint64_t slot)
{
	if (shared_word(0) != ROOT_PATTERN)
		return (30);
	atomic_store_explicit((_Atomic uint64_t *)(uintptr_t)(SIGNAL_ADDR + slot * sizeof(uint64_t)), 1,
	    memory_order_release);
	while (shared_word(0) == ROOT_PATTERN)
		;
	return (31);
}

/*
 * Spaces below its own: a child, and a grandchild below the child, each reporting to a
 * gate of its own, and the child given a page of its object; then a parent that names
 * no space, and the child's first thread, which only the root makes. Its end stops
 * both, children first, and frees them.
 */
static int64_t
mode_creator(void)
{
	uint64_t gate, mem, child, grandchild, refused;

	if (erx_gate_create(0, &gate) != ERX_OK || erx_mem_create(0, PAGE, 0, &mem) != ERX_OK)
		return (40);
	if (erx_space_create(0, ERX_CAP_SELF, gate, 1, 0, CREATED_CAP_LIMIT, &child) != ERX_OK)
		return (41);
	if (erx_space_create(0, child, gate, 2, 0, CREATED_CAP_LIMIT, &grandchild) != ERX_OK)
		return (42);
	if (erx_vm_reserve(child, SHARED_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) != ERX_OK ||
	    erx_vm_map(child, SHARED_ADDR, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK)
		return (43);
	if (erx_space_create(0, mem, gate, 3, 0, CREATED_CAP_LIMIT, &refused) != ERX_ETYPE)
		return (44);
	/* Only the root makes a created space's first thread. */
	if (erx_thread_create(0, child, 0, ERX_THREAD_CLASS_WORKER, &refused) != ERX_ENOTSUP)
		return (45);
	return (0);
}

/* The first thread of a task the root started: its argument arrives whole. */
static int64_t
mode_first(uint64_t argument)
{
	return (argument >> SLOT_SHIFT == FIRST_TAG ? FIRST_STATUS : 50);
}

/* Maps the object whose handle the root passed into this task, finds the root's pattern read-only, and releases the range. */
static int64_t
mode_holder(uint64_t mem)
{
	if (erx_vm_map(ERX_CAP_SELF, SHARED_ADDR, SHARED_PAGES * PAGE, mem, 0, ERX_PROT_R) != ERX_OK)
		return (50);
	for (uint64_t page = 0; page < SHARED_PAGES; page++)
		if (shared_word(page) != ROOT_PATTERN + page)
			return (51);
	return (erx_vm_release(ERX_CAP_SELF, SHARED_ADDR, SHARED_PAGES * PAGE) == ERX_OK ? 0 : 52);
}

/* Reads the wall clock from the time page the service mapped: the root's first setting, then its second. */
static int64_t
mode_time(void)
{
	const uint64_t deadline = erx_time_monotonic_ns() + TIME_SLACK_NS;
	uint64_t wall;

	if (!erx_time_wall_ns(&wall) || wall < TIME_FIRST_NS || wall - TIME_FIRST_NS > TIME_SLACK_NS)
		return (60);
	atomic_store_explicit((_Atomic uint64_t *)(uintptr_t)SIGNAL_ADDR, 1, memory_order_release);
	do {
		if (!erx_time_wall_ns(&wall))
			return (61);
		if (erx_time_monotonic_ns() > deadline)
			return (62);
	} while (wall < TIME_SECOND_NS);
	return (wall - TIME_SECOND_NS > TIME_SLACK_NS ? 63 : 0);
}

/* What the bell's executor ends with, BELL_RUNNING until it ends. */
#define BELL_RUNNING	INT64_C(-1)
#define BELL_WAIT_NS	UINT64_C(10000000000)
#define BELL_STACK_BYTES	16384u

static _Alignas(16) uint8_t bell_stack[BELL_STACK_BYTES];
static _Atomic int64_t bell_result = BELL_RUNNING;

/*
 * An executor of the task's home group: parks until a take gives its bell's label, then
 * acks the bell and rings the root's object, from this task's own handles to both.
 */
static void
bell_executor(uint64_t argument)
{
	const uint64_t bell = argument >> BELL_SHIFT & HANDLE_MASK, back = argument >> BACK_SHIFT & HANDLE_MASK;
	const erx_group_stat_t *const status = erx_fiasco_group_status();
	const uint32_t slot = erx_fiasco_thread_self()->executor_slot;
	const uint64_t deadline = erx_fiasco_clock_ns() + BELL_WAIT_NS;
	uint64_t label = 0;
	int64_t result = 61;
	int taken = 0;

	while (taken == 0) {
		const uint64_t group_epoch = atomic_load_explicit(&status->epoch, memory_order_acquire);
		const uint64_t own = atomic_load_explicit(&status->exec[slot].epoch, memory_order_acquire);

		taken = erx_group_take_ready(1);
		if (taken == 0 && erx_park(group_epoch, own, deadline) == ERX_ETIMEDOUT)
			break;
	}
	if (taken == 1 && erx_utcb_mr_load(erx_utcb_self(), 0, &label) && label == BELL_LABEL)
		result = erx_irq_ack(bell) == ERX_OK && erx_irq_trigger(back) == ERX_OK ? 0 : 62;
	atomic_store_explicit(&bell_result, result, memory_order_release);
	erx_thread_exit();
}

/* The first thread, a worker: starts the executor, and ends with its result once it has one. */
static int64_t
mode_bell(uint64_t argument)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	const uint64_t deadline = erx_fiasco_clock_ns() + 2 * BELL_WAIT_NS;
	int64_t result;
	uint64_t thread;

	start.regs.gpr[0] = argument;
	start.regs.sp = (uint64_t)(uintptr_t)(bell_stack + sizeof(bell_stack));
	start.regs.pc = (uint64_t)(uintptr_t)bell_executor;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		(void)erx_utcb_mr_store(erx_utcb_self(), word, words[word]);
	if (erx_thread_create(0, 0, ERX_CAP_NULL, ERX_THREAD_CLASS_EXECUTOR, &thread) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK)
		return (60);
	while ((result = atomic_load_explicit(&bell_result, memory_order_acquire)) == BELL_RUNNING &&
	    erx_fiasco_clock_ns() < deadline)
		erx_yield();
	return (result == BELL_RUNNING ? 63 : result);
}

static bool
bytes_equal(const uint8_t *bytes, const char *text, size_t length)
{
	for (size_t index = 0; index < length; index++)
		if (bytes[index] != (uint8_t)text[index])
			return (false);
	return (true);
}

/* Whether entry is the file at path, holding these bytes, which it reads where the root mapped the slice. */
static bool
entry_is(const erx_release_entry_t *entry, const char *contents, size_t size)
{
	return (entry->size == size && bytes_equal((const uint8_t *)(uintptr_t)(SLICE_ADDR + entry->offset), contents, size));
}

/*
 * Lists the slice the root passed with erx_release_entry, as a domain's runtime lists
 * its release: each path without its domains/sample/ prefix, the long one whole from
 * its pieces, each file's bytes at its offset from the mapping, and no third entry.
 */
static int64_t
mode_release(uint64_t slice)
{
	static erx_release_entry_t entry;
	const size_t part = sizeof(RELEASE_LONG_PART) - 1;

	if (erx_fiasco_release_entry(slice, 0, true, &entry) != ERX_OK || entry.path_length != sizeof(RELEASE_ALPHA) - 1 ||
	    !bytes_equal(entry.path, RELEASE_ALPHA, entry.path_length) ||
	    !entry_is(&entry, RELEASE_ALPHA_BYTES, sizeof(RELEASE_ALPHA_BYTES) - 1))
		return (80);
	if (erx_fiasco_release_entry(slice, 1, true, &entry) != ERX_OK ||
	    entry.path_length != RELEASE_LONG_PARTS * part + sizeof(RELEASE_LONG_TAIL) - 1 ||
	    !entry_is(&entry, RELEASE_LONG_BYTES, sizeof(RELEASE_LONG_BYTES) - 1))
		return (81);
	for (size_t index = 0; index < RELEASE_LONG_PARTS; index++)
		if (!bytes_equal(entry.path + index * part, RELEASE_LONG_PART, part))
			return (82);
	if (!bytes_equal(entry.path + RELEASE_LONG_PARTS * part, RELEASE_LONG_TAIL, sizeof(RELEASE_LONG_TAIL) - 1))
		return (83);
	return (erx_fiasco_release_entry(slice, 2, false, &entry) == ERX_ERANGE ? 0 : 84);
}

static int64_t
mode_data(void)
{
	if (data_word != DATA_PATTERN)
		return (100);
	data_word = WRITER_PATTERN;
	return (data_word == WRITER_PATTERN ? 0 : 101);
}

/* The first word of erx_task_main's code, through the task's own mapping of it. */
static volatile uint64_t *
code_word(void)
{
	return ((volatile uint64_t *)(uintptr_t)&erx_task_main);
}

/* A write to code shared with every task that runs the image: it faults, so the return is a failure. */
static int64_t
mode_code_write(void)
{
	*code_word() = WRITER_PATTERN;
	return (110);
}

int64_t
erx_task_main(uint64_t argument)
{
	switch (argument & MODE_MASK) {
	case MODE_WRITER:
		return (mode_writer());
	case MODE_READER:
		return (mode_reader());
	case MODE_REVOKED:
		return (mode_revoked(argument >> SLOT_SHIFT));
	case MODE_GROUP:
		return (erx_group_take_ready(1) == ERX_ETYPE ? 0 : 51);
	case MODE_CREATOR:
		return (mode_creator());
	case MODE_FIRST:
		return (mode_first(argument));
	case MODE_HOLDER:
		return (mode_holder(argument >> SLOT_SHIFT));
	case MODE_TIME:
		return (mode_time());
	case MODE_BELL:
		return (mode_bell(argument));
	case MODE_RELEASE:
		return (mode_release(argument >> SLOT_SHIFT));
	case MODE_DATA:
		return (mode_data());
	case MODE_CODE_READ:
		return ((int64_t)*code_word());
	case MODE_CODE_WRITE:
		return (mode_code_write());
	default:
		return (90);
	}
}
