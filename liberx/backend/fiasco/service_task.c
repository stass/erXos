/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What the service does about a task as a whole: its capabilities in the root, its
 * creation, its image, and its end (docs/design-stopgap.md, "Task exit"). The root
 * holds a capability to everything it makes, in a run of slots per task past its
 * own; the task holds only its gate and its semaphores, which the root maps to it.
 *
 * A task's end needs no list of what it holds: every thread and semaphore has its
 * slot by index, and every page is in the task's range table or one of its objects.
 */

#include <stddef.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/semaphore.h>
#include <l4/sys/task.h>

#include "erx/abi.h"
#include "erx/core/crash.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/root_mem.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

/* A task's run of slots: its threads, its semaphores, then the three below. */
#define TASK_SLOT_GATE		(2 * ERX_FIASCO_THREADS_MAX)
#define TASK_SLOT_SPACE		(TASK_SLOT_GATE + 1)
#define TASK_SLOT_ENDED		(TASK_SLOT_GATE + 2)
#define TASK_SLOTS		(TASK_SLOT_GATE + 3)
#define TASK_TABLE_BYTES	(ERX_FIASCO_THREADS_MAX * UINT64_C(2048))
#define TASK_PAGE_MASK		((uint64_t)ERX_PAGE_SIZE - 1)

_Static_assert(ERX_FIASCO_TASKS_MAX <= 64, "the decoder's mask holds every task");

static uint64_t	task_slot(uint32_t, uint32_t);
static bool	task_failed(l4_msgtag_t);
static void	task_end(uint32_t, int64_t);
static void	task_delete(uint64_t);
static bool	task_segment_load(uint32_t, const uint8_t *, const erx_elf_load_t *, uint64_t);

static erx_fiasco_task_t task_rows[ERX_FIASCO_TASKS_MAX];
static const erx_pack_view_t *task_archive;
/* One plan at a time, as the service runs one body: too large for its stack to spare. */
static erx_elf_plan_t task_plan;

erx_fiasco_task_t *
erx_fiasco_task(uint32_t task)
{
	return (&task_rows[task]);
}

uint64_t
erx_fiasco_task_live_mask(void)
{
	uint64_t mask = 0;

	for (uint32_t task = 0; task < ERX_FIASCO_TASKS_MAX; task++)
		if (task_rows[task].state == ERX_FIASCO_TASK_LIVE)
			mask |= UINT64_C(1) << task;
	return (mask);
}

void
erx_fiasco_task_table_init(void)
{
	task_rows[ERX_FIASCO_TASK_ROOT].state = ERX_FIASCO_TASK_LIVE;
	task_rows[ERX_FIASCO_TASK_ROOT].threads[0] = ERX_FIASCO_TASK_THREAD_STARTED;
}

void
erx_fiasco_task_set_archive(const erx_pack_view_t *view)
{
	task_archive = view;
}

static uint64_t
task_slot(uint32_t task, uint32_t slot)
{
	return (erx_fiasco_thread_cap(ERX_FIASCO_SLOT_TASK_RUNS + (task - 1) * TASK_SLOTS + slot));
}

/* The first thread's capability is the one the kernel gave it. */
uint64_t
erx_fiasco_task_thread_cap(uint32_t task, uint32_t index)
{
	if (task != ERX_FIASCO_TASK_ROOT)
		return (task_slot(task, index));
	return (index == 0 ? L4_BASE_THREAD_CAP : erx_fiasco_thread_cap(index));
}

uint64_t
erx_fiasco_task_semaphore_cap(uint32_t task, uint32_t index)
{
	if (task != ERX_FIASCO_TASK_ROOT)
		return (task_slot(task, ERX_FIASCO_THREADS_MAX + index));
	return (erx_fiasco_thread_semaphore_cap(index));
}

uint64_t
erx_fiasco_task_gate_cap(uint32_t task)
{
	return (task != ERX_FIASCO_TASK_ROOT ? task_slot(task, TASK_SLOT_GATE) : erx_fiasco_service_gate());
}

uint64_t
erx_fiasco_task_gate_slot(uint32_t task)
{
	return (task != ERX_FIASCO_TASK_ROOT ? L4_BASE_PAGER_CAP : erx_fiasco_service_gate());
}

uint64_t
erx_fiasco_task_cap(uint32_t task)
{
	return (task != ERX_FIASCO_TASK_ROOT ? task_slot(task, TASK_SLOT_SPACE) : L4_BASE_TASK_CAP);
}

uint64_t
erx_fiasco_task_ended_cap(uint64_t task)
{
	return (task_slot((uint32_t)task, TASK_SLOT_ENDED));
}

void *
erx_fiasco_task_record(uint32_t task, uint32_t index)
{
	const uint64_t record = (uint64_t)(uintptr_t)erx_fiasco_thread_record(index);
	const uintptr_t window = erx_fiasco_vm_task_window(task, record & ~TASK_PAGE_MASK);

	return (window != 0 ? (void *)(window + (uintptr_t)(record & TASK_PAGE_MASK)) : NULL);
}

static bool
task_failed(l4_msgtag_t tag)
{
	return (l4_error(tag) < 0);
}

/*
 * Everything a task has before its first thread: its space, with the thread table's
 * UTCB area, its gate mapped where its threads call, and its committed thread table.
 * A failure undoes what ran, through the one path a task ends by.
 */
int
erx_fiasco_task_create_body(uint32_t caller, uint64_t flags, uint64_t *space)
{
	l4_fpage_t area = l4_fpage(erx_fiasco_thread_native_slot(0), ERX_FIASCO_UTCB_AREA_ORDER, L4_FPAGE_RW);
	const uint64_t table = (uint64_t)(uintptr_t)erx_fiasco_thread_record(0);
	uint64_t reserved;
	uint32_t task = 1;

	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	if ((flags & ~(uint64_t)ERX_SPACE_JIT) != 0)
		return (ERX_EINVAL);
	while (task < ERX_FIASCO_TASKS_MAX && task_rows[task].state != ERX_FIASCO_TASK_ABSENT)
		task++;
	if (task == ERX_FIASCO_TASKS_MAX)
		return (ERX_ENOMEM);

	task_rows[task] = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_LIVE, .flags = (uint32_t)flags };
	erx_fiasco_vm_task_open(task);
	if (task_failed(l4_factory_create_task(L4_BASE_FACTORY_CAP, erx_fiasco_task_cap(task), &area)) ||
	    task_failed(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE, erx_fiasco_task_ended_cap(task))) ||
	    task_failed(l4_factory_create_gate(L4_BASE_FACTORY_CAP, erx_fiasco_task_gate_cap(task),
	    erx_fiasco_service_thread(), task << ERX_FIASCO_WIRE_LABEL_SHIFT)) ||
	    task_failed(l4_task_map(erx_fiasco_task_cap(task), L4_BASE_TASK_CAP,
	    l4_obj_fpage(erx_fiasco_task_gate_cap(task), 0, L4_CAP_FPAGE_RWS),
	    l4_map_obj_control(L4_BASE_PAGER_CAP, L4_MAP_ITEM_MAP))) ||
	    erx_fiasco_vm_body(task, ERX_FIASCO_VM_RESERVE, table, TASK_TABLE_BYTES, ERX_VM_FIXED, &reserved) != ERX_OK ||
	    erx_fiasco_vm_body(task, ERX_FIASCO_VM_COMMIT, table, TASK_TABLE_BYTES, 0, NULL) != ERX_OK) {
		task_end(task, 0);
		task_delete(erx_fiasco_task_ended_cap(task));
		task_rows[task].state = ERX_FIASCO_TASK_ABSENT;
		return (ERX_ENOMEM);
	}
	*space = task;
	return (ERX_OK);
}

/*
 * One segment's pages: committed read-write, filled through the window, whose rest
 * is the pool's zeroes, and then given the segment's protection. Code is cleaned and
 * invalidated through the window before any thread can run it.
 */
static bool
task_segment_load(uint32_t task, const uint8_t *image, const erx_elf_load_t *load, uint64_t base)
{
	const uint64_t start = base + load->segment.mem_offset;
	const uint64_t size = (load->segment.mem_size + TASK_PAGE_MASK) & ~TASK_PAGE_MASK;
	uint64_t reserved;

	if (erx_fiasco_vm_body(task, ERX_FIASCO_VM_RESERVE, start, size, ERX_VM_FIXED | ERX_VM_NOREPLACE, &reserved) != ERX_OK ||
	    erx_fiasco_vm_body(task, ERX_FIASCO_VM_COMMIT, start, size, 0, NULL) != ERX_OK)
		return (false);
	for (uint64_t done = 0; done < size; done += ERX_PAGE_SIZE) {
		const uintptr_t window = erx_fiasco_vm_task_window(task, start + done);

		if (done < load->segment.file_size) {
			const uint64_t rest = load->segment.file_size - done;

			bcopy(image + load->source_offset + done, (void *)window, rest < ERX_PAGE_SIZE ? (size_t)rest : ERX_PAGE_SIZE);
		}
		if (load->segment.prot == ERX_PROT_RX)
			erx_fiasco_cache_make_coherent(window, ERX_PAGE_SIZE);
	}
	return (erx_fiasco_vm_body(task, ERX_FIASCO_VM_PROTECT, start, size, load->segment.prot, NULL) == ERX_OK);
}

/*
 * The kernel's call takes a slice of the image and an entry of it; this backend has
 * one image, the boot archive, and no slices, so image is ignored. Only a program
 * linked at fixed addresses can load, as there is no relocation here.
 */
int
erx_fiasco_task_image_map_body(uint32_t caller, uint64_t space, uint64_t entry, uint64_t *start)
{
	erx_pack_entry_t file;
	erx_elf_error_t error;
	const uint8_t *image;

	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	if (space == ERX_FIASCO_TASK_ROOT || space >= ERX_FIASCO_TASKS_MAX || entry > UINT32_MAX ||
	    task_rows[space].state != ERX_FIASCO_TASK_LIVE || task_archive == NULL ||
	    !erx_pack_entry_at(task_archive, (uint32_t)entry, &file))
		return (ERX_EINVAL);
	image = task_archive->bytes + file.data_off;
	if (!erx_elf_plan(image, (size_t)file.data_size, UINT64_MAX, &task_plan, &error) ||
	    (task_plan.flags & ERX_IMAGE_FIXED) == 0)
		return (ERX_EINVAL);
	for (uint32_t load = 0; load < task_plan.nloads; load++)
		if (!task_segment_load((uint32_t)space, image, &task_plan.loads[load], task_plan.fixed_base))
			return (ERX_ENOMEM);
	task_rows[space].entry = task_plan.fixed_base + task_plan.entry;
	*start = task_rows[space].entry;
	return (ERX_OK);
}

static void
task_delete(uint64_t cap)
{
	static const char line[] = "erx: service: the kernel refused a task's deletion\n";

	if (task_failed(l4_task_delete_obj(L4_BASE_TASK_CAP, cap))) {
		erx_fiasco_console_write(line, sizeof(line) - 1);
		erx_fiasco_machine_off();
	}
}

/*
 * The design's steps, in order. Deleting a thread leaves its slots empty and its
 * IPC gone, so a thread blocked on the gate is no request any more. Deleting what a
 * failed create never made is a no-op to the kernel.
 */
static void
task_end(uint32_t task, int64_t status)
{
	erx_fiasco_task_t *const row = &task_rows[task];

	for (uint32_t index = ERX_FIASCO_THREADS_MAX; index-- > 0;)
		if (row->threads[index] != ERX_FIASCO_TASK_THREAD_ABSENT)
			task_delete(erx_fiasco_task_thread_cap(task, index));
	for (uint32_t index = ERX_FIASCO_THREADS_MAX; index-- > 0;)
		if (row->threads[index] != ERX_FIASCO_TASK_THREAD_ABSENT)
			task_delete(erx_fiasco_task_semaphore_cap(task, index));
	task_delete(erx_fiasco_task_gate_cap(task));
	task_delete(erx_fiasco_task_cap(task));
	erx_fiasco_vm_task_close(task);
	*row = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_ENDED, .status = status };
	(void)l4_semaphore_up(erx_fiasco_task_ended_cap(task));
}

/* A task stops itself or the root stops it; the root's own stop is the machine's end. */
int
erx_fiasco_task_stop_body(uint32_t caller, uint64_t space, int64_t status)
{
	const uint64_t target = space == ERX_CAP_SELF ? caller : space;

	if (target >= ERX_FIASCO_TASKS_MAX || task_rows[target].state != ERX_FIASCO_TASK_LIVE)
		return (ERX_EINVAL);
	if (caller != ERX_FIASCO_TASK_ROOT && target != caller)
		return (ERX_ERIGHTS);
	if (target == ERX_FIASCO_TASK_ROOT)
		erx_fiasco_end(NULL, ERX_END_OFF);
	task_end((uint32_t)target, status);
	return (target == caller ? ERX_FIASCO_NO_REPLY : ERX_OK);
}

/* The caller has seen the ended semaphore's up, so the row's status is there. */
int
erx_fiasco_task_join_body(uint32_t caller, uint64_t space, int64_t *status)
{
	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	if (space == ERX_FIASCO_TASK_ROOT || space >= ERX_FIASCO_TASKS_MAX || task_rows[space].state != ERX_FIASCO_TASK_ENDED)
		return (ERX_EINVAL);
	*status = task_rows[space].status;
	task_delete(erx_fiasco_task_ended_cap((uint32_t)space));
	task_rows[space].state = ERX_FIASCO_TASK_ABSENT;
	return (ERX_OK);
}

int
erx_fiasco_task_mem_create_body(uint32_t caller, uint64_t size, uint64_t flags, uint64_t *mem)
{
	if ((flags & ~(uint64_t)ERX_MEM_JIT) != 0 || size == 0 || (size & TASK_PAGE_MASK) != 0)
		return (ERX_EINVAL);
	if ((flags & ERX_MEM_JIT) != 0 && (task_rows[caller].flags & ERX_SPACE_JIT) == 0)
		return (ERX_ERIGHTS);
	return (erx_fiasco_vm_object_create(caller, size, mem));
}

/* A task's objects map into the task alone: nothing yet maps one across tasks. */
int
erx_fiasco_task_vm_map_body(uint32_t caller, const erx_fiasco_vm_map_request_t *request)
{
	if (request->space != ERX_CAP_SELF)
		return (ERX_ENOTSUP);
	if (request->prot > UINT32_MAX)
		return (ERX_EINVAL);
	return (erx_fiasco_vm_object_map(caller, request->mem, request->addr, request->size, request->offset,
	    (uint32_t)request->prot));
}

void
erx_fiasco_task_fault(uint32_t task, const erx_crash_fault_t *fault)
{
	erx_fiasco_task_crash_write(fault);
	task_end(task, ERX_FIASCO_TASK_STATUS_FAULT);
}

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdbool.h>

/* Whether every capability the root held for this task's index reads as gone. */
bool
erx_fiasco_test_task_caps_gone(uint32_t task)
{
	const uint64_t caps[] = { erx_fiasco_task_gate_cap(task), erx_fiasco_task_cap(task) };

	for (size_t cap = 0; cap < sizeof(caps) / sizeof(caps[0]); cap++)
		if (l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, caps[cap])) != 0)
			return (false);
	for (uint32_t index = 0; index < ERX_FIASCO_THREADS_MAX; index++)
		if (l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, erx_fiasco_task_thread_cap(task, index))) != 0 ||
		    l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, erx_fiasco_task_semaphore_cap(task, index))) != 0)
			return (false);
	return (true);
}
#endif
