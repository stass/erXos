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
 * records; handles the root passes into a task with erx_cap_pass; a budget whose
 * last handle a task holds, which ends after that task's end; a program's budgets,
 * group and doorbell that a task makes itself; and slices of the
 * image, which a task lists with erx_release_entry, and erx_mem_copy. Each case says
 * one line, which tools/lib/erx/native_space.rb holds the transcript to.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/group_report.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PROGRAM		"boot/native-space"
/* The same program packed as an image entry, as a domain runtime is. */
#define IMAGE_PROGRAM	"boot/native-space-image"
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
#define HELD_LABEL	UINT64_C(0x5e0000000000e000)
#define IMAGE_LABEL	UINT64_C(0x5e0000000000f000)
#define IMAGE_STATUS	78
/* The most tasks one case holds at once: case_created's other task, creator, child and grandchild. */
#define WARM_TASKS	4u
/* More pages than one erx_mem_copy request copies. */
#define COPY_PAGES	66u

void erx_fiasco_root_main(void);

static uint32_t program_entry;
/* The program's entry, the same in every task the launcher makes from its fixed image. */
static uint64_t program_pc;

static void	item_put(size_t, uint64_t, uint32_t, bool);
static uint64_t	item_word(size_t, size_t);

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

/* The tag of the last erx_ipc_wait; record_wait checks that it describes a record. */
static erx_msgtag_t tag;

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

/*
 * The next record at the gates bound to the calling thread, with its label:
 * a message of a record's words and no items.
 */
static bool
record_wait(uint64_t deadline, erx_fault_t *record, uint64_t *label)
{
	const erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t words[sizeof(*record) / sizeof(uint64_t)];

	if (erx_ipc_wait(deadline, &tag, label) != ERX_OK ||
	    erx_msgtag_raw_words_get(tag.raw) != sizeof(words) / sizeof(words[0]) ||
	    erx_msgtag_raw_items_get(tag.raw) != 0)
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
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &tag, &label) == ERX_ETIMEDOUT &&
	    erx_gate_bind(gate, ERX_CAP_NULL, 0) == ERX_OK;
	if (space != 0) {
		int64_t status;

		/* The exit record waits at the unbound gate until the join withdraws it. */
		passed = passed && erx_space_stop(space, 0) == ERX_OK && erx_fiasco_task_join(space, &status) == ERX_OK &&
		    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &tag, &label) == ERX_ETIMEDOUT;
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
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &tag, &label) == ERX_ETIMEDOUT &&
	    erx_fiasco_task_join(first, &status) == ERX_OK && status == 7 &&
	    erx_fiasco_task_join(third, &status) == ERX_OK && status == 8 &&
	    erx_gate_bind(other, ERX_CAP_SELF_THREAD, 0) == ERX_ESTALE;
	passed = passed && erx_cap_close(other) == ERX_OK && erx_cap_close(gate) == ERX_OK &&
	    erx_fiasco_vm_free_pages() == before;
	say_case("gate_queue", passed);
}

/*
 * A task creates spaces below its own and one with a bad parent, and runs the program in
 * its child from a slice of the program's entry that the root passed it (MODE_CREATOR in
 * program.c). The root also makes another task's first thread and passes its handle,
 * which the creator may not start: the root's own start of it then succeeds. Each
 * task's end stops and frees what it made, so the pool's pages come back.
 */
static void
case_created(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space = 0, other = 0, slice = 0, thread = 0;
	int64_t status = INT64_MIN, other_status = INT64_MIN;
	bool passed = erx_image_slice(0, 0, program_entry, 1, &slice) == ERX_OK &&
	    erx_fiasco_launch_make(program_entry, 0, &other, &program_pc) == ERX_OK;

	if (passed) {
		erx_fiasco_launch_set_registers(program_pc, FIRST_TAG << SLOT_SHIFT | MODE_FIRST);
		passed = erx_thread_create(0, other, 0, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK &&
		    erx_fiasco_launch_make(program_entry, 0, &space, &program_pc) == ERX_OK;
	}
	if (passed) {
		item_put(0, slice, ERX_HR_READ, false);
		passed = erx_cap_pass(ERX_CAP_SELF, space, 1) == ERX_OK;
	}
	if (passed)
		status = task_finish(space, MODE_CREATOR | item_word(0, 1) << CREATOR_SLICE_SHIFT |
		    thread << CREATOR_THREAD_SHIFT | (uint64_t)program_entry << CREATOR_ENTRY_SHIFT);
	else if (space != 0)
		task_drop(space);
	if (thread != 0 && erx_thread_start(thread) == ERX_OK)
		(void)erx_fiasco_task_join_until(other, erx_fiasco_clock_ns() + WAIT_NS, &other_status);
	else if (other != 0)
		task_drop(other);
	say_count("created_status", (uint64_t)status);
	say_count("created_other_status", (uint64_t)other_status);
	passed = (slice == 0 || erx_cap_close(slice) == ERX_OK) && passed;
	say_case("created", passed && status == 0 && other_status == FIRST_STATUS &&
	    erx_fiasco_vm_free_pages() == before);
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
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &tag, &label) == ERX_ETIMEDOUT;

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
 * is stale once the task is joined. The root's dispatcher stays, so only cases that
 * may find the root with a group of its own follow. The second group takes a grant.
 */
static void
case_groups(void)
{
	const erx_share_t grant = { .cpuset = UINT64_C(0x1) };
	const erx_share_t empty = { .cpuset = 0 };
	uint64_t own, second, domain, space, thread;
	int64_t status = INT64_MIN;
	bool passed = erx_group_create(0, 0, &own) == ERX_OK && erx_group_create(0, 0, &second) == ERX_OK &&
	    erx_group_create(0, 0, &domain) == ERX_OK;

	/* A group the root holds that is not its own takes a grant the service checks and keeps none of. */
	erx_group_grant_store(erx_utcb_self(), &grant);
	passed = passed && erx_group_configure(second) == ERX_OK;
	erx_group_grant_store(erx_utcb_self(), &empty);
	passed = passed && erx_group_configure(second) == ERX_EINVAL &&
	    erx_thread_create(0, 0, second, ERX_THREAD_CLASS_WORKER, &thread) == ERX_ENOTSUP &&
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

/* Whether a pass rewrote the item as a handle of the type with exactly these rights. */
static bool
item_typed(size_t item, erx_ktype_t type, uint32_t rights)
{
	const uint64_t desc = item_word(item, 0);

	return (erx_msg_item_desc_type_get(desc) == type && erx_msg_item_desc_rights_get(desc) == rights &&
	    erx_msg_item_desc_move_get(desc) == 0 && item_word(item, 1) != ERX_CAP_NULL);
}

/* Whether a pass rewrote the item as a memory object's handle with exactly these rights. */
static bool
item_passed(size_t item, uint32_t rights)
{
	return (item_typed(item, ERX_K_MEMORY, rights));
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

/* Whether the root group's epoch moves past epoch before the deadline: some object of the group fired. */
static bool
epoch_moves(uint64_t epoch)
{
	const uint64_t deadline = erx_fiasco_clock_ns() + WAIT_NS;

	while (atomic_load_explicit(&erx_fiasco_group_status()->epoch, memory_order_acquire) == epoch)
		if (erx_fiasco_clock_ns() >= deadline)
			return (false);
	return (true);
}

/*
 * Doorbells between tasks (docs/design-stopgap.md, "Interrupts and readiness"). The
 * root binds a bell to a domain group that has no home yet, so the bind waits, and
 * rings it before the task has a thread: the bind, made once the task's first thread
 * fixes the home and its dispatcher registers, delivers that ring. The root passes the
 * task its handles to the bell and to an object bound to the root's own group; the
 * task's executor takes the bell's label, acks the bell and rings the root's object,
 * which moves the root group's epoch. The task's end takes its group and the bell's
 * bind with it, so the bell's destroy finds it unbound; the other is destroyed bound.
 * A bound object's bind to another group is refused. After case_groups, whose first
 * group is the root's own, which ERX_CAP_SELF names.
 */
static void
case_doorbells(void)
{
	const uint64_t epoch = atomic_load_explicit(&erx_fiasco_group_status()->epoch, memory_order_acquire);
	uint64_t domain = ERX_CAP_NULL, bell = ERX_CAP_NULL, back = ERX_CAP_NULL, task = 0, argument;
	int64_t status = INT64_MIN;
	bool passed = erx_group_create(0, 0, &domain) == ERX_OK && erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &bell) == ERX_OK &&
	    erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &back) == ERX_OK && erx_irq_bind(bell, domain, BELL_LABEL) == ERX_OK &&
	    erx_irq_bind(bell, ERX_CAP_SELF, BELL_LABEL) == ERX_ENOTSUP &&
	    erx_irq_bind(back, ERX_CAP_SELF, BACK_LABEL) == ERX_OK && erx_irq_trigger(bell) == ERX_OK &&
	    erx_fiasco_launch_make(program_entry, 0, &task, &program_pc) == ERX_OK;

	item_put(0, bell, ERX_HR_TRIGGER | ERX_HR_ACK, false);
	item_put(1, back, ERX_HR_TRIGGER, false);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, task, 2) == ERX_OK &&
	    erx_msg_item_desc_type_get(item_word(0, 0)) == ERX_K_IRQ && erx_msg_item_desc_type_get(item_word(1, 0)) == ERX_K_IRQ;
	argument = MODE_BELL | (item_word(0, 1) & HANDLE_MASK) << BELL_SHIFT | (item_word(1, 1) & HANDLE_MASK) << BACK_SHIFT;
	if (passed && group_start(task, domain, argument)) {
		if (erx_fiasco_task_join_until(task, erx_fiasco_clock_ns() + WAIT_NS, &status) != ERX_OK)
			status = INT64_MIN;
	} else if (task != 0) {
		task_drop(task);
	}
	say_count("bell_status", (uint64_t)status);
	passed = passed && status == 0 && epoch_moves(epoch);
	passed = passed && erx_object_destroy(domain) == ERX_ESTALE && erx_object_destroy(bell) == ERX_OK &&
	    erx_object_destroy(back) == ERX_OK && erx_irq_trigger(bell) == ERX_ESTALE;
	say_case("doorbells", passed);
}

/*
 * A task makes a program's records from its own authority, as a session does (MODE_MAKER
 * in program.c): budgets, groups, a channel and a child that runs, from a slice of the
 * program's entry the root passed it, in the new group, with the handles the task
 * passed it and their values in its argument registers, and a second program that rings
 * the child's doorbell through a copy passed with TRIGGER alone. The root starts the
 * task in a domain group, its home, into which the task binds its bell, and waits for it
 * up to MADE_WAIT_NS, longer than the task's own nested waits, so the transcript shows
 * the step at which a failed task stopped. The task's end takes the domain group with it,
 * and the pages come back. After case_doorbells, as the root already has a group of its
 * own.
 */
#define MADE_WAIT_NS	(3 * WAIT_NS)

static void
case_made(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t domain = ERX_CAP_NULL, slice = ERX_CAP_NULL, task = 0;
	int64_t status = INT64_MIN;
	bool passed = erx_group_create(0, 0, &domain) == ERX_OK && erx_image_slice(0, 0, program_entry, 1, &slice) == ERX_OK &&
	    erx_fiasco_launch_make(program_entry, 0, &task, &program_pc) == ERX_OK;

	item_put(0, slice, ERX_HR_READ, false);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, task, 1) == ERX_OK;
	if (passed && group_start(task, domain, MODE_MAKER | (item_word(0, 1) & HANDLE_MASK) << MAKER_SLICE_SHIFT)) {
		if (erx_fiasco_task_join_until(task, erx_fiasco_clock_ns() + MADE_WAIT_NS, &status) != ERX_OK)
			status = INT64_MIN;
	} else if (task != 0) {
		task_drop(task);
	}
	say_count("made_status", (uint64_t)status);
	passed = passed && status == 0 && erx_object_destroy(domain) == ERX_ESTALE;
	passed = erx_cap_close(slice) == ERX_OK && passed;
	say_case("made", passed && erx_fiasco_vm_free_pages() == before);
}

/*
 * A task that holds the last handle of the budget its own space is charged to ends that
 * budget with its own end. The root moves the budget and a group charged to it into
 * the space, so it keeps no handle to either, and starts the space's first thread,
 * which ends with FIRST_STATUS. The space ends once: its end closes its handles, and
 * the budget's end, which waits until the space's row is reset, deletes the space and
 * everything else charged to the budget. The deletion withdraws the exit record, as
 * every deletion does, so none reaches the root's gate; the root's handles to the
 * space and to a memory object charged to the budget are stale, and the pages come
 * back.
 */
static void
case_budget_held(void)
{
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t gate = ERX_CAP_NULL, budget = ERX_CAP_NULL, group = ERX_CAP_NULL, space = ERX_CAP_NULL;
	uint64_t mem = ERX_CAP_NULL, copy, thread, pc, label, deadline;
	erx_fault_t record;
	bool passed = erx_gate_create(0, &gate) == ERX_OK && erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_WALL, 64, 64, &budget) == ERX_OK &&
	    erx_group_create(budget, 0, &group) == ERX_OK && erx_mem_create(budget, PAGE, 0, &mem) == ERX_OK &&
	    erx_space_create(budget, ERX_CAP_SELF, gate, HELD_LABEL, 0, TASK_CAP_LIMIT, &space) == ERX_OK &&
	    erx_image_map(space, 0, program_entry, &pc) == ERX_OK;

	item_put(0, budget, ERX_HR_ALLOC | ERX_HR_DESTROY, true);
	item_put(1, group, ERX_HR_ATTACH | ERX_HR_SIGNAL, true);
	passed = passed && erx_cap_pass(ERX_CAP_SELF, space, 2) == ERX_OK && item_typed(0, ERX_K_BUDGET, ERX_HR_ALLOC) &&
	    item_typed(1, ERX_K_GROUP, ERX_HR_ATTACH | ERX_HR_SIGNAL) && erx_cap_close(budget) == ERX_EINVAL &&
	    erx_cap_close(group) == ERX_EINVAL;
	erx_fiasco_launch_set_registers(program_pc, FIRST_TAG << SLOT_SHIFT | MODE_FIRST);
	passed = passed && erx_thread_create(0, space, 0, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK &&
	    erx_thread_start(thread) == ERX_OK;

	/* The space's stop and the budget's end are one request, so the object stays until both are done. */
	deadline = erx_fiasco_clock_ns() + WAIT_NS;
	while (passed && erx_cap_dup(mem, &copy) == ERX_OK)
		passed = erx_cap_close(copy) == ERX_OK && erx_fiasco_clock_ns() < deadline;
	passed = passed && erx_object_destroy(mem) == ERX_ESTALE && erx_object_destroy(space) == ERX_ESTALE &&
	    !record_wait(erx_fiasco_clock_ns() + SETTLE_NS, &record, &label);
	passed = erx_cap_close(mem) == ERX_OK && erx_cap_close(space) == ERX_OK && erx_cap_close(gate) == ERX_OK && passed;
	say_count("held_free_pages", erx_fiasco_vm_free_pages());
	say_case("budget_held", passed && erx_fiasco_vm_free_pages() == before);
}

/*
 * A slice of the image's two domains/sample/ files, mapped read-only into a task and
 * passed to it, which lists it with erx_release_entry (program.c). A run past the
 * index is ERX_ERANGE, a writable map of the slice ERX_ERIGHTS, and an entry asked of
 * a memory object that is no slice ERX_ETYPE.
 */
static void
case_slices(uint32_t first)
{
	static erx_release_entry_t entry;
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t space = 0, slice = 0, mem = 0, refused;
	int64_t status = INT64_MIN;
	bool passed = erx_image_slice(0, 0, first, 2, &slice) == ERX_OK &&
	    erx_image_slice(0, 0, first, UINT64_C(1) << 32, &refused) == ERX_ERANGE &&
	    erx_mem_create(0, PAGE, 0, &mem) == ERX_OK && erx_fiasco_release_entry(mem, 0, false, &entry) == ERX_ETYPE &&
	    task_make(&space, SLICE_ADDR, SLICE_PAGES) &&
	    erx_vm_map(space, SLICE_ADDR, SLICE_PAGES * PAGE, slice, 0, ERX_PROT_RW) == ERX_ERIGHTS &&
	    erx_vm_map(space, SLICE_ADDR, SLICE_PAGES * PAGE, slice, 0, ERX_PROT_R) == ERX_OK;

	if (passed) {
		item_put(0, slice, ERX_HR_READ, false);
		passed = erx_cap_pass(ERX_CAP_SELF, space, 1) == ERX_OK;
	}
	if (passed)
		status = task_finish(space, MODE_RELEASE | item_word(0, 1) << SLOT_SHIFT);
	else if (space != 0)
		task_drop(space);
	say_count("release_status", (uint64_t)status);
	passed = passed && status == 0;
	passed = (slice == 0 || erx_cap_close(slice) == ERX_OK) && (mem == 0 || erx_cap_close(mem) == ERX_OK) && passed;
	say_case("slices", passed && erx_fiasco_vm_free_pages() == before);
}

/* An object of size bytes mapped read-write into the root at *addr. */
static bool
copy_object(uint64_t size, uint64_t *mem, uint64_t *addr)
{
	return (erx_mem_create(0, size, 0, mem) == ERX_OK && erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, *addr, size, *mem, 0, ERX_PROT_RW) == ERX_OK);
}

static uint64_t
copy_word(uint64_t addr)
{
	return (*(volatile const uint64_t *)(uintptr_t)addr);
}

/*
 * erx_mem_copy of more pages than one request copies, eight bytes off the source's
 * page boundaries; a range a byte past the destination and a source offset whose sum
 * wraps are ERX_ERANGE and leave the destination as it was, a copy into a slice
 * ERX_ERIGHTS, and one from a destroyed object ERX_ESTALE.
 */
static void
case_copy(uint32_t first)
{
	const uint64_t size = COPY_PAGES * PAGE;
	const uint64_t before = erx_fiasco_vm_free_pages();
	uint64_t src = 0, dst = 0, slice = 0, src_addr = 0, dst_addr = 0;
	bool passed = copy_object(size, &src, &src_addr) && copy_object(size, &dst, &dst_addr) &&
	    erx_image_slice(0, 0, first, 1, &slice) == ERX_OK;

	for (uint64_t page = 0; passed && page < COPY_PAGES; page++)
		*(volatile uint64_t *)(uintptr_t)(src_addr + page * PAGE + sizeof(uint64_t)) = ROOT_PATTERN + page;
	passed = passed && erx_mem_copy(dst, 0, src, sizeof(uint64_t), size - sizeof(uint64_t)) == ERX_OK;
	for (uint64_t page = 0; passed && page < COPY_PAGES; page++)
		passed = copy_word(dst_addr + page * PAGE) == ROOT_PATTERN + page;
	passed = passed && erx_mem_copy(dst, 1, src, 0, size) == ERX_ERANGE &&
	    erx_mem_copy(dst, 0, src, UINT64_MAX - 7, 16) == ERX_ERANGE && copy_word(dst_addr) == ROOT_PATTERN &&
	    erx_mem_copy(slice, 0, src, 0, sizeof(uint64_t)) == ERX_ERIGHTS;
	if (src_addr != 0)
		passed = erx_vm_release(ERX_CAP_SELF, src_addr, size) == ERX_OK && passed;
	if (dst_addr != 0)
		passed = erx_vm_release(ERX_CAP_SELF, dst_addr, size) == ERX_OK && passed;
	passed = passed && erx_object_destroy(src) == ERX_OK && erx_mem_copy(dst, 0, src, 0, sizeof(uint64_t)) == ERX_ESTALE;
	passed = (src == 0 || erx_cap_close(src) == ERX_OK) && (dst == 0 || erx_cap_close(dst) == ERX_OK) &&
	    (slice == 0 || erx_cap_close(slice) == ERX_OK) && passed;
	say_case("copy", passed && erx_fiasco_vm_free_pages() == before);
}

/*
 * The root's own tables, and the service's rows for the first WARM_TASKS task indices,
 * as many as one case holds at once (case_created), take their pages here, so no case
 * counts them against its pool.
 */
static void
warm_up(void)
{
	uint64_t mem, addr, gate, label, tasks[WARM_TASKS] = { 0 };

	for (size_t made = 0; made < WARM_TASKS; made++) {
		if (erx_fiasco_launch_make(program_entry, 0, &tasks[made], &program_pc) != ERX_OK) {
			say("erx: space: warm-up refused\n");
			break;
		}
	}
	for (size_t made = WARM_TASKS; made > 0; made--)
		if (tasks[made - 1] != 0)
			task_drop(tasks[made - 1]);

	if (erx_mem_create(0, PAGE, 0, &mem) != ERX_OK || erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, PAGE, mem, 0, ERX_PROT_RW) != ERX_OK ||
	    erx_vm_release(ERX_CAP_SELF, addr, PAGE) != ERX_OK || erx_cap_close(mem) != ERX_OK)
		say("erx: space: warm-up refused\n");
	/* The gate table, and the list of waiting threads up to the root's first thread. */
	if (erx_gate_create(0, &gate) != ERX_OK || erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) != ERX_OK ||
	    erx_ipc_wait(erx_fiasco_clock_ns() + SHORT_NS, &tag, &label) != ERX_ETIMEDOUT || erx_cap_close(gate) != ERX_OK)
		say("erx: space: warm-up refused\n");
}

/*
 * A task reads the wall clock the root set before the task was made, raises its signal,
 * and then sees the root move it: the task reads the root's one page, not a copy.
 */
static void
case_time(void)
{
	uint64_t signal, signal_addr, space, deadline;
	int64_t status = INT64_MIN;
	bool passed = erx_time_set_wall(TIME_FIRST_NS) == ERX_OK && erx_mem_create(0, PAGE, 0, &signal) == ERX_OK &&
	    erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &signal_addr) == ERX_OK &&
	    erx_vm_map(ERX_CAP_SELF, signal_addr, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK && task_make(&space, SIGNAL_ADDR, 1) &&
	    erx_vm_map(space, SIGNAL_ADDR, PAGE, signal, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_fiasco_launch_start(space, program_pc, MODE_TIME) == ERX_OK;
	const bool started = passed;

	/* A task that fails its first read never signals, and its join still shows why. */
	deadline = erx_fiasco_clock_ns() + WAIT_NS;
	while (passed && atomic_load_explicit((_Atomic uint64_t *)(uintptr_t)signal_addr, memory_order_acquire) == 0 &&
	    erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + SHORT_NS, &status) == ERX_ETIMEDOUT)
		passed = erx_fiasco_clock_ns() < deadline;
	passed = passed && status == INT64_MIN && erx_time_set_wall(TIME_SECOND_NS) == ERX_OK;
	if (started && status == INT64_MIN)
		(void)erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + WAIT_NS, &status);
	say_count("time_status", (uint64_t)status);
	passed = passed && status == 0 && erx_vm_release(ERX_CAP_SELF, signal_addr, PAGE) == ERX_OK &&
	    erx_cap_close(signal) == ERX_OK;
	say_case("time", passed);
}

/* A task of the image entry, its records going to gate under label, started with argument. */
static bool
image_task_start(uint32_t entry, uint64_t budget, uint64_t gate, uint64_t label, uint64_t argument, uint64_t *space)
{
	uint64_t pc;

	if (erx_space_create(budget, ERX_CAP_SELF, gate, label, 0, TASK_CAP_LIMIT, space) != ERX_OK)
		return (false);
	if (erx_image_map(*space, 0, entry, &pc) == ERX_OK && pc == program_pc &&
	    erx_fiasco_launch_start(*space, pc, argument) == ERX_OK)
		return (true);
	task_drop(*space);
	return (false);
}

/* Starts a task of the image entry under the root's budget and waits for its status. */
static int64_t
image_task_run(uint32_t entry, uint64_t argument)
{
	uint64_t space;
	int64_t status = INT64_MIN;

	if (!image_task_start(entry, ERX_CAP_SELF, 0, 0, argument, &space) ||
	    erx_fiasco_task_join_until(space, erx_fiasco_clock_ns() + WAIT_NS, &status) != ERX_OK)
		return (INT64_MIN);
	return (status);
}

/*
 * The program packed as an image entry (docs/design-stopgap.md, "The call table",
 * erx_image_map): every task that runs it maps its code and read-only data from the
 * archive's own pages, through one slice the service makes at the entry's first map and
 * charges to the root, and copies only its writable data.
 *
 * The first map is in a space under a budget of its own, which the case destroys once
 * that task has ended; every later task still runs, so the slice outlived the budget.
 * A map of the image entry takes fewer pool pages than one of the same program as a
 * file entry, which copies every segment. Each task finds the program's writable word
 * as linked, though the task before it wrote it. A task that writes its own code faults
 * at its gate, and the tasks before and after it read the same word there.
 */
static void
case_image_shared(uint32_t entry)
{
	uint64_t budget, first, file_space, image_space, gate, writer, label, steady, before, file_taken, image_taken;
	int64_t status = INT64_MIN, code_before, code_after;
	erx_fault_t record;
	bool passed = erx_budget_create(ERX_CAP_SELF, ERX_BUDGET_WALL, 64, 64, &budget) == ERX_OK &&
	    image_task_start(entry, budget, 0, 0, MODE_DATA, &first) &&
	    erx_fiasco_task_join_until(first, erx_fiasco_clock_ns() + WAIT_NS, &status) == ERX_OK && status == 0 &&
	    erx_object_destroy(budget) == ERX_OK && erx_cap_close(budget) == ERX_OK;

	steady = erx_fiasco_vm_free_pages();
	before = steady;
	passed = passed && erx_fiasco_launch_make(program_entry, 0, &file_space, &program_pc) == ERX_OK;
	file_taken = before - erx_fiasco_vm_free_pages();
	if (passed)
		task_drop(file_space);
	before = erx_fiasco_vm_free_pages();
	passed = passed && image_task_start(entry, ERX_CAP_SELF, 0, 0, MODE_DATA, &image_space);
	image_taken = before - erx_fiasco_vm_free_pages();
	passed = passed && erx_fiasco_task_join_until(image_space, erx_fiasco_clock_ns() + WAIT_NS, &status) == ERX_OK &&
	    status == 0;
	say_count("image_file_pages", file_taken);
	say_count("image_shared_pages", image_taken);
	passed = passed && image_taken < file_taken && image_task_run(entry, MODE_DATA) == 0;

	code_before = passed ? image_task_run(entry, MODE_CODE_READ) : INT64_MIN;
	passed = passed && code_before != INT64_MIN && code_before != 0 &&
	    erx_gate_create(0, &gate) == ERX_OK && erx_gate_bind(gate, ERX_CAP_SELF_THREAD, 0) == ERX_OK &&
	    image_task_start(entry, ERX_CAP_SELF, gate, IMAGE_LABEL, MODE_CODE_WRITE, &writer) &&
	    record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label) && label == IMAGE_LABEL &&
	    record.kind == ERX_FAULT_MEMORY && record.space != ERX_FIASCO_TASK_ROOT &&
	    erx_space_stop(writer, IMAGE_STATUS) == ERX_OK &&
	    record_wait(erx_fiasco_clock_ns() + WAIT_NS, &record, &label) &&
	    exit_record_is(&record, IMAGE_LABEL, label, IMAGE_STATUS) &&
	    erx_fiasco_task_join_until(writer, erx_fiasco_clock_ns() + WAIT_NS, &status) == ERX_OK &&
	    status == IMAGE_STATUS && erx_object_destroy(gate) == ERX_OK && erx_cap_close(gate) == ERX_OK;
	code_after = passed ? image_task_run(entry, MODE_CODE_READ) : INT64_MIN;
	passed = passed && code_after == code_before && erx_fiasco_vm_free_pages() == steady;
	say_case("image_shared", passed);
}

void
erx_fiasco_root_main(void)
{
	erx_boot_handoff_view_t handoff;
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);
	uint32_t release_first = 0, image_entry = 0;

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
	case_time();
	case_budget_held();
	case_doorbells();
	case_made();
	if (erx_fiasco_launcher_find(&pack, RELEASE_FIRST_PATH, &release_first) != ERX_OK)
		say("erx: space: no domain release\n");
	case_slices(release_first);
	case_copy(release_first);
	if (erx_fiasco_launcher_find(&pack, IMAGE_PROGRAM, &image_entry) != ERX_OK)
		say("erx: space: no image program\n");
	case_image_shared(image_entry);
	say("erx: space: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	erx_fiasco_sleep_forever();
}
