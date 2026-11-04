/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects under vm_table.c and page_pool.c: taking sigma0's memory, and the
 * root mapping window pages into a task at the addresses its range table names.
 * Every decision is in those cores.
 *
 * The window maps all RAM, read, write and execute, as sigma0 gives it, and is
 * never unmapped: it is where a page lives, and a task's mapping of the page is
 * the window's child, so unmapping that child leaves the page and its contents
 * alone. The root is always the sender, and for its own memory the receiver too.
 *
 * Every table shares one page index, keyed by address and label: a task's label
 * is its index, and an object's label lies above every task's. A shared object is a
 * table of its own over offsets, so it owns its pages as a task does, comes from
 * the pool and goes back with no second way to hold a page.
 */

#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/err.h>
#include <l4/sys/task.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/fiasco/vm_table.h"

/* The backend's address layout: above all RAM, and below 2^39, Fiasco's user limit here. */
#define VM_WINDOW_BASE	UINT64_C(0x1000000000)
#define VM_AREA_START	ERX_FIASCO_AREA_START
#define VM_AREA_END	UINT64_C(0x8000000000)
/* The window's two grains: sigma0 gives 2 MiB until refused, then 4 KiB until refused. */
#define VM_SUPERPAGE_ORDER	21u
/* How many separate reserved runs a task may hold; more is ERX_ENOMEM. */
#define VM_RANGES_MAX	4096u
/* How many shared objects a task may create; more is ERX_ENOMEM. */
#define VM_OBJECTS_MAX	16u
/* An object's offsets, as addresses of its own table: page zero stays an empty key. */
#define VM_OBJECT_AREA_START	((uint64_t)ERX_PAGE_SIZE)
#define VM_OBJECT_AREA_END	(VM_AREA_END - VM_AREA_START)
#define VM_OBJECT_LABEL(task, handle)	(ERX_FIASCO_TASKS_MAX + (task) * VM_OBJECTS_MAX + (handle))

_Static_assert(VM_OBJECT_LABEL(ERX_FIASCO_TASKS_MAX, 0) <= ERX_PAGE_SIZE, "every label fits a page address's low bits");

_Static_assert(VM_WINDOW_BASE % (UINT64_C(1) << VM_SUPERPAGE_ORDER) == 0,
    "the window starts on a superpage");

typedef struct vm_object {
	bool			used;
	erx_fiasco_vm_table_t	table;
	erx_fiasco_vm_range_t	ranges[2];
} vm_object_t;

typedef struct vm_task {
	erx_fiasco_vm_table_t	table;
	erx_fiasco_vm_range_t	ranges[VM_RANGES_MAX];
	vm_object_t		objects[VM_OBJECTS_MAX];
} vm_task_t;

static unsigned	fpage_rights(uint32_t);
static void	vm_map(uint32_t, uintptr_t, uint64_t, uint32_t);
static void	vm_unmap(uint32_t, uint64_t, uint32_t);
static void	vm_no_map(uint32_t, uintptr_t, uint64_t, uint32_t);
static void	vm_no_unmap(uint32_t, uint64_t, uint32_t);
static uint64_t	window_grow(uint64_t, unsigned);
static _Noreturn void vm_refused(const char *);

static const erx_fiasco_vm_effects_t vm_effects = { .map = vm_map, .unmap = vm_unmap };
/* For a table no space sees: an object's, or a task's whose mappings went with it. */
static const erx_fiasco_vm_effects_t vm_no_effects = { .map = vm_no_map, .unmap = vm_no_unmap };
static vm_task_t vm_tasks[ERX_FIASCO_TASKS_MAX];
static erx_fiasco_vm_page_t *vm_index;
static size_t vm_index_slots;
static erx_fiasco_pool_t vm_pool;

const char *
erx_fiasco_vm_init(void)
{
	uint64_t cursor = VM_WINDOW_BASE;
	uint64_t window_pages;
	erx_fiasco_vm_layout_t layout;

	cursor = window_grow(cursor, VM_SUPERPAGE_ORDER);
	cursor = window_grow(cursor, L4_PAGESHIFT);
	window_pages = (cursor - VM_WINDOW_BASE) >> L4_PAGESHIFT;
	layout = erx_fiasco_vm_layout(window_pages);
	if (layout.index_pages >= window_pages)
		return ("memory: sigma0 gave too little to hold the page index");

	vm_index = (erx_fiasco_vm_page_t *)(uintptr_t)VM_WINDOW_BASE;
	vm_index_slots = (size_t)layout.index_slots;
	erx_fiasco_vm_index_init(vm_index, vm_index_slots);
	erx_fiasco_vm_task_open(0);
	for (uint64_t page = layout.index_pages; page < window_pages; page++)
		erx_fiasco_pool_put(&vm_pool, (uintptr_t)(VM_WINDOW_BASE + (page << L4_PAGESHIFT)));
	return (NULL);
}

uint64_t
erx_fiasco_vm_free_pages(void)
{
	return (vm_pool.free_pages);
}

void
erx_fiasco_vm_task_open(uint32_t task)
{
	erx_fiasco_vm_table_init(&vm_tasks[task].table, task, vm_tasks[task].ranges, VM_RANGES_MAX, vm_index,
	    vm_index_slots, VM_AREA_START, VM_AREA_END);
}

void
erx_fiasco_vm_task_close(uint32_t task)
{
	vm_task_t *const row = &vm_tasks[task];

	erx_fiasco_vm_table_clear(&row->table, &vm_pool, &vm_no_effects);
	for (uint32_t handle = 0; handle < VM_OBJECTS_MAX; handle++) {
		if (row->objects[handle].used)
			erx_fiasco_vm_table_clear(&row->objects[handle].table, &vm_pool, &vm_no_effects);
		row->objects[handle].used = false;
	}
}

uintptr_t
erx_fiasco_vm_task_window(uint32_t task, uint64_t addr)
{
	return (erx_fiasco_vm_window(&vm_tasks[task].table, addr));
}

int
erx_fiasco_vm_object_create(uint32_t task, uint64_t size, uint64_t *handle)
{
	vm_task_t *const row = &vm_tasks[task];

	for (uint32_t free = 0; free < VM_OBJECTS_MAX; free++) {
		vm_object_t *const object = &row->objects[free];
		const erx_fiasco_vm_request_t reserve = { .op = ERX_FIASCO_VM_RESERVE, .addr = VM_OBJECT_AREA_START,
		    .size = size, .flags = ERX_VM_FIXED };
		const erx_fiasco_vm_request_t commit = { .op = ERX_FIASCO_VM_COMMIT, .addr = VM_OBJECT_AREA_START, .size = size };
		int status;

		if (object->used)
			continue;
		erx_fiasco_vm_table_init(&object->table, VM_OBJECT_LABEL(task, free), object->ranges, 2, vm_index,
		    vm_index_slots, VM_OBJECT_AREA_START, VM_OBJECT_AREA_END);
		status = erx_fiasco_vm_call(&object->table, &vm_pool, &vm_no_effects, &reserve, NULL);
		if (status != ERX_OK)
			return (status == ERX_ERANGE ? ERX_ENOMEM : status);
		status = erx_fiasco_vm_call(&object->table, &vm_pool, &vm_no_effects, &commit, NULL);
		if (status != ERX_OK) {
			erx_fiasco_vm_table_clear(&object->table, &vm_pool, &vm_no_effects);
			return (status);
		}
		object->used = true;
		*handle = free;
		return (ERX_OK);
	}
	return (ERX_ENOMEM);
}

int
erx_fiasco_vm_object_map(uint32_t task, uint64_t handle, uint64_t addr, uint64_t size, uint64_t offset, uint32_t prot)
{
	vm_task_t *const row = &vm_tasks[task];

	if (handle >= VM_OBJECTS_MAX || !row->objects[handle].used)
		return (ERX_EINVAL);
	return (erx_fiasco_vm_map_object(&row->table, &row->objects[handle].table, &vm_effects, addr, size, offset, prot));
}

int
erx_fiasco_vm_body(uint32_t task, erx_fiasco_vm_op_t op, uint64_t addr, uint64_t size, uint32_t word, uint64_t *reserved)
{
	const erx_fiasco_vm_request_t request = { .op = op, .addr = addr, .size = size,
	    .flags = op == ERX_FIASCO_VM_RESERVE ? word : 0,
	    .prot = op == ERX_FIASCO_VM_PROTECT ? word : ERX_PROT_NONE };

	return (erx_fiasco_vm_call(&vm_tasks[task].table, &vm_pool, &vm_effects, &request, reserved));
}

/*
 * Extends the window in pages of one order until sigma0 refuses or the window
 * meets the area; returns its new end.
 */
static uint64_t
window_grow(uint64_t cursor, unsigned order)
{
	l4_addr_t physical;

	while (cursor < VM_AREA_START &&
	    l4sigma0_map_anypage(L4_BASE_PAGER_CAP, (l4_addr_t)cursor, order, &physical, order) == 0)
		cursor += UINT64_C(1) << order;
	return (cursor);
}

static void
vm_no_map(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot)
{
	(void)label;
	(void)window;
	(void)addr;
	(void)prot;
}

static void
vm_no_unmap(uint32_t label, uint64_t addr, uint32_t rights)
{
	(void)label;
	(void)addr;
	(void)rights;
}

static void
vm_map(uint32_t task, uintptr_t window, uint64_t addr, uint32_t prot)
{
	const l4_msgtag_t tag = l4_task_map(erx_fiasco_task_cap(task), L4_BASE_TASK_CAP,
	    l4_fpage(window, L4_PAGESHIFT, fpage_rights(prot)), l4_map_control(addr, 0, 0));

	if (l4_error(tag) < 0)
		vm_refused("erx: memory: the kernel refused a map\n");
}

static void
vm_unmap(uint32_t task, uint64_t addr, uint32_t rights)
{
	const l4_msgtag_t tag = l4_task_unmap(erx_fiasco_task_cap(task),
	    l4_fpage(addr, L4_PAGESHIFT, fpage_rights(rights)), L4_FP_ALL_SPACES);

	if (l4_error(tag) < 0)
		vm_refused("erx: memory: the kernel refused an unmap\n");
}

/* The kernel spells rights differently from ERX_PROT_*: read 4, write 2, execute 1. */
static unsigned
fpage_rights(uint32_t rights)
{
	return (((rights & ERX_PROT_R) != 0 ? L4_FPAGE_RO : 0u) |
	    ((rights & (ERX_PROT_RW & ~ERX_PROT_R)) != 0 ? L4_FPAGE_W : 0u) |
	    ((rights & (ERX_PROT_RX & ~ERX_PROT_R)) != 0 ? L4_FPAGE_X : 0u));
}

static _Noreturn void
vm_refused(const char *line)
{
	size_t length = 0;

	while (line[length] != '\0')
		length++;
	erx_fiasco_console_write(line, length);
	erx_fiasco_machine_off();
}
