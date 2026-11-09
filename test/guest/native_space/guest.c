/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root of the mapping suite: memory objects mapped between the root and two tasks of
 * test/guest/native_space/program.c, a destroy that revokes them, and the bounds of a
 * map into a created space, and fault gates: a revoked task's fault reaches the root's
 * gate, and the gate calls' refusals and queue; and spaces: a task that creates spaces
 * below its own, the create's refusals, and a release at the last handle's close; a
 * created space's first thread, which the root makes and starts; budgets and groups as
 * records; and handles the root passes into a task with erx_cap_pass. Each case says
 * one line, which tools/lib/erx/native_space.rb holds the transcript to.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PROGRAM		"boot/native-space"
#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define WAIT_NS		UINT64_C(10000000000)
#define SHORT_NS	UINT64_C(1000000)
/* Long enough for a spinning task to reach its fault after a revoke. */
#define SETTLE_NS	UINT64_C(200000000)
/* The handle table of each task the root makes. */
#define TASK_CAP_LIMIT	64u
/* Each case's labels and statuses, so a record shows which space and which stop it came from. */
#define REVOKE_LABEL	UINT64_C(0x5e0000000000a000)
#define REVOKE_STATUS	77
#define QUEUE_LABEL	UINT64_C(0x5e0000000000b000)
#define RELEASE_LABEL	UINT64_C(0x5e0000000000c000)
#define BUDGET_LABEL	UINT64_C(0x5e0000000000d000)

void erx_fiasco_root_main(void);

static uint32_t program_entry;
/* The program's entry, the same in every task the launcher makes from its fixed image. */
static uint64_t program_pc;

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static void
say_case(const char *name, bool passed)
{
	say("erx: space: ");
	say(name);
	say(passed ? " ok\n" : " FAILED\n");
}

/* Says a count the case compares, so a failure shows what it saw. */
static void
say_count(const char *name, uint64_t value)
{
	char line[24];
	size_t used = sizeof(line) - 1;

	line[used] = '\0';
	do {
		line[--used] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0 && used > 0);
	say("erx: space: ");
	say(name);
	say(" ");
	say(&line[used]);
	say("\n");
}

/* A task made from the program with its image, whose first thread has not started, and a range reserved there. */
static bool
task_make(uint64_t *space, uint64_t addr, uint64_t pages)
{
	return (erx_fiasco_launch_make(program_entry, 0, space, &program_pc) == ERX_OK &&
	    erx_vm_reserve(*space, addr, pages * PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK);
}

static int64_t
task_finish(uint64_t space, uint64_t argument)
{
	int64_t status = INT64_MIN;

	if (erx_fiasco_launch_start(space, program_pc, argument) != ERX_OK ||
	    erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + WAIT_NS, &status) != ERX_OK)
		return (INT64_MIN);
	return (status);
}

/* A task the case does not start: stopped and joined, so nothing of it remains. */
static void
task_drop(uint64_t space)
{
	int64_t ignored;

	(void)erx_space_stop(space, 0);
	(void)erx_fiasco_task_join(space, &ignored);
}

/* A task made from the program with its image, its records going to gate under label, whose first thread has not started. */
static bool
task_make_gated(uint64_t *space, uint64_t gate, uint64_t label)
{
	uint64_t pc;

	if (erx_space_create(0, ERX_CAP_SELF, gate, label, 0, TASK_CAP_LIMIT, space) != ERX_OK)
		return (false);
	if (erx_image_map(*space, 0, program_entry, &pc) == ERX_OK)
		return (true);
	task_drop(*space);
	return (false);
}

/* The next record at the gates bound to the calling thread, with its label. */
static bool
record_wait(uint64_t deadline, erx_fault_t *record, uint64_t *label)
{
	const erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];

	if (erx_ipc_wait(deadline, label) != ERX_OK)
		return (false);
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	__builtin_memcpy(record, words, sizeof(words));
	return (true);
}

/* An exit record of the space under label, from a stop of the root's with status. */
static bool
exit_record_is(const erx_fault_t *record, uint64_t label, uint64_t got_label, int64_t status)
{
	return (record->kind == ERX_FAULT_EXIT && record->status == status && record->space == ERX_FIASCO_TASK_ROOT &&
	    record->thread == UINT64_MAX && got_label == label);
}

/* Writes value plus the page's number at the head of each of mem's pages, through a mapping of the root's own. */
static bool
object_fill(uint64_t mem, uint64_t pages, uint64_t value)
{
	uint64_t addr;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, pages * PAGE, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, pages * PAGE, mem, 0, ERX_PROT_RW) != ERX_OK)
		return (false);
	for (uint64_t page = 0; page < pages; page++)
		atomic_store_explicit((_Atomic uint64_t *)(uintptr_t)(addr + page * PAGE), value + page, memory_order_release);
	return (erx_vm_release(ERX_CAP_SELF, addr, pages * PAGE) == ERX_OK);
}

/*
 * The root maps an object read-write into the writer and read-only into the reader and
 * closes its handle. The writer's bytes reach the reader; the object outlives the
 * handle and the writer's release, and its pages come back at the reader's release.
 */
static void
case_between_tasks(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	int64_t writer_status;
	uint64_t writer = 0, reader = 0, mem, object_cost, reader_from, reader_cost, after_writer;
	bool passed = erx_mem_create(0, SHARED_PAGES * PAGE, 0, &mem) == ERX_OK;

	/* An object holds its range table's record pages as well as its data pages. */
	object_cost = before - erx_fiasco_vm_free_pages();
	passed = passed && object_fill(mem, SHARED_PAGES, ROOT_PATTERN);

	/* What the reader holds of its own, so what the writer leaves behind can be told from the object. */
	reader_from = erx_fiasco_vm_free_pages();
	passed = passed && task_make(&reader, SHARED_ADDR, SHARED_PAGES) &&
	    erx_vm_map(reader, SHARED_ADDR, SHARED_PAGES * PAGE, mem, 0, ERX_PROT_R) == ERX_OK;
	reader_cost = reader_from - erx_fiasco_vm_free_pages();
	passed = passed && task_make(&writer, SHARED_ADDR, SHARED_PAGES) &&
	    erx_vm_map(writer, SHARED_ADDR, SHARED_PAGES * PAGE, mem, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_cap_close(mem) == ERX_OK;
	writer_status = task_finish(writer, MODE_WRITER);
	say_count("writer_status", (uint64_t)writer_status);
	passed = passed && writer_status == 0;
	after_writer = erx_fiasco_vm_free_pages();
	say_count("pages_held", before - after_writer);
	say_count("pages_expected", reader_cost + object_cost);
	passed = passed && before - after_writer == reader_cost + object_cost;
	say_case("writer_released", passed);
	passed = passed && task_finish(reader, MODE_READER) == 0 && erx_fiasco_vm_free_pages() == before;
	say_case("between_tasks", passed);
}

/*
 * A map into a created space: over a mapping or a committed page, and a release or a
 * protect or decommit that meets a mapping, are refused and change nothing; an offset
 * that wraps, pages past the object or the area, and a space that is no live child are
 * refused too.
 */
static void
case_bounds(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint64_t past = (UINT64_MAX / PAGE) * PAGE;
	uint64_t space, mem, committed;
	bool passed = task_make(&space, SHARED_ADDR, 4) && erx_mem_create(0, 2 * PAGE, 0, &mem) == ERX_OK &&
	    erx_vm_map(space, SHARED_ADDR, 2 * PAGE, mem, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_vm_commit(space, SHARED_ADDR + 3 * PAGE, PAGE) == ERX_OK;

	committed = erx_fiasco_vm_free_pages();
	passed = passed &&
	    erx_vm_map(space, SHARED_ADDR + PAGE, 2 * PAGE, mem, 0, ERX_PROT_R) == ERX_EINVAL &&
	    erx_vm_map(space, SHARED_ADDR + 3 * PAGE, PAGE, mem, 0, ERX_PROT_R) == ERX_EINVAL &&
	    erx_vm_release(space, SHARED_ADDR, PAGE) == ERX_EINVAL &&
	    erx_vm_decommit(space, SHARED_ADDR + PAGE, PAGE) == ERX_EINVAL &&
	    erx_space_protect(space, SHARED_ADDR, 2 * PAGE, ERX_PROT_R) == ERX_ENOTSUP &&
	    erx_vm_map(space, SHARED_ADDR + 2 * PAGE, PAGE, mem, past, ERX_PROT_R) == ERX_ERANGE &&
	    erx_vm_map(space, SHARED_ADDR + 2 * PAGE, PAGE, mem, 2 * PAGE, ERX_PROT_R) == ERX_ERANGE &&
	    erx_vm_map(space, past, PAGE, mem, 0, ERX_PROT_R) == ERX_ERANGE &&
	    erx_vm_map(space + 1000, SHARED_ADDR + 2 * PAGE, PAGE, mem, 0, ERX_PROT_R) == ERX_EINVAL &&
	    erx_fiasco_vm_free_pages() == committed &&
	    erx_vm_release(space, SHARED_ADDR, 2 * PAGE) == ERX_OK;
	task_drop(space);
	passed = passed && erx_cap_close(mem) == ERX_OK && erx_fiasco_vm_free_pages() == before;
	say_case("bounds", passed);
}

/*
 * An object mapped read-only into two running tasks is destroyed by its creator: each
 * task's next read faults, and its fault record, a memory fault whose thread is
 * unknown, reaches the root's gate under the task's label. The faulting threads stay
 * blocked until the root stops each task, whose exit record follows; the pages come
 * back. A signal page the root shares with them says each has read the object first.
 */
static void
case_revoke(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t spaces[2], mem, signal, signal_addr, gate;
	bool passed = erx_mem_create(0, PAGE, 0, &mem) == ERX_OK && object_fill(mem, 1, ROOT_PATTERN) &&
	    erx_mem_create(0, PAGE, 0, &signal) == ERX_OK && erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &signal_addr) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, signal_addr, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_gate_create(0, &gate) == ERX_OK && erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK;
	uint64_t deadline, seen = 0;

	for (uint64_t slot = 0; slot < 2 && passed; slot++)
		passed = task_make_gated(&spaces[slot], gate, REVOKE_LABEL + slot) &&
		    erx_vm_reserve(spaces[slot], SHARED_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
		    erx_vm_reserve(spaces[slot], SIGNAL_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
		    erx_vm_map(spaces[slot], SHARED_ADDR, PAGE, mem, 0, ERX_PROT_R) == ERX_OK &&
		    erx_vm_map(spaces[slot], SIGNAL_ADDR, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK &&
		    erx_fiasco_launch_start(spaces[slot], program_pc, MODE_REVOKED | slot << SLOT_SHIFT) == ERX_OK;
	deadline = erx_fiasco_clock_ns() + WAIT_NS;
	for (uint64_t slot = 0; slot < 2 && passed; slot++)
		while (atomic_load_explicit((_Atomic uint64_t *)(uintptr_t)(signal_addr + slot * sizeof(uint64_t)),
		    memory_order_acquire) == 0 && passed)
			passed = erx_fiasco_clock_ns() < deadline;
	passed = passed && erx_object_destroy(mem) == ERX_OK;
	/*
	 * Both tasks fault at once; the second is stopped before any record is read, and its
	 * fault record outlives the stop, ahead of its exit record. The faults come in either
	 * order, each naming its space under its label.
	 */
	(void)erx_umtx_wait(signal_addr + PAGE - sizeof(uint32_t), 0, erx_fiasco_clock_ns() + SETTLE_NS);
	passed = passed && erx_space_stop(spaces[1], REVOKE_STATUS) == ERX_OK;
	for (uint64_t taken = 0; taken < 2 && passed; taken++) {
		erx_fault_t record;
		uint64_t label, slot;

		passed = record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label);
		slot = label - REVOKE_LABEL;
		passed = passed && slot < 2 && (seen & (UINT64_C(1) << slot)) == 0 && record.kind == ERX_FAULT_MEMORY &&
		    record.thread == UINT64_MAX && record.space != ERX_FIASCO_TASK_ROOT && record.addr == SHARED_ADDR;
		seen |= passed ? UINT64_C(1) << slot : 0;
	}
	say_count("revoke_faults", seen);
	for (uint64_t slot = 2; slot-- > 0 && passed;) {
		erx_fault_t record;
		uint64_t label;
		int64_t status = 0;

		passed = (slot == 1 || erx_space_stop(spaces[slot], REVOKE_STATUS) == ERX_OK) &&
		    record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label) &&
		    exit_record_is(&record, REVOKE_LABEL + slot, label, REVOKE_STATUS) &&
		    erx_fiasco_task_join_until(spaces[slot], erx_fiasco_clock_ns() + WAIT_NS, &status) == ERX_OK &&
		    status == REVOKE_STATUS;
	}
	passed = passed && erx_vm_release(ERX_CAP_SELF, signal_addr, PAGE) == ERX_OK && erx_cap_close(mem) == ERX_OK &&
	    erx_cap_close(signal) == ERX_OK && erx_object_destroy(gate) == ERX_OK && erx_cap_close(gate) == ERX_OK &&
	    erx_fiasco_vm_free_pages() == before;
	say_case("revoke", passed);
}

/*
 * What the gate calls refuse: every message call; a bind of a handle that names no
 * gate, or no entry; a bind to another task's thread; a space whose fault names no
 * gate. A bound thread with nothing queued waits until its deadline.
 */
static void
case_gate_refusals(void)
{
	uint64_t gate, mem, space = 0, thread = 0, refused, label;
	bool passed = erx_gate_create(0, &gate) == ERX_OK && erx_mem_create(0, PAGE, 0, &mem) == ERX_OK &&
	    task_make_gated(&space, gate, 1) &&
	    erx_thread_create(0, space, 0, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK;

	passed = passed && erx_ipc_call(gate, 0, 0, 0) == ERX_ENOTSUP && erx_ipc_send(gate, 0, 0) == ERX_ENOTSUP &&
	    erx_ipc_reply(0) == ERX_ENOTSUP && erx_ipc_reply_wait(0, 0) == ERX_ENOTSUP &&
	    erx_gate_bind(mem, ERX_CAP_SELF_THREAD, 0) == ERX_ETYPE &&
	    erx_gate_bind(gate + 1000, ERX_CAP_SELF_THREAD, 0) == ERX_EINVAL &&
	    erx_gate_bind(gate, thread, 0) == ERX_ENOTSUP &&
	    erx_gate_bind(gate, ERX_FIASCO_THREADS_MAX - 1, 0) == ERX_EINVAL &&
	    erx_space_create(0, ERX_CAP_SELF, mem, 0, 0, TASK_CAP_LIMIT, &refused) == ERX_ETYPE &&
	    erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &label) == ERX_ETIMEDOUT &&
	    erx_gate_bind(gate, ERX_CAP_NULL, 0) == ERX_OK;
	if (space != 0) {
		int64_t status;

		/* The exit record waits at the unbound gate until the join withdraws it. */
		passed = passed && erx_space_stop(space, 0) == ERX_OK && erx_fiasco_task_join(space, &status) == ERX_OK &&
		    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &label) == ERX_ETIMEDOUT;
	}
	passed = passed && erx_cap_close(mem) == ERX_OK && erx_cap_close(gate) == ERX_OK;
	say_case("gate_refusals", passed);
}

/*
 * A gate with no thread bound keeps its records, and the thread a later bind names
 * takes them in order. A gate's destroy drops what it holds and leaves its spaces with
 * none, so a later record of theirs is dropped.
 */
static void
case_gate_queue(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t gate, other, first, second, third, label;
	erx_fault_t record;
	int64_t status;
	bool passed = erx_gate_create(0, &gate) == ERX_OK && task_make_gated(&first, gate, QUEUE_LABEL) &&
	    task_make_gated(&second, gate, QUEUE_LABEL + 1);

	passed = passed && erx_space_stop(second, 6) == ERX_OK && erx_space_stop(first, 5) == ERX_OK &&
	    erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label) && exit_record_is(&record, QUEUE_LABEL + 1, label, 6) &&
	    record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label) && exit_record_is(&record, QUEUE_LABEL, label, 5) &&
	    erx_fiasco_task_join(first, &status) == ERX_OK && status == 5 &&
	    erx_fiasco_task_join(second, &status) == ERX_OK && status == 6;
	/* Destroyed with a record queued: the record goes, and so does the next of a space that named it. */
	passed = passed && erx_gate_create(0, &other) == ERX_OK && task_make_gated(&first, other, QUEUE_LABEL) &&
	    task_make_gated(&third, other, QUEUE_LABEL + 2) && erx_gate_bind(other, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    erx_space_stop(first, 7) == ERX_OK && erx_object_destroy(other) == ERX_OK &&
	    erx_space_stop(third, 8) == ERX_OK &&
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &label) == ERX_ETIMEDOUT &&
	    erx_fiasco_task_join(first, &status) == ERX_OK && status == 7 &&
	    erx_fiasco_task_join(third, &status) == ERX_OK && status == 8 &&
	    erx_gate_bind(other, ERX_CAP_SELF_THREAD, 0) == ERX_ESTALE;
	passed = passed && erx_cap_close(other) == ERX_OK && erx_cap_close(gate) == ERX_OK &&
	    erx_fiasco_vm_free_pages() == before;
	say_case("gate_queue", passed);
}

/*
 * A task creates spaces below its own and one with a bad parent (MODE_CREATOR
 * in program.c); its end stops and frees them with it, so the pool's pages come back.
 */
static void
case_created(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space;
	const int64_t status = erx_fiasco_launch_make(program_entry, 0, &space, &program_pc) == ERX_OK ?
	    task_finish(space, MODE_CREATOR) : INT64_MIN;

	say_count("created_status", (uint64_t)status);
	say_case("created", status == 0 && erx_fiasco_vm_free_pages() == before);
}

/* What the root's create refuses: a parent or a fault gate that names no space or gate it holds. */
static void
case_space_refusals(void)
{
	uint64_t mem, refused;
	bool passed = erx_mem_create(0, PAGE, 0, &mem) == ERX_OK;

	passed = passed && erx_space_create(0, mem, ERX_CAP_NULL, 0, 0, TASK_CAP_LIMIT, &refused) == ERX_ETYPE &&
	    erx_space_create(0, ERX_CAP_SELF, mem, 0, 0, TASK_CAP_LIMIT, &refused) == ERX_ETYPE;
	passed = erx_cap_close(mem) == ERX_OK && passed;
	say_case("space_refusals", passed);
}

/*
 * The last handle's close releases a space: it stops and is deleted in that call, so
 * its exit record is withdrawn before the bound thread can take it, and its pages
 * come back.
 */
static void
case_released(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t gate, space, label;
	bool passed = erx_gate_create(0, &gate) == ERX_OK && erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    task_make_gated(&space, gate, RELEASE_LABEL) && erx_cap_close(space) == ERX_OK &&
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &label) == ERX_ETIMEDOUT;

	passed = passed && erx_cap_close(gate) == ERX_OK && erx_fiasco_vm_free_pages() == before;
	say_case("released", passed);
}

/* Starts the first thread of a task the launcher made, in group, at the program's entry with the argument. */
static bool
group_start(uint64_t space, uint64_t group, uint64_t argument)
{
	uint64_t thread;

	erx_fiasco_launch_set_registers(program_pc, argument);
	return (erx_thread_create(0, space, group, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK &&
	    erx_thread_start(thread) == ERX_OK);
}

/*
 * Groups as records (docs/design-stopgap.md, "Budgets and groups as records"). The
 * root's first group is its home, as the root's dispatcher is the first thread made in
 * it, so a root thread in a second group is a second home group, refused, and the first
 * cannot be destroyed while the root has threads. A domain's group takes its task as
 * home with the task's first thread, and goes with the task, so the root's handle to it
 * is stale once the task is joined. Last, as the root's dispatcher stays.
 */
static void
case_groups(void)
{
	uint64_t own, second, domain, space, thread;
	int64_t status = INT64_MIN;
	bool passed = erx_group_create(0, 0, &own) == ERX_OK && erx_group_create(0, 0, &second) == ERX_OK &&
	    erx_group_create(0, 0, &domain) == ERX_OK;

	passed = passed && erx_thread_create(0, 0, second, ERX_THREAD_CLASS_WORKER, &thread) == ERX_ENOTSUP &&
	    erx_object_destroy(own) == ERX_ENOTSUP && erx_object_destroy(second) == ERX_OK;
	if (passed && erx_fiasco_launch_make(program_entry, 0, &space, &program_pc) == ERX_OK) {
		if (!group_start(space, domain, MODE_GROUP))
			task_drop(space);
		else if (erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + WAIT_NS, &status) != ERX_OK)
			status = INT64_MIN;
	}
	say_count("groups_status", (uint64_t)status);
	say_case("groups", passed && status == 0 && erx_object_destroy(domain) == ERX_ESTALE);
}

/*
 * The root makes a created space's first thread and starts it at the image's entry with
 * its argument (MODE_FIRST in program.c). A second create there is ERX_ENOTSUP and a
 * second start ERX_EINVAL. The task ends with the thread's status, and its pages come
 * back. No create follows the start: the thread may have ended its task by then, and a
 * create in an ended space is refused for that instead.
 */
static void
case_first_thread(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space, thread, refused;
	int64_t status;
	bool passed;

	if (erx_fiasco_launch_make(program_entry, 0, &space, &program_pc) != ERX_OK) {
		say_case("first_thread", false);
		return;
	}
	erx_fiasco_launch_set_registers(program_pc, FIRST_TAG << SLOT_SHIFT | MODE_FIRST);
	if (erx_thread_create(0, space, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK ||
	    erx_thread_create(0, space, 0, ERX_THREAD_CLASS_WORKER, &refused) != ERX_ENOTSUP ||
	    erx_thread_start(thread) != ERX_OK) {
		task_drop(space);
		say_case("first_thread", false);
		return;
	}
	passed = erx_thread_start(thread) == ERX_EINVAL;
	if (erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + WAIT_NS, &status) != ERX_OK) {
		say_case("first_thread", false);
		return;
	}
	say_count("first_thread_status", (uint64_t)status);
	say_case("first_thread", passed && status == FIRST_STATUS && erx_fiasco_vm_free_pages() == before);
}

/*
 * What the budget calls answer: a create under the root's budget or a carved one; a
 * kind that is neither wall nor elastic, or a parent that names no budget, refused; a
 * resize recorded unchecked, the root's own budget refused; a watch refused; a carved
 * budget's report refused and the root's answering, its used partial. A budget's last
 * close ends what is charged to it, as a destroy does.
 */
static void
case_budget_calls(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	erx_info_budget_t report;
	uint64_t budget, carved, mem, refused;
	bool passed = erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_WALL, 4, 4, &budget) == ERX_OK &&
	    erx_budget_create(budget, ERX_BUDGET_ELASTIC, 1, 2, &carved) == ERX_OK &&
	    erx_mem_create(carved, PAGE, 0, &mem) == ERX_OK;

	passed = passed && erx_budget_create(ERX_CAP_SELF, 0, 4, 4, &refused) == ERX_EINVAL &&
	    erx_budget_create(mem, ERX_BUDGET_WALL, 4, 4, &refused) == ERX_ETYPE &&
	    erx_budget_resize(budget, 1, UINT64_C(1) << 40) == ERX_OK && erx_budget_resize(ERX_CAP_SELF, 1, 1) == ERX_ENOTSUP &&
	    erx_budget_watch(budget, ERX_CAP_NULL, 1) == ERX_ENOTSUP &&
	    erx_object_info(budget, ERX_INFO_BUDGET, 0, &report, sizeof(report)) == ERX_ENOTSUP &&
	    erx_object_info(ERX_CAP_SELF, ERX_INFO_BUDGET, 0, &report, sizeof(report)) == ERX_OK && report.reported == 0 &&
	    report.used != 0;
	passed = passed && erx_cap_close(budget) == ERX_OK && erx_object_destroy(carved) == ERX_ESTALE &&
	    erx_object_destroy(mem) == ERX_ESTALE && erx_cap_close(carved) == ERX_OK && erx_cap_close(mem) == ERX_OK;
	say_case("budget_calls", passed && erx_fiasco_vm_free_pages() == before);
}

/*
 * The domain library's undo and end (include/erx/dom.h, ERX_DOM_UNDO_BY_BUDGET): a
 * domain's own budget and its outer budget, a connection's budget carved from the outer
 * one with a budget carved from that, and the domain's objects charged to them: its
 * fault gate, its space, running, an object mapped into it, and a connection's two
 * sides, one on each carved budget. Destroying the two budgets ends it
 * all: the space stops and goes, every handle answers ERX_ESTALE, and the pages come
 * back.
 */
static void
case_budget_destroy(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t own, outer, link, deep, gate, space, shared, side, deep_side, signal, signal_addr, pc, deadline;
	bool passed = erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_WALL, 64, 64, &own) == ERX_OK &&
	    erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_ELASTIC, 8, 16, &outer) == ERX_OK &&
	    erx_budget_create(outer, ERX_BUDGET_WALL, 2, 2, &link) == ERX_OK && erx_gate_create(own, &gate) == ERX_OK &&
	    erx_space_create(own, ERX_CAP_SELF, gate, BUDGET_LABEL, 0, TASK_CAP_LIMIT, &space) == ERX_OK &&
	    erx_image_map(space, 0, program_entry, &pc) == ERX_OK && erx_mem_create(own, PAGE, 0, &shared) == ERX_OK &&
	    object_fill(shared, 1, ROOT_PATTERN) && erx_mem_create(link, PAGE, 0, &side) == ERX_OK &&
	    erx_budget_create(link, ERX_BUDGET_WALL, 1, 1, &deep) == ERX_OK &&
	    erx_mem_create(deep, PAGE, 0, &deep_side) == ERX_OK &&
	    erx_mem_create(0, PAGE, 0, &signal) == ERX_OK && erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &signal_addr) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, signal_addr, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_vm_reserve(space, SHARED_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
	    erx_vm_reserve(space, SIGNAL_ADDR, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_OK &&
	    erx_vm_map(space, SHARED_ADDR, PAGE, shared, 0, ERX_PROT_R) == ERX_OK &&
	    erx_vm_map(space, SIGNAL_ADDR, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_fiasco_launch_start(space, program_pc, MODE_REVOKED) == ERX_OK;

	/* The task has read the object, so it runs when its budget goes. */
	deadline = erx_fiasco_clock_ns() + WAIT_NS;
	while (passed && atomic_load_explicit((_Atomic uint64_t *)(uintptr_t)signal_addr, memory_order_acquire) == 0)
		passed = erx_fiasco_clock_ns() < deadline;
	passed = passed && erx_object_destroy(own) == ERX_OK && erx_object_destroy(outer) == ERX_OK;
	passed = passed && erx_object_destroy(space) == ERX_ESTALE && erx_object_destroy(gate) == ERX_ESTALE &&
	    erx_object_destroy(shared) == ERX_ESTALE && erx_object_destroy(side) == ERX_ESTALE &&
	    erx_object_destroy(link) == ERX_ESTALE && erx_object_destroy(deep) == ERX_ESTALE &&
	    erx_object_destroy(deep_side) == ERX_ESTALE && erx_object_destroy(own) == ERX_ESTALE;
	passed = passed && erx_cap_close(space) == ERX_OK && erx_cap_close(gate) == ERX_OK && erx_cap_close(shared) == ERX_OK &&
	    erx_cap_close(side) == ERX_OK && erx_cap_close(link) == ERX_OK &&
	    erx_cap_close(deep) == ERX_OK && erx_cap_close(deep_side) == ERX_OK && erx_cap_close(own) == ERX_OK &&
	    erx_cap_close(outer) == ERX_OK && erx_vm_release(ERX_CAP_SELF, signal_addr, PAGE) == ERX_OK &&
	    erx_cap_close(signal) == ERX_OK;
	say_count("budget_free_pages", erx_fiasco_vm_free_pages());
	say_case("budget_destroy", passed && erx_fiasco_vm_free_pages() == before);
}

/* Writes a pass's item into the calling thread's public UTCB: the handle, its rights mask, and whether it moves. */
static void
item_put(size_t item, uint64_t cap, uint32_t mask, bool move)
{
	uint64_t desc = 0;

	(void)erx_msg_item_desc_rights_set(&desc, mask);
	(void)erx_msg_item_desc_move_set(&desc, move);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item, desc);
	(void)erx_utcb_mr_store(erx_utcb_self(), 2 * item + 1, cap);
}

/* One of the item's two words as the UTCB holds them now. */
static uint64_t
item_word(size_t item, size_t word)
{
	uint64_t value = 0;

	(void)erx_utcb_mr_load(erx_utcb_self(), 2 * item + word, &value);
	return (value);
}

/* Whether a pass rewrote the item as a memory object's handle with exactly these rights. */
static bool
item_passed(size_t item, uint32_t rights)
{
	const uint64_t desc = item_word(item, 0);

	return (erx_msg_item_desc_type_get(desc) == ERX_K_MEMORY && erx_msg_item_desc_rights_get(desc) == rights &&
	    erx_msg_item_desc_move_get(desc) == 0 && item_word(item, 1) != ERX_CAP_NULL);
}

/*
 * Whether a pass into task of one item naming handle, its descriptor naming the type
 * the handle must have (a checked pass) or else setting a bit no descriptor defines, is
 * refused with status and leaves the item as written.
 */
static bool
item_refused(uint64_t task, uint64_t handle, bool typed, int status)
{
	uint64_t desc = ERX_HR_READ;

	if (typed)
		(void)erx_msg_item_desc_type_set(&desc, ERX_K_MEMORY);
	else
		desc |= UINT64_C(1) << 40;
	(void)erx_utcb_mr_store(erx_utcb_self(), 0, desc);
	(void)erx_utcb_mr_store(erx_utcb_self(), 1, handle);
	return (erx_cap_pass(ERX_CAP_SELF, task, 1) == status && item_word(0, 0) == desc && item_word(0, 1) == handle);
}

/*
 * The root passes a copy and a move of handles to one object into a created task. Each
 * item comes back with its value in the task's table, the memory type, and its mask
 * intersected with the type's rights less DESTROY; the moved handle is gone from the
 * root's table. A pass of four into a table with room for three passes three and is
 * ERX_ELIMIT at the fourth. A pass stops at its first refused item, a gate, leaving the
 * one before it passed and the one after it as written; a checked pass, a descriptor
 * with an undefined bit, a space's handle, a pass from another space or into the
 * root's own, and more than four items are refused. Then the root closes its own
 * handle, and the task maps the copy and finds the root's pattern, which it can only
 * if a copy counts in the object. The task's end closes what it was passed, so the
 * pages come back.
 */
static void
case_passing(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	const uint32_t write = ERX_HR_READ | ERX_HR_WRITE | ERX_HR_MAP;
	uint64_t mem = ERX_CAP_NULL, moved = ERX_CAP_NULL, gate = ERX_CAP_NULL, held, task = 0, small = 0;
	int64_t status = INT64_MIN;
	bool passed = erx_mem_create(0, SHARED_PAGES * PAGE, 0, &mem) == ERX_OK &&
	    object_fill(mem, SHARED_PAGES, ROOT_PATTERN) && erx_cap_dup(mem, &moved) == ERX_OK &&
	    erx_gate_create(0, &gate) == ERX_OK && task_make(&task, SHARED_ADDR, SHARED_PAGES) &&
	    erx_space_create(0, ERX_CAP_SELF, ERX_CAP_NULL, 0, 0, 4, &small) == ERX_OK;

	item_put(0, mem, ERX_HR_READ | ERX_HR_MAP, false);
	item_put(1, moved, write | ERX_HR_DESTROY, true);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, task, 2) == ERX_OK && item_passed(0, ERX_HR_READ | ERX_HR_MAP) &&
	    item_passed(1, write) && item_word(0, 1) != item_word(1, 1) && erx_cap_close(moved) == ERX_EINVAL;
	held = item_word(0, 1);

	for (size_t item = 0; item < ERX_MSG_CAPS; item++)
		item_put(item, mem, ERX_HR_READ, false);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, small, ERX_MSG_CAPS) == ERX_ELIMIT && item_passed(0, ERX_HR_READ) &&
	    item_passed(1, ERX_HR_READ) && item_passed(2, ERX_HR_READ) && item_word(3, 1) == mem;

	item_put(0, mem, ERX_HR_READ, false);
	item_put(1, gate, ERX_HR_SERVE, false);
	item_put(2, mem, ERX_HR_READ, true);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, task, 3) == ERX_ENOTSUP && item_passed(0, ERX_HR_READ) &&
	    item_word(1, 1) == gate && item_word(2, 1) == mem && erx_msg_item_desc_move_get(item_word(2, 0)) == 1;
	passed = passed && item_refused(task, mem, true, ERX_ENOTSUP) && item_refused(task, mem, false, ERX_EINVAL);
	item_put(0, task, ERX_HR_INSPECT, false);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, task, 1) == ERX_ENOTSUP &&
	    erx_cap_pass(task, task, 1) == ERX_ENOTSUP && erx_cap_pass(ERX_CAP_SELF, ERX_CAP_SELF, 1) == ERX_ENOTSUP &&
	    erx_cap_pass(ERX_CAP_SELF, task, ERX_MSG_CAPS + 1) == ERX_EINVAL;

	passed = erx_cap_close(mem) == ERX_OK && passed;
	if (task != 0)
		status = task_finish(task, MODE_HOLDER | held << SLOT_SHIFT);
	if (small != 0)
		task_drop(small);
	say_count("holder_status", (uint64_t)status);
	passed = passed && status == 0;
	passed = erx_cap_close(gate) == ERX_OK && passed && erx_fiasco_vm_free_pages() == before;
	say_case("passing", passed);
}

/*
 * The root's own tables, and the service's rows for the first two task indices, take
 * their pages here, so no case counts them against its pool.
 */
static void
warm_up(void)
{
	uint64_t mem, addr, gate, label, first = 0, second = 0;

	if (erx_fiasco_launch_make(program_entry, 0, &first, &program_pc) != ERX_OK)
		say("erx: space: warm-up refused\n");
	else if (erx_fiasco_launch_make(program_entry, 0, &second, &program_pc) != ERX_OK)
		say("erx: space: warm-up refused\n");
	else
		task_drop(second);
	if (first != 0)
		task_drop(first);

	if (erx_mem_create(0, PAGE, 0, &mem) != ERX_OK || erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK ||
	    erx_vm_release(ERX_CAP_SELF, addr, PAGE) != ERX_OK || erx_cap_close(mem) != ERX_OK)
		say("erx: space: warm-up refused\n");
	/* The gate table, and the list of waiting threads up to the root's first thread. */
	if (erx_gate_create(0, &gate) != ERX_OK || erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK ||
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &label) != ERX_ETIMEDOUT || erx_cap_close(gate) != ERX_OK)
		say("erx: space: warm-up refused\n");
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);

	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	erx_fiasco_task_set_archive(&pack);
	say_case("program_found", erx_fiasco_launcher_find(&pack, PROGRAM, &program_entry) == ERX_OK);
	warm_up();
	case_between_tasks();
	case_bounds();
	case_revoke();
	case_gate_refusals();
	case_gate_queue();
	case_created();
	case_space_refusals();
	case_released();
	case_first_thread();
	case_budget_calls();
	case_budget_destroy();
	case_groups();
	case_passing();
	say("erx: space: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
