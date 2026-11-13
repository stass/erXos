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

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/semaphore.h>
#include <l4/sys/task.h>

#include "erx/abi.h"
#include "erx/core/crash.h"
#include "erx/core/debug_log.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/root_mem.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/core/device_check.h"
#include "liberx/backend/core/grow_table.h"
#include "liberx/backend/fiasco/budget.h"
#include "liberx/backend/fiasco/fault_gate.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/slice.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/trace.h"
#include "liberx/backend/fiasco/vm.h"

/* A task's run of slots: its threads, its semaphores, then the three below. */
#define TASK_SLOT_GATE		(2 * ERX_FIASCO_THREADS_MAX)
#define TASK_SLOT_SPACE		(TASK_SLOT_GATE + 1)
#define TASK_SLOT_ENDED		(TASK_SLOT_GATE + 2)
#define TASK_SLOTS		(TASK_SLOT_GATE + 3)

/* What erx_space_create hands the fill of its space record. */
typedef struct task_create {
	const erx_fiasco_space_create_request_t *request;
	uint32_t	parent;		/* the parent's task */
	uint32_t	gate;		/* as erx_fiasco_gate_named gave it */
} task_create_t;

static uint64_t	task_slot(uint32_t, uint32_t);
static uint32_t	*task_space_of(uint32_t);
static int	task_space_named(uint32_t, uint64_t, uint32_t *);
static bool	task_failed(l4_msgtag_t);
static bool	task_objects_make(uint32_t);
static int	task_fill_space(uint32_t, const void *);
static void	task_teardown(uint32_t);
static void	task_end(uint32_t, uint32_t, int64_t);
static uint32_t	task_live_child(uint32_t);
static void	task_stop_tree(uint32_t, uint32_t, int64_t);
static void	task_remove(uint32_t);
static void	task_delete_tree(uint32_t);
static void	task_delete(uint64_t);
static bool	task_segment_load(uint32_t, const uint8_t *, const erx_elf_load_t *, uint64_t);
static bool	task_segment_share(uint32_t, uint32_t, const erx_elf_load_t *, uint64_t);
static int	task_image_slice(uint32_t, uint32_t *);
static int	task_fill_pages(uint32_t, const void *);
static int	task_fill_physical(uint32_t, const void *);
static int	task_fill_contiguous(uint32_t, const void *);

_Static_assert(sizeof(erx_fiasco_task_t) <= ERX_PAGE_SIZE, "a task's row fits a page of its table");

/* erx_fiasco_task_t by index, the root's first. */
static erx_backend_grow_table_t task_rows;
/*
 * A uint32_t by space record's index: its task's index plus one while the task's row
 * lives, so a live record always names a row; 0 once the space is deleted, as its
 * record is ended.
 */
static erx_backend_grow_table_t task_spaces;
static const erx_pack_view_t *task_archive;
/* By archive entry: its image slice's object record index plus one, or 0 before its first map. */
static erx_backend_grow_table_t task_image_slices;
/* One plan at a time, as the service runs one body: too large for its stack to spare. */
static erx_elf_plan_t task_plan;

erx_fiasco_task_t *
erx_fiasco_task(uint32_t task)
{
	return (erx_backend_grow_table_at(&task_rows, task));
}

bool
erx_fiasco_task_live(uint32_t task)
{
	const erx_fiasco_task_t *const row = erx_backend_grow_table_at(&task_rows, task);

	return (row != NULL && row->state == ERX_FIASCO_TASK_LIVE);
}

bool
erx_fiasco_task_group_home(uint32_t record, uint32_t *task)
{
	for (uint32_t index = 0; index < erx_backend_grow_table_capacity(&task_rows); index++) {
		const erx_fiasco_task_t *const row = erx_fiasco_task(index);

		if (row->state == ERX_FIASCO_TASK_LIVE && row->group == record + 1) {
			*task = index;
			return (true);
		}
	}
	return (false);
}

const char *
erx_fiasco_task_table_init(void)
{
	const char *reason;

	erx_backend_grow_table_init(&task_rows, sizeof(erx_fiasco_task_t), &erx_fiasco_vm_records);
	erx_backend_grow_table_init(&task_spaces, sizeof(uint32_t), &erx_fiasco_vm_records);
	erx_backend_grow_table_init(&task_image_slices, sizeof(uint32_t), &erx_fiasco_vm_records);
	/* Both first pages now, so a task's first create takes no table page a page count would miss. */
	if (erx_backend_grow_table_room(&task_rows, 1) != ERX_OK || erx_backend_grow_table_room(&task_spaces, 1) != ERX_OK)
		return ("memory: the pool cannot hold the task table");
	reason = erx_fiasco_object_init();
	if (reason == NULL)
		reason = erx_fiasco_gate_init();
	if (reason == NULL)
		reason = erx_fiasco_budget_init();
	if (reason != NULL)
		return (reason);
	erx_fiasco_task(ERX_FIASCO_TASK_ROOT)->state = ERX_FIASCO_TASK_LIVE;
	erx_fiasco_task(ERX_FIASCO_TASK_ROOT)->threads[0] = ERX_FIASCO_TASK_THREAD_STARTED;
	return (NULL);
}

void
erx_fiasco_task_set_archive(const erx_pack_view_t *view)
{
	task_archive = view;
}

const erx_pack_view_t *
erx_fiasco_task_archive(void)
{
	return (task_archive);
}

static uint32_t *
task_space_of(uint32_t record)
{
	return (erx_backend_grow_table_at(&task_spaces, record));
}

/*
 * The task a space handle of the caller's names, stopped or not: ERX_CAP_SELF is the
 * caller's own, and any other value an entry of its handle table naming a space record,
 * which only the space's creator holds, since no space handle passes. Else the entry's
 * refusal.
 */
static int
task_space_named(uint32_t caller, uint64_t space, uint32_t *task)
{
	uint32_t record;
	int status;

	if (space == ERX_CAP_SELF) {
		*task = caller;
		return (ERX_OK);
	}
	status = erx_fiasco_object_find(caller, space, ERX_BACKEND_OBJECT_SPACE, &record);
	if (status == ERX_OK)
		*task = *task_space_of(record) - 1;
	return (status);
}

int
erx_fiasco_task_space_target(uint32_t caller, uint64_t space, uint32_t *task)
{
	const int status = task_space_named(caller, space, task);

	if (status != ERX_OK)
		return (status);
	return (erx_fiasco_task(*task)->state == ERX_FIASCO_TASK_LIVE ? ERX_OK : ERX_EINVAL);
}

/* The space record outlives no creator: the creator's end releases the space with it. */
bool
erx_fiasco_task_created_by(uint32_t task, uint32_t caller)
{
	const uint32_t space = erx_fiasco_task(task)->tree.space;

	return (space != 0 && erx_fiasco_object_at(space - 1)->creator == caller);
}

static uint64_t
task_slot(uint32_t task, uint32_t slot)
{
	return (erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_TASK_RUNS + (task - 1) * TASK_SLOTS + slot));
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

void
erx_fiasco_task_thread_map(uint32_t task, uint64_t map[2])
{
	_Static_assert(ERX_FIASCO_THREADS_MAX <= 2 * 64, "a task's threads fit the map");
	const erx_fiasco_task_t *const row = erx_fiasco_task(task);

	map[0] = map[1] = 0;
	for (uint32_t index = 0; index < ERX_FIASCO_THREADS_MAX; index++)
		if (row->threads[index] != ERX_FIASCO_TASK_THREAD_ABSENT)
			map[index / 64] |= UINT64_C(1) << (index % 64);
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
	const uintptr_t window = erx_fiasco_vm_task_window(task, record & ~ERX_BACKEND_VM_PAGE_MASK);

	return (window != 0 ? (void *)(window + (uintptr_t)(record & ERX_BACKEND_VM_PAGE_MASK)) : NULL);
}

static bool
task_failed(l4_msgtag_t tag)
{
	return (l4_error(tag) < 0);
}

/*
 * Everything a task has before its first thread: its space, with the thread table's
 * UTCB area, its ended semaphore, its gate mapped where its threads call, its
 * committed thread table and the time page. False at the first step that fails, with what ran still there.
 */
static bool
task_objects_make(uint32_t task)
{
	l4_fpage_t area = l4_fpage(erx_fiasco_thread_native_slot(0), ERX_FIASCO_UTCB_AREA_ORDER, L4_FPAGE_RW);
	const uint64_t table = (uint64_t)(uintptr_t)erx_fiasco_thread_record(0);
	uint64_t reserved;

	if (task_failed(l4_factory_create_task(L4_BASE_FACTORY_CAP, erx_fiasco_task_cap(task), &area)) ||
	    task_failed(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE, erx_fiasco_task_ended_cap(task))) ||
	    task_failed(l4_factory_create_gate(L4_BASE_FACTORY_CAP, erx_fiasco_task_gate_cap(task),
	    erx_fiasco_service_thread(), task << ERX_FIASCO_WIRE_LABEL_SHIFT)) ||
	    task_failed(l4_task_map(erx_fiasco_task_cap(task), L4_BASE_TASK_CAP,
	    l4_obj_fpage(erx_fiasco_task_gate_cap(task), 0, L4_CAP_FPAGE_RWS),
	    l4_map_obj_control(L4_BASE_PAGER_CAP, L4_MAP_ITEM_MAP))))
		return (false);
	return (erx_fiasco_vm_body(task, ERX_BACKEND_VM_RESERVE, table, ERX_FIASCO_TASK_AREA_BYTES, ERX_VM_FIXED,
	    &reserved) == ERX_OK &&
	    erx_fiasco_vm_body(task, ERX_BACKEND_VM_COMMIT, table, ERX_FIASCO_TASK_AREA_BYTES, 0, NULL) == ERX_OK &&
	    erx_fiasco_vm_body(task, ERX_BACKEND_VM_RESERVE, ERX_FIASCO_TIME_PAGE_ADDR, ERX_PAGE_SIZE, ERX_VM_FIXED,
	    &reserved) == ERX_OK && erx_fiasco_time_page_map(task) == ERX_OK);
}

/*
 * A space is an object record of kind space, which the caller's handle names, and a
 * task row, which the record names by task_spaces: the record is made, then filled by
 * task_fill_space, then the handle added, all through object.c's one create path.
 */
int
erx_fiasco_task_create_body(uint32_t caller, const erx_fiasco_space_create_request_t *request, uint64_t *space)
{
	const uint64_t flags = request->flags, cap_limit = request->cap_limit;
	task_create_t create = { .request = request };

	if ((flags & ~(uint64_t)ERX_SPACE_JIT) != 0 || cap_limit < 2 || cap_limit > ERX_CAPS_MAX)
		return (ERX_EINVAL);
	if (task_space_named(caller, request->parent, &create.parent) != ERX_OK ||
	    erx_fiasco_gate_named(caller, request->fault, &create.gate) != ERX_OK)
		return (ERX_ETYPE);
	/* A stopped space takes no child, so a stop's walk of the tree below it is final. */
	if (erx_fiasco_task(create.parent)->state != ERX_FIASCO_TASK_LIVE)
		return (ERX_EINVAL);
	/* The right to make code follows from the image: only the root, or a JIT space, makes a JIT space. */
	if ((flags & ERX_SPACE_JIT) != 0 && caller != ERX_FIASCO_TASK_ROOT &&
	    (erx_fiasco_task(caller)->flags & ERX_SPACE_JIT) == 0)
		return (ERX_ERIGHTS);
	return (erx_fiasco_object_create(caller, ERX_BACKEND_OBJECT_SPACE, request->budget, task_fill_space, &create,
	    space));
}

/*
 * The fill of a new space record: a free task row with everything a task has before
 * its first thread, on its parent's list. On failure nothing of the task is left.
 */
static int
task_fill_space(uint32_t record, const void *argument)
{
	const task_create_t *const create = argument;
	erx_fiasco_task_t *parent;
	uint32_t task = 1;

	while (task < erx_backend_grow_table_capacity(&task_rows) && erx_fiasco_task(task)->state != ERX_FIASCO_TASK_ABSENT)
		task++;
	/* A row past the capacity takes a page that stays the table's if the range table cannot open. */
	if (erx_backend_grow_table_room(&task_rows, task + 1) != ERX_OK ||
	    erx_backend_grow_table_room(&task_spaces, record + 1) != ERX_OK)
		return (ERX_ENOMEM);
	/* As on erXos's kernel, the limit counts slot 0, ERX_CAP_NULL, which no entry is. */
	if (erx_fiasco_object_task_open(task, (uint32_t)create->request->cap_limit - 1) != ERX_OK)
		return (ERX_ENOMEM);
	if (erx_fiasco_vm_task_open(task) != ERX_OK) {
		erx_fiasco_object_task_close(task);
		return (ERX_ENOMEM);
	}
	if (erx_fiasco_gate_space_open(task, create->gate, create->request->label) != ERX_OK) {
		erx_fiasco_vm_task_close(task);
		erx_fiasco_object_task_close(task);
		return (ERX_ENOMEM);
	}

	*erx_fiasco_task(task) = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_LIVE, .flags = (uint32_t)create->request->flags };
	if (!task_objects_make(task)) {
		/* No thread ever ran, so nobody waits on the ended semaphore and no status is owed. */
		task_teardown(task);
		erx_fiasco_gate_space_close(task);
		task_delete(erx_fiasco_task_ended_cap(task));
		*erx_fiasco_task(task) = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_ABSENT };
		return (ERX_ENOMEM);
	}
	parent = erx_fiasco_task(create->parent);
	erx_fiasco_task(task)->tree = (erx_fiasco_task_tree_t){ .parent = create->parent, .sibling = parent->tree.child,
	    .space = record + 1 };
	parent->tree.child = task;
	*task_space_of(record) = task + 1;
	erx_fiasco_trace_service(ERX_TRACE_EVENT_SPACE_START, (uint64_t)task + 1, 0, 0);
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
	const uint64_t size = (load->segment.mem_size + ERX_BACKEND_VM_PAGE_MASK) & ~ERX_BACKEND_VM_PAGE_MASK;
	uint64_t reserved;

	if (erx_fiasco_vm_body(task, ERX_BACKEND_VM_RESERVE, start, size, ERX_VM_FIXED | ERX_VM_NOREPLACE, &reserved) != ERX_OK ||
	    erx_fiasco_vm_body(task, ERX_BACKEND_VM_COMMIT, start, size, 0, NULL) != ERX_OK)
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
	return (erx_fiasco_vm_body(task, ERX_BACKEND_VM_PROTECT, start, size, load->segment.prot, NULL) == ERX_OK);
}

/*
 * One read-only or read-execute segment of an image entry: the entry's own pages in the
 * archive, mapped from its slice at the segment's protection. The pack tool stores such a
 * segment's whole memory from a page boundary, zero past its file bytes, which the
 * file check at the slice's making holds, so its pages are the slice's from its file
 * offset; the map refuses an offset off a page and pages past the slice.
 */
static bool
task_segment_share(uint32_t task, uint32_t slice, const erx_elf_load_t *load, uint64_t base)
{
	const uint64_t start = base + load->segment.mem_offset;
	const uint64_t size = (load->segment.mem_size + ERX_BACKEND_VM_PAGE_MASK) & ~ERX_BACKEND_VM_PAGE_MASK;
	uint64_t reserved;

	return (erx_fiasco_vm_body(task, ERX_BACKEND_VM_RESERVE, start, size, ERX_VM_FIXED | ERX_VM_NOREPLACE, &reserved) ==
	    ERX_OK && erx_fiasco_vm_image_map(task, slice, start, size, load->source_offset, load->segment.prot) == ERX_OK);
}

/* The image entry's slice, made at the entry's first map and the same for every later one. */
static int
task_image_slice(uint32_t entry, uint32_t *slice)
{
	uint32_t *row;
	int status;

	/* entry names an entry of the archive, so entry + 1 does not wrap. */
	if (erx_backend_grow_table_room(&task_image_slices, entry + 1) != ERX_OK)
		return (ERX_ENOMEM);
	row = erx_backend_grow_table_at(&task_image_slices, entry);
	if (*row == 0) {
		status = erx_fiasco_slice_image(entry, slice);
		if (status != ERX_OK)
			return (status);
		*row = *slice + 1;
	}
	*slice = *row - 1;
	return (ERX_OK);
}

/*
 * The archive index a map names. A slice the caller holds names its run of entries,
 * and entry counts from the run's first, ERX_ERANGE past its last; a handle that names
 * no slice is the lookup's refusal, ERX_ETYPE for another kind. The root alone may name
 * ERX_CAP_NULL, the whole archive, and then entry is the archive's own index: how the
 * domain library maps a runtime's image entry, which no slice may hold.
 */
static int
task_image_entry(uint32_t caller, uint64_t image, uint64_t entry, uint32_t *index)
{
	uint32_t object, first, count;
	int status;

	if (caller == ERX_FIASCO_TASK_ROOT && image == ERX_CAP_NULL) {
		if (entry > UINT32_MAX)
			return (ERX_EINVAL);
		*index = (uint32_t)entry;
		return (ERX_OK);
	}
	status = erx_fiasco_object_find(caller, image, ERX_BACKEND_OBJECT_MEMORY, &object);
	if (status == ERX_OK)
		status = erx_fiasco_vm_slice_entries(object, &first, &count);
	if (status != ERX_OK)
		return (status);
	if (entry >= count)
		return (ERX_ERANGE);
	/* The slice's run lies inside the archive, so first + entry does not wrap. */
	*index = first + (uint32_t)entry;
	return (ERX_OK);
}

/*
 * Loads an entry of the image into a space the caller created: any task's call, as a
 * session starts a program from its release's slice. An entry loads in either of its
 * two forms: an image entry (a domain's runtime) by the manifest the pack tool wrote,
 * through erx_image_plan, or a file entry holding an ELF executable (the test
 * launcher's and a session's programs) through erx_elf_plan. Only a program linked at
 * fixed addresses can load, as there is no relocation here. An image entry's
 * read-only and read-execute segments are its slice's pages, shared by every space
 * that runs it; its writable segments, and every segment of a file entry, whose
 * offsets are the ELF file's, are copied into the space.
 */
int
erx_fiasco_task_image_map_body(uint32_t caller, uint64_t space, uint64_t image, uint64_t entry, uint64_t *start)
{
	erx_pack_entry_t file;
	erx_elf_error_t error;
	const uint8_t *bytes;
	uint32_t task, index, slice = 0;
	bool planned;
	int status;

	status = erx_fiasco_task_space_target(caller, space, &task);
	if (status == ERX_OK)
		status = task_image_entry(caller, image, entry, &index);
	if (status != ERX_OK)
		return (status);
	if (task == caller || task_archive == NULL || !erx_pack_entry_at(task_archive, index, &file))
		return (ERX_EINVAL);
	bytes = task_archive->bytes + file.data_off;
	if (file.kind == ERX_ENTRY_IMAGE)
		planned = erx_image_plan(bytes, (size_t)file.data_size, &task_plan, &error);
	else
		planned = erx_elf_plan(bytes, (size_t)file.data_size, UINT64_MAX, &task_plan, &error);
	if (!planned || (task_plan.flags & ERX_IMAGE_FIXED) == 0)
		return (ERX_EINVAL);
	if (file.kind == ERX_ENTRY_IMAGE && task_image_slice(index, &slice) != ERX_OK)
		return (ERX_ENOMEM);
	for (uint32_t step = 0; step < task_plan.nloads; step++) {
		const erx_elf_load_t *const load = &task_plan.loads[step];
		bool loaded;

		if (file.kind == ERX_ENTRY_IMAGE && load->segment.prot != ERX_PROT_RW)
			loaded = task_segment_share(task, slice, load, task_plan.fixed_base);
		else
			loaded = task_segment_load(task, bytes, load, task_plan.fixed_base);
		if (!loaded)
			return (ERX_ENOMEM);
	}
	*start = task_plan.fixed_base + task_plan.entry;
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
 * The design's steps up to the status, in order. Deleting a thread leaves its slots
 * empty and its IPC gone, so a thread blocked on the gate is no request any more.
 * Deleting what a failed create never made is a no-op to the kernel. The row and the
 * ended semaphore are the caller's.
 */
static void
task_teardown(uint32_t task)
{
	const erx_fiasco_task_t *const row = erx_fiasco_task(task);

	for (uint32_t index = ERX_FIASCO_THREADS_MAX; index-- > 0;)
		if (row->threads[index] != ERX_FIASCO_TASK_THREAD_ABSENT)
			task_delete(erx_fiasco_task_thread_cap(task, index));
	for (uint32_t index = ERX_FIASCO_THREADS_MAX; index-- > 0;)
		if (row->threads[index] != ERX_FIASCO_TASK_THREAD_ABSENT)
			task_delete(erx_fiasco_task_semaphore_cap(task, index));
	task_delete(erx_fiasco_task_gate_cap(task));
	task_delete(erx_fiasco_task_cap(task));
	erx_fiasco_gate_task_gone(task);
	erx_fiasco_vm_task_close(task);
	erx_fiasco_object_task_close(task);
	/* A group goes with its home, whose threads are gone. */
	if (row->group != 0)
		erx_fiasco_object_end(row->group - 1);
}

/*
 * One live task's end, stopped by the task stopper: steps 1 to 3 of the design, then
 * the status. The row keeps its status and its place in the tree until its deletion;
 * the exit record goes to the space's fault gate once no thread of it can run, and the
 * ended semaphore's up lets the root's join go.
 */
static void
task_end(uint32_t task, uint32_t stopper, int64_t status)
{
	erx_fiasco_task_t *const row = erx_fiasco_task(task);
	erx_fiasco_task_tree_t tree;

	task_teardown(task);
	/* The teardown's object close only marks what it frees, so no space of the tree has gone. */
	tree = row->tree;
	*row = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_ENDED, .tree = tree, .status = status };
	erx_fiasco_gate_exit(task, stopper, status);
	erx_fiasco_trace_service(ERX_TRACE_EVENT_SPACE_END, (uint64_t)task + 1, (uint64_t)status, 0);
	(void)l4_semaphore_up(erx_fiasco_task_ended_cap(task));
}

/* The first live child on the task's list, or 0 when it has none. */
static uint32_t
task_live_child(uint32_t task)
{
	uint32_t child = erx_fiasco_task(task)->tree.child;

	while (child != 0 && erx_fiasco_task(child)->state != ERX_FIASCO_TASK_LIVE)
		child = erx_fiasco_task(child)->tree.sibling;
	return (child);
}

/*
 * A stop: the live task and every live space below it end, children first, each
 * child with ERX_EXIT_PARENT and the same stopper (docs/design-stopgap.md, "Task
 * exit"). The walk goes down to a live space with no live child, ends it, and goes
 * back up to its parent; an ended space is never live again and a stopped one takes no
 * child, so each step ends one space, the walk is iterative whatever the tree's depth,
 * and a child's exit record is posted before its parent's.
 *
 * No task_end deletes a space or ends a budget: its object close marks the records it
 * frees and those the task created, and the service ends them once the walk is over
 * (erx_fiasco_object_drain), so every row the walk reads stands until it returns.
 */
static void
task_stop_tree(uint32_t task, uint32_t stopper, int64_t status)
{
	uint32_t at = task;

	for (;;) {
		const uint32_t child = task_live_child(at);

		if (child != 0) {
			at = child;
			continue;
		}
		task_end(at, stopper, at == task ? status : ERX_EXIT_PARENT);
		if (at == task)
			return;
		at = erx_fiasco_task(at)->tree.parent;
	}
}

/*
 * One stopped task's deletion, once it has no child: its unread records withdrawn,
 * its ended semaphore and its row gone, off its parent's list, and its space record
 * ended, so every handle to it answers ERX_ESTALE.
 */
static void
task_remove(uint32_t task)
{
	erx_fiasco_task_t *const row = erx_fiasco_task(task);
	const uint32_t record = row->tree.space;
	uint32_t *link = &erx_fiasco_task(row->tree.parent)->tree.child;

	while (*link != task)
		link = &erx_fiasco_task(*link)->tree.sibling;
	*link = row->tree.sibling;
	erx_fiasco_gate_space_close(task);
	task_delete(erx_fiasco_task_ended_cap(task));
	*row = (erx_fiasco_task_t){ .state = ERX_FIASCO_TASK_ABSENT };
	if (record != 0) {
		/* Cleared first, so the record's end finds no space left to release. */
		*task_space_of(record - 1) = 0;
		erx_fiasco_object_end(record - 1);
	}
}

/*
 * A stopped task's deletion with every space below it, which a stop has ended too:
 * children first, by the same walk as a stop's, each removal taking one off the tree.
 */
static void
task_delete_tree(uint32_t task)
{
	uint32_t at = task;

	for (;;) {
		const uint32_t child = erx_fiasco_task(at)->tree.child;
		const uint32_t parent = erx_fiasco_task(at)->tree.parent;

		if (child != 0) {
			at = child;
			continue;
		}
		task_remove(at);
		if (at == task)
			return;
		at = parent;
	}
}

void
erx_fiasco_task_space_release(uint32_t record)
{
	uint32_t *const space = task_space_of(record);
	uint32_t task;

	if (*space == 0)
		return;
	task = *space - 1;
	*space = 0;
	erx_fiasco_task(task)->tree.space = 0;
	/* The exit record this posts is withdrawn at once by the deletion: nothing reads a released space's end. */
	if (erx_fiasco_task(task)->state == ERX_FIASCO_TASK_LIVE)
		task_stop_tree(task, task, ERX_EXIT_RELEASED);
	task_delete_tree(task);
}

/*
 * A task stops itself or a space it created; the root's own stop is the machine's end.
 * A stopped space stays stopped with its first status. The kernel's own statuses are
 * refused, so a record that carries one was written by the backend.
 */
int
erx_fiasco_task_stop_body(uint32_t caller, uint64_t space, int64_t status)
{
	uint32_t task;
	const int named = task_space_named(caller, space, &task);

	if (named != ERX_OK)
		return (named);
	if (status == ERX_EXIT_PARENT || status == ERX_EXIT_RELEASED || status == ERX_EXIT_NOTHREAD)
		return (ERX_EINVAL);
	if (task == ERX_FIASCO_TASK_ROOT)
		erx_fiasco_end(NULL, ERX_END_OFF);
	if (erx_fiasco_task(task)->state == ERX_FIASCO_TASK_LIVE)
		task_stop_tree(task, caller, status);
	return (task == caller ? ERX_FIASCO_NO_REPLY : ERX_OK);
}

int
erx_fiasco_task_join_body(uint32_t caller, uint64_t space, int64_t *status, uint64_t *task)
{
	uint32_t named;
	int result;

	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	result = task_space_named(caller, space, &named);
	if (result != ERX_OK)
		return (result);
	if (named == caller)
		return (ERX_EINVAL);
	if (erx_fiasco_task(named)->state == ERX_FIASCO_TASK_LIVE) {
		*task = named;
		return (ERX_EBUSY);
	}
	*status = erx_fiasco_task(named)->status;
	task_delete_tree(named);
	/* The deletion left the entry stale; the close frees it. */
	return (erx_fiasco_cap_close_body(caller, space));
}

int
erx_fiasco_task_mem_create_body(uint32_t caller, const erx_fiasco_mem_create_request_t *request, uint64_t *mem)
{
	if ((request->flags & ~(uint64_t)ERX_MEM_JIT) != 0 || request->size == 0 ||
	    (request->size & ERX_BACKEND_VM_PAGE_MASK) != 0)
		return (ERX_EINVAL);
	if ((request->flags & ERX_MEM_JIT) != 0 && (erx_fiasco_task(caller)->flags & ERX_SPACE_JIT) == 0)
		return (ERX_ERIGHTS);
	return (erx_fiasco_object_create(caller, ERX_BACKEND_OBJECT_MEMORY, request->budget, task_fill_pages, request, mem));
}

static int
task_fill_pages(uint32_t object, const void *request)
{
	return (erx_fiasco_vm_object_create(object, ((const erx_fiasco_mem_create_request_t *)request)->size));
}

static int
task_fill_physical(uint32_t object, const void *request)
{
	const erx_fiasco_mem_physical_request_t *const physical = request;

	return (erx_fiasco_vm_physical_create(object, physical->base, physical->size));
}

static int
task_fill_contiguous(uint32_t object, const void *request)
{
	const erx_fiasco_mem_contiguous_request_t *const contiguous = request;

	return (erx_fiasco_vm_contiguous_create(object, contiguous->size, contiguous->cpu, contiguous->bus,
	    contiguous->last));
}

/*
 * Written by the root's entry on the root thread before its program runs, and read on the
 * service thread, so atomic. It publishes only itself.
 */
static _Atomic uint64_t task_console_page;

void
erx_fiasco_task_console_set(uint64_t page)
{
	atomic_store_explicit(&task_console_page, page, memory_order_relaxed);
}

/*
 * Device memory, a physical object or a contiguous run, comes from the root only
 * (docs/design-stopgap.md, "The call table"): the root's own drivers make theirs, and the
 * domain library makes every other holder's and passes it, so a create from any other
 * task is ERX_ENOTSUP before its request is read. This body and the contiguous one below
 * are the only callers of task_fill_physical and task_fill_contiguous, and the service's
 * dispatch the only caller of the bodies, so the check in each covers every create.
 *
 * The handoff (docs/design-stopgap.md, "The console"): the console's driver maps the page that
 * holds its registers (erx_boot_console_page), and its first touch of a register
 * needs this reply, so it follows the last log record the service wrote to the UART, and a
 * failed map changes nothing.
 */
int
erx_fiasco_task_mem_physical_body(uint32_t caller, const erx_fiasco_mem_physical_request_t *request, uint64_t *mem)
{
	uint64_t console_page;
	int status;

	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	status = request->attr > UINT32_MAX ? ERX_EINVAL :
	    erx_backend_physical_check(request->base, request->size, (uint32_t)request->attr);
	if (status != ERX_OK)
		return (status);
	status = erx_fiasco_object_create(caller, ERX_BACKEND_OBJECT_MEMORY, request->budget, task_fill_physical, request, mem);
	console_page = atomic_load_explicit(&task_console_page, memory_order_relaxed);
	if (status == ERX_OK && console_page != 0 && request->base == console_page)
		erx_debug_log_hand_to_console();
	return (status);
}

int
erx_fiasco_task_mem_contiguous_body(uint32_t caller, const erx_fiasco_mem_contiguous_request_t *request, uint64_t *mem)
{
	int status;

	if (caller != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	status = erx_backend_contiguous_check(request->size);
	if (status == ERX_OK)
		status = erx_backend_dma_range_check(request->cpu, request->bus, request->last);
	if (status != ERX_OK)
		return (status);
	return (erx_fiasco_object_create(caller, ERX_BACKEND_OBJECT_MEMORY, request->budget, task_fill_contiguous, request,
	    mem));
}

/* An object the caller holds, into its own space or one it created. */
int
erx_fiasco_task_vm_map_body(uint32_t caller, const erx_fiasco_vm_map_request_t *request)
{
	uint32_t object, target;
	int status;

	if (request->prot > UINT32_MAX)
		return (ERX_EINVAL);
	status = erx_fiasco_task_space_target(caller, request->space, &target);
	if (status == ERX_OK)
		status = erx_fiasco_object_find(caller, request->mem, ERX_BACKEND_OBJECT_MEMORY, &object);
	if (status == ERX_OK)
		status = erx_fiasco_vm_object_map(target, object, request->addr, request->size, request->offset,
		    (uint32_t)request->prot);
	return (status);
}

int
erx_fiasco_task_mem_dma_body(uint32_t caller, uint64_t mem, uint64_t offset, uint64_t *addr)
{
	uint32_t object;
	const int status = erx_fiasco_object_find(caller, mem, ERX_BACKEND_OBJECT_MEMORY, &object);

	return (status != ERX_OK ? status : erx_fiasco_vm_object_dma_addr(object, offset, addr));
}

void
erx_fiasco_task_fault(uint32_t task, const erx_crash_fault_t *fault)
{
	if (erx_fiasco_gate_fault(task, fault))
		return;
	erx_fiasco_task_crash_write(fault);
	task_stop_tree(task, task, ERX_FIASCO_TASK_STATUS_FAULT);
}

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdbool.h>

static bool	task_caps_gone(uint32_t);

/*
 * Whether every capability the root held for each task index not in use reads as gone.
 * Call it only while no request runs: it reads the service's rows.
 */
bool
erx_fiasco_test_task_caps_gone(void)
{
	for (uint32_t task = 1; task < erx_backend_grow_table_capacity(&task_rows); task++)
		if (erx_fiasco_task(task)->state == ERX_FIASCO_TASK_ABSENT && !task_caps_gone(task))
			return (false);
	return (true);
}

static bool
task_caps_gone(uint32_t task)
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
