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
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PAGE	((uint64_t)ERX_PAGE_SIZE)
/* The handle table of each space the creator makes. */
#define CREATED_CAP_LIMIT	16u

_Static_assert(PROGRAM_TAG_ARG > ERX_PROGRAM_ARG_DOORBELL && PROGRAM_TAG_ARG < ERX_FIASCO_START_ARGS,
    "the tag's register is an argument register no program value uses");

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

/* The starting registers erx_thread_create reads from the head of the calling thread's public UTCB. */
static void
first_registers(uint64_t pc, uint64_t argument)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;

	start.regs.pc = pc;
	start.regs.gpr[0] = argument;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&erx_utcb_self()->mr[word], words[word], memory_order_relaxed);
}

/* The next record at the gate bound to the calling thread, as erx_ipc_wait leaves it in its public UTCB. */
static bool
record_take(erx_fault_t *record, uint64_t *label)
{
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];
	erx_msgtag_t tag;

	if (erx_ipc_wait(erx_fiasco_clock_ns() + CREATOR_WAIT_NS, &tag, label) != ERX_OK)
		return (false);
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		words[word] = atomic_load_explicit(&erx_utcb_self()->mr[word], memory_order_relaxed);
	__builtin_memcpy(record, words, sizeof(words));
	return (true);
}

/*
 * Spaces below its own: a child, and a grandchild below the child, each reporting to a
 * gate of its own, and the child given a page of its object; then a parent that names
 * no space. The child runs this program, index 0 of the slice the root passed: the map
 * refuses an index past the slice, a target that is no space, an image that is no
 * slice, and the whole archive, which only the root names, even at the program's entry. The child's first thread takes FIRST_TAG, a second create there is
 * ERX_ENOTSUP, and the start of the root's first thread in a task this one did not
 * create, whose handle the root passed, ERX_EINVAL. The child's end stops the
 * grandchild below it, and both exit records come to the gate. Its own end frees what
 * is left.
 */
static int64_t
mode_creator(uint64_t argument)
{
	const uint64_t slice = argument >> CREATOR_SLICE_SHIFT & HANDLE_MASK;
	const uint64_t others = argument >> CREATOR_THREAD_SHIFT & CREATOR_THREAD_MASK;
	const uint64_t entry = argument >> CREATOR_ENTRY_SHIFT;
	uint64_t gate, mem, child, grandchild, refused, pc, thread, label;
	erx_fault_t record;
	bool child_ended = false, grandchild_ended = false;

	if (erx_gate_create(0, &gate) != ERX_OK || erx_mem_create(0, PAGE, 0, &mem) != ERX_OK)
		return (40);
	if (erx_space_create(0, ERX_CAP_SELF, gate, CREATOR_LABEL, 0, CREATED_CAP_LIMIT, &child) != ERX_OK)
		return (41);
	if (erx_space_create(0, child, gate, CREATOR_LABEL + 1, 0, CREATED_CAP_LIMIT, &grandchild) != ERX_OK)
		return (42);
	if (erx_vm_reserve(child, SHARED_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) != ERX_OK ||
	    erx_vm_map(child, SHARED_ADDR, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK)
		return (43);
	if (erx_space_create(0, mem, gate, 3, 0, CREATED_CAP_LIMIT, &refused) != ERX_ETYPE)
		return (44);
	if (erx_image_map(child, slice, 1, &pc) != ERX_ERANGE || erx_image_map(mem, slice, 0, &pc) != ERX_ETYPE ||
	    erx_image_map(child, mem, 0, &pc) != ERX_ETYPE || erx_image_map(child, ERX_CAP_NULL, entry, &pc) != ERX_EINVAL)
		return (45);
	if (erx_image_map(child, slice, 0, &pc) != ERX_OK)
		return (46);
	first_registers(pc, FIRST_TAG << SLOT_SHIFT | MODE_FIRST);
	if (erx_thread_create(0, child, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK ||
	    erx_thread_create(0, child, 0, ERX_THREAD_CLASS_WORKER, &refused) != ERX_ENOTSUP)
		return (47);
	if (erx_thread_start(others) != ERX_EINVAL)
		return (48);
	if (erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK || erx_thread_start(thread) != ERX_OK)
		return (49);
	while (!child_ended || !grandchild_ended) {
		if (!record_take(&record, &label) || record.kind != ERX_FAULT_EXIT)
			return (120);
		if (label == CREATOR_LABEL && !child_ended && record.status == FIRST_STATUS)
			child_ended = true;
		else if (label == CREATOR_LABEL + 1 && !grandchild_ended)
			grandchild_ended = true;
		else
			return (121);
	}
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
/* The label the executor waits for, written before it starts. */
static uint64_t bell_label;

/*
 * An executor of the task's home group: parks until a take gives bell_label, then acks
 * the bell and rings the back object, each if the argument names one, from this task's
 * own handles to both.
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
	if (taken == 1 && erx_utcb_mr_load(erx_utcb_self(), 0, &label) && label == bell_label)
		result = (bell == ERX_CAP_NULL || erx_irq_ack(bell) == ERX_OK) &&
		    (back == ERX_CAP_NULL || erx_irq_trigger(back) == ERX_OK) ? 0 : 62;
	atomic_store_explicit(&bell_result, result, memory_order_release);
	erx_thread_exit();
}

/* From the first thread, a worker, once: starts the executor for label, and returns its result once it has one. */
static int64_t
bell_run(uint64_t argument, uint64_t label)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	const uint64_t deadline = erx_fiasco_clock_ns() + 2 * BELL_WAIT_NS;
	int64_t result;
	uint64_t thread;

	bell_label = label;
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

/* A word of a side of the channel, where this task mapped it at addr. */
static _Atomic uint64_t *
channel_word(uint64_t addr, uint64_t word)
{
	return ((_Atomic uint64_t *)(uintptr_t)(addr + word * sizeof(uint64_t)));
}

/*
 * Maps the channel in this task's own space as each party does: the side it writes at
 * own_addr read-write, and its peer's at peer_addr read-only.
 */
static bool
channel_map(uint64_t own_addr, uint64_t own, uint64_t peer_addr, uint64_t peer)
{
	return (erx_vm_reserve(ERX_CAP_SELF, own_addr, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, own_addr, PAGE, own, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_vm_reserve(ERX_CAP_SELF, peer_addr, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, peer_addr, PAGE, peer, 0, ERX_PROT_R) == ERX_OK);
}

/* One erx_cap_pass item in the calling thread's public UTCB: a copy of handle with the rights mask. */
static void
item_put(size_t item, uint64_t handle, uint32_t mask)
{
	uint64_t desc = 0;

	(void)erx_msg_item_desc_rights_set(&desc, mask);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item, desc);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item + 1, handle);
}

/* What erx_cap_pass made of one item: the handle's value in the target's table. */
static uint64_t
item_value(size_t item)
{
	uint64_t value = ERX_CAP_NULL;

	(void)erx_utcb_mr_load(erx_utcb_self(), 2 * item + 1, &value);
	return (value);
}

/*
 * What the maker installs into its child, in order: each without DUP, GIVE or DESTROY, the
 * program's side READ, WRITE and MAP, the session's side READ and MAP and the session's
 * bell TRIGGER alone, as a session installs them.
 */
enum { INSTALL_BUDGET, INSTALL_GROUP, INSTALL_PROGRAM_SIDE, INSTALL_SESSION_SIDE, INSTALL_SESSION_BELL, INSTALL_OTHER,
    INSTALL_ITEMS };
#define INSTALL_RIGHTS	(UINT32_MAX & ~(ERX_HR_DUP | ERX_HR_GIVE | ERX_HR_DESTROY))

/* The rights the maker passes each item with. */
static uint32_t
install_rights(size_t item)
{
	if (item == INSTALL_PROGRAM_SIDE)
		return (ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP);
	if (item == INSTALL_SESSION_SIDE)
		return (ERX_HR_READ | ERX_HR_MAP);
	return (item == INSTALL_SESSION_BELL ? ERX_HR_TRIGGER : INSTALL_RIGHTS);
}

/* What MODE_MAKER adds to its child's status when the child ends with another than PROGRAM_STATUS. */
#define CHILD_FAILED	INT64_C(1000)

/*
 * Installs the program's handles into child as a session does, after the passes a
 * task may not make: of a space or gate handle, into its own space, or into a handle
 * that names no space. Fills values with what the pass made of each item.
 */
static int64_t
maker_install(uint64_t child, uint64_t gate, const uint64_t handles[INSTALL_ITEMS], uint64_t values[INSTALL_ITEMS])
{
	item_put(0, child, INSTALL_RIGHTS);
	if (erx_cap_pass(ERX_CAP_SELF, child, 1) != ERX_ENOTSUP)
		return (100);
	item_put(0, gate, INSTALL_RIGHTS);
	if (erx_cap_pass(ERX_CAP_SELF, child, 1) != ERX_ENOTSUP)
		return (101);
	item_put(0, handles[INSTALL_PROGRAM_SIDE], INSTALL_RIGHTS);
	if (erx_cap_pass(ERX_CAP_SELF, ERX_CAP_SELF, 1) != ERX_ENOTSUP)
		return (102);
	if (erx_cap_pass(ERX_CAP_SELF, handles[INSTALL_PROGRAM_SIDE], 1) != ERX_ETYPE)
		return (103);
	/* At most ERX_MSG_CAPS items a call. */
	for (size_t first = 0; first < INSTALL_ITEMS; first += ERX_MSG_CAPS) {
		const size_t count = INSTALL_ITEMS - first < ERX_MSG_CAPS ? INSTALL_ITEMS - first : ERX_MSG_CAPS;

		for (size_t item = 0; item < count; item++)
			item_put(item, handles[first + item], install_rights(first + item));
		if (erx_cap_pass(ERX_CAP_SELF, child, (uint32_t)count) != ERX_OK)
			return (104);
		for (size_t item = 0; item < count; item++)
			values[first + item] = item_value(item);
	}
	return (0);
}

/*
 * The child's starting registers, as a session writes a program's: the installed
 * values where program_arg puts them, PROGRAM_MARK with its index in the registers
 * past them, and PROGRAM_TAG in the last.
 */
static void
program_registers(uint64_t pc, const uint64_t values[INSTALL_ITEMS])
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;

	start.regs.pc = pc;
	for (uint32_t index = 0; index < ERX_FIASCO_START_ARGS; index++)
		start.regs.gpr[index] = PROGRAM_MARK | index;
	start.regs.gpr[ERX_PROGRAM_ARG_BUDGET] = values[INSTALL_BUDGET];
	start.regs.gpr[ERX_PROGRAM_ARG_GROUP] = values[INSTALL_GROUP];
	start.regs.gpr[ERX_PROGRAM_ARG_OWN_SIDE] = values[INSTALL_PROGRAM_SIDE];
	start.regs.gpr[ERX_PROGRAM_ARG_PEER_SIDE] = values[INSTALL_SESSION_SIDE];
	start.regs.gpr[ERX_PROGRAM_ARG_DOORBELL] = values[INSTALL_SESSION_BELL];
	start.regs.gpr[PROGRAM_TAG_ARG] = PROGRAM_TAG;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&erx_utcb_self()->mr[word], words[word], memory_order_relaxed);
}

/*
 * What a session makes for each program, from this task's own authority (MODE_MAKER):
 * a budget carved from the one its own space is charged to, a budget carved from that,
 * a group, another group and a bell charged to them, and a child below its own space,
 * charged to the first budget, that will run index 0 of the slice the root passed in
 * the new group. A task resizes no budget and makes no line. From its own budget it
 * makes the channel: the program's side and the session's side, which it maps as a session
 * does (channel_map), and the program's doorbell (program_bell), which it binds into the
 * new group, its creator's to bind into though the child becomes its home, and it binds
 * the bell, the session's doorbell, into its own home group. It installs the budget,
 * the group, both sides, the bell and the other group into the child (maker_install),
 * leaves the other group's value in its own side, and starts the child with the values
 * in its argument registers (mode_program). The child's first thread ends with
 * PROGRAM_STATUS, and its ring of the bell, made before, reaches this task's executor
 * with the child's pattern in the program's side. The first budget's destroy takes
 * everything charged to either budget, the bell included.
 */
static int64_t
mode_maker(uint64_t argument)
{
	const uint64_t slice = argument >> MAKER_SLICE_SHIFT & HANDLE_MASK;
	uint64_t budget, carved, group, other, bell, program_side, session_side, program_bell, refused, gate, child, pc,
	    thread, label;
	uint64_t handles[INSTALL_ITEMS], values[INSTALL_ITEMS];
	erx_fault_t record;
	int64_t step;

	if (erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_WALL, MAKER_PAGES, MAKER_PAGES, &budget) != ERX_OK ||
	    erx_budget_create(budget, ERX_BUDGET_ELASTIC, 1, 2, &carved) != ERX_OK)
		return (70);
	if (erx_budget_resize(budget, 1, 1) != ERX_ENOTSUP)
		return (71);
	if (erx_group_create(budget, 0, &group) != ERX_OK || erx_group_create(budget, 0, &other) != ERX_OK ||
	    erx_irq_create(carved, 0, ERX_IRQ_SOFT, 0, &bell) != ERX_OK)
		return (72);
	if (erx_irq_create(budget, 0, ERX_IRQ_LINE, 0, &refused) != ERX_ENOTSUP)
		return (73);
	if (erx_gate_create(budget, &gate) != ERX_OK ||
	    erx_space_create(budget, ERX_CAP_SELF, gate, MAKER_LABEL, 0, CREATED_CAP_LIMIT, &child) != ERX_OK ||
	    erx_image_map(child, slice, 0, &pc) != ERX_OK)
		return (74);
	if (erx_mem_create(0, PAGE, 0, &program_side) != ERX_OK || erx_mem_create(0, PAGE, 0, &session_side) != ERX_OK ||
	    erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &program_bell) != ERX_OK ||
	    !channel_map(SESSION_SIDE_ADDR, session_side, PROGRAM_SIDE_ADDR, program_side))
		return (75);
	if (erx_irq_bind(program_bell, group, CHANNEL_LABEL) != ERX_OK)
		return (76);
	if (erx_irq_bind(bell, ERX_CAP_SELF, BELL_LABEL) != ERX_OK)
		return (77);
	handles[INSTALL_BUDGET] = budget;
	handles[INSTALL_GROUP] = group;
	handles[INSTALL_PROGRAM_SIDE] = program_side;
	handles[INSTALL_SESSION_SIDE] = session_side;
	handles[INSTALL_SESSION_BELL] = bell;
	handles[INSTALL_OTHER] = other;
	step = maker_install(child, gate, handles, values);
	if (step != 0)
		return (step);
	atomic_store_explicit(channel_word(SESSION_SIDE_ADDR, CHANNEL_OTHER_WORD), values[INSTALL_OTHER],
	    memory_order_release);
	program_registers(pc, values);
	if (erx_thread_create(0, child, group, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK)
		return (78);
	/* Rung before the child runs: the kernel keeps the ring for the bind its home's dispatcher makes. */
	if (erx_irq_trigger(program_bell) != ERX_OK || erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK)
		return (79);
	/* The child's own status names the step it failed at, above CHILD_FAILED. */
	if (!record_take(&record, &label) || record.kind != ERX_FAULT_EXIT || label != MAKER_LABEL)
		return (80);
	if (record.status != PROGRAM_STATUS)
		return (CHILD_FAILED + record.status);
	step = bell_run(bell << BELL_SHIFT | ERX_CAP_NULL << BACK_SHIFT, BELL_LABEL);
	if (step != 0)
		return (step);
	if (atomic_load_explicit(channel_word(PROGRAM_SIDE_ADDR, 0), memory_order_acquire) != WRITER_PATTERN)
		return (81);
	/* The channel's objects go after the program's budget, as a session deletes them. */
	if (erx_object_destroy(budget) != ERX_OK || erx_irq_trigger(bell) != ERX_ESTALE)
		return (82);
	return (erx_object_destroy(program_bell) == ERX_OK && erx_object_destroy(program_side) == ERX_OK &&
	    erx_object_destroy(session_side) == ERX_OK ? 0 : 83);
}

/*
 * The child MODE_MAKER starts (PROGRAM_TAG): checks each marked register, maps its own
 * side read-write and its peer side, the session's, read-only, finds the other group's
 * value in the peer side, makes a doorbell of its own from the
 * passed budget, which the other group, neither its home nor its own, refuses, and
 * may neither unbind nor move the session's doorbell out of the maker's group. Writes
 * WRITER_PATTERN in its own side, and, once its executor took the program's doorbell under
 * CHANNEL_LABEL, rings the session's doorbell. Ends with PROGRAM_STATUS.
 */
static int64_t
mode_program(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	uint64_t own, other;
	int64_t step;

	for (uint32_t at = ERX_PROGRAM_ARG_DOORBELL + 1; at < PROGRAM_TAG_ARG; at++)
		if (args[at] != (PROGRAM_MARK | at))
			return (130);
	if (args[ERX_PROGRAM_ARG_BUDGET] == ERX_CAP_NULL || args[ERX_PROGRAM_ARG_GROUP] == ERX_CAP_NULL ||
	    !channel_map(PROGRAM_SIDE_ADDR, args[ERX_PROGRAM_ARG_OWN_SIDE], SESSION_SIDE_ADDR, args[ERX_PROGRAM_ARG_PEER_SIDE]))
		return (133);
	if (erx_irq_create(args[ERX_PROGRAM_ARG_BUDGET], 0, ERX_IRQ_SOFT, 0, &own) != ERX_OK)
		return (134);
	other = atomic_load_explicit(channel_word(SESSION_SIDE_ADDR, CHANNEL_OTHER_WORD), memory_order_acquire);
	if (erx_irq_bind(own, other, BELL_LABEL) != ERX_ETYPE)
		return (135);
	if (erx_irq_bind(args[ERX_PROGRAM_ARG_DOORBELL], ERX_CAP_NULL, 0) != ERX_ETYPE ||
	    erx_irq_bind(args[ERX_PROGRAM_ARG_DOORBELL], ERX_CAP_SELF, BELL_LABEL) != ERX_ETYPE)
		return (136);
	atomic_store_explicit(channel_word(PROGRAM_SIDE_ADDR, 0), WRITER_PATTERN, memory_order_release);
	step = bell_run(ERX_CAP_NULL << BELL_SHIFT | args[ERX_PROGRAM_ARG_DOORBELL] << BACK_SHIFT, CHANNEL_LABEL);
	return (step == 0 ? PROGRAM_STATUS : step);
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
erx_task_main(const uint64_t args[ERX_FIASCO_START_ARGS])
{
	const uint64_t argument = args[0];

	if (args[PROGRAM_TAG_ARG] == PROGRAM_TAG)
		return (mode_program(args));
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
		return (mode_creator(argument));
	case MODE_FIRST:
		return (mode_first(argument));
	case MODE_HOLDER:
		return (mode_holder(argument >> SLOT_SHIFT));
	case MODE_TIME:
		return (mode_time());
	case MODE_BELL:
		return (bell_run(argument, BELL_LABEL));
	case MODE_MAKER:
		return (mode_maker(argument));
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
