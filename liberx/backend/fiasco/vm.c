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
 * Every table shares one page index, keyed by address and label. A label names one
 * table, a task's or an object's, and is below ERX_PAGE_SIZE, so live tasks and
 * objects together hold at most that many; the label map says which task's space a
 * task table's label is. A shared object is a table of its own over offsets, so it
 * owns its pages as a task does, comes from the pool and goes back with no second way
 * to hold a page. An object's table is kept by its object record's index (object.c),
 * which alone says whether the object lives.
 *
 * A mapping is a record in the task's table (vm_table.c) naming the object's record
 * index; object.c counts them, so an object without a handle lives while one remains.
 *
 * A physical or contiguous object is the same table over pages that lie outside
 * the pool: a device's registers in the device window, or a run of the contiguous
 * pool. vm_give tells them apart by address and keeps them, so no way of ending an
 * object can put them on the free list.
 */

#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/err.h>
#include <l4/sys/task.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/core/mem.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/core/vm_table.h"

/* The backend's address layout: above all RAM, and below 2^39, Fiasco's user limit here. */
#define VM_WINDOW_BASE	UINT64_C(0x1000000000)
#define VM_AREA_END	UINT64_C(0x8000000000)
/*
 * Below the window and above all RAM: the device window, where each physical
 * object's registers stay mapped in the root, and the contiguous pool's superpage.
 */
#define VM_DEVICE_BASE	UINT64_C(0xE00000000)
#define VM_DEVICE_PAGES	4096u
#define VM_CONTIG_BASE	(VM_WINDOW_BASE - (UINT64_C(1) << VM_SUPERPAGE_ORDER))
/* The window's two grains: sigma0 gives 2 MiB until refused, then 4 KiB until refused. */
#define VM_SUPERPAGE_ORDER	21u
/* An object's offsets, as addresses of its own table: page zero stays an empty key. */
#define VM_OBJECT_AREA_START	((uint64_t)ERX_PAGE_SIZE)
#define VM_OBJECT_AREA_END	(VM_AREA_END - ERX_FIASCO_AREA_START)
/* The page index's labels, which a page address's low bits hold. */
#define VM_LABELS	((uint32_t)ERX_PAGE_SIZE)
/* What the label map holds for a free label, and for an object's; a task's is its index plus one. */
#define VM_LABEL_FREE	0u
#define VM_LABEL_OBJECT	UINT32_MAX

_Static_assert(VM_WINDOW_BASE % (UINT64_C(1) << VM_SUPERPAGE_ORDER) == 0,
    "the window starts on a superpage");

typedef enum vm_object_kind {
	VM_OBJECT_PAGES,
	VM_OBJECT_PHYSICAL,
	VM_OBJECT_CONTIGUOUS
} vm_object_kind_t;

typedef struct vm_object {
	vm_object_kind_t	kind;
	uint64_t		device_base;	/* VM_OBJECT_CONTIGUOUS: offset 0's device address */
	uint64_t		size;
	erx_backend_vm_table_t	table;
} vm_object_t;

typedef struct vm_task {
	erx_backend_vm_table_t	table;
} vm_task_t;

_Static_assert(sizeof(vm_task_t) <= ERX_PAGE_SIZE, "a task's record fits a page of its table");
_Static_assert(sizeof(vm_object_t) <= ERX_PAGE_SIZE, "an object's record fits a page of its table");

static unsigned	fpage_rights(uint32_t);
static void	vm_map(uint32_t, uintptr_t, uint64_t, uint32_t);
static void	vm_unmap(uint32_t, uint64_t, uint32_t);
static void	vm_no_map(uint32_t, uintptr_t, uint64_t, uint32_t);
static void	vm_no_unmap(uint32_t, uint64_t, uint32_t);
static uintptr_t vm_take(uint64_t);
static void	vm_give(uintptr_t, uint64_t);
static void	vm_unmapped(uint32_t);
static uintptr_t vm_run_take(uint64_t);
static uint64_t	vm_run_free_pages(void);
static uint64_t	window_grow(uint64_t, unsigned);
static uintptr_t vm_record_take(void);
static void	vm_record_give(uintptr_t);
static uint32_t	vm_label_take(uint32_t);
static void	vm_label_put(uint32_t);
static vm_task_t *vm_task(uint32_t);
static vm_object_t *vm_object(uint32_t);
static uint32_t	vm_label_task(uint32_t);
static _Noreturn void vm_refused(const char *);

const erx_backend_grow_pages_t erx_fiasco_vm_records = { .take = vm_record_take, .give = vm_record_give };

static const erx_backend_vm_effects_t vm_effects = { .map = vm_map, .unmap = vm_unmap, .take = vm_take,
    .give = vm_give, .free_pages = erx_fiasco_vm_free_pages, .unmapped = vm_unmapped };
/* For a table no space sees: an object's, or a task's whose mappings went with it. */
static const erx_backend_vm_effects_t vm_no_effects = { .map = vm_no_map, .unmap = vm_no_unmap, .take = vm_take,
    .give = vm_give, .free_pages = erx_fiasco_vm_free_pages, .unmapped = vm_unmapped };
/* For an object over a run: its pages are the run's, in order, from vm_run_window. */
static const erx_backend_vm_effects_t vm_run_effects = { .map = vm_no_map, .unmap = vm_no_unmap, .take = vm_run_take,
    .give = vm_give, .free_pages = vm_run_free_pages, .unmapped = vm_unmapped };
static uintptr_t vm_run_window;
static erx_fiasco_contig_t vm_contig;
static uint64_t vm_contig_physical;
static uint32_t vm_device_pages_used;
/* Each task's record, by its index. */
static erx_backend_grow_table_t vm_tasks;
/* Each memory object's pages, by its object record's index. */
static erx_backend_grow_table_t vm_objects;
/* By label: VM_LABEL_FREE, VM_LABEL_OBJECT, or the task index plus one of the task whose range table it is. */
static uint32_t vm_label_map[VM_LABELS];
static erx_backend_vm_page_t *vm_index;
static size_t vm_index_slots;
static erx_fiasco_pool_t vm_pool;

static uintptr_t
vm_take(uint64_t addr)
{
	(void)addr;
	return (erx_fiasco_pool_take(&vm_pool));
}

static void
vm_give(uintptr_t window, uint64_t addr)
{
	(void)addr;
	/* Below the window: a run of an object, which never joins the pool. */
	if (window >= VM_WINDOW_BASE)
		erx_fiasco_pool_put(&vm_pool, window);
}

/* A mapping's record went by a release or its task's end: the object counts one fewer. */
static void
vm_unmapped(uint32_t object)
{
	erx_fiasco_object_unmapped(object);
}

static uintptr_t
vm_record_take(void)
{
	return (erx_fiasco_pool_take(&vm_pool));
}

static void
vm_record_give(uintptr_t page)
{
	erx_fiasco_pool_put(&vm_pool, page);
}

/* The lowest free label, now owner's, or VM_LABELS when every one is held. */
static uint32_t
vm_label_take(uint32_t owner)
{
	for (uint32_t label = 0; label < VM_LABELS; label++)
		if (vm_label_map[label] == VM_LABEL_FREE) {
			vm_label_map[label] = owner;
			return (label);
		}
	return (VM_LABELS);
}

static void
vm_label_put(uint32_t label)
{
	vm_label_map[label] = VM_LABEL_FREE;
}

/* The task whose range table holds this label: only a task's table maps, so its label's owner is a task. */
static uint32_t
vm_label_task(uint32_t label)
{
	return (vm_label_map[label] - 1);
}

/* An open task's record. */
static vm_task_t *
vm_task(uint32_t task)
{
	return (erx_backend_grow_table_at(&vm_tasks, task));
}

/* A live memory object's record. */
static vm_object_t *
vm_object(uint32_t object)
{
	return (erx_backend_grow_table_at(&vm_objects, object));
}

const char *
erx_fiasco_vm_init(void)
{
	uint64_t cursor = VM_WINDOW_BASE;
	uint64_t window_pages;
	erx_backend_vm_layout_t layout;
	l4_addr_t contig_physical;

	if (l4sigma0_map_anypage(L4_BASE_PAGER_CAP, (l4_addr_t)VM_CONTIG_BASE, VM_SUPERPAGE_ORDER, &contig_physical,
	    VM_SUPERPAGE_ORDER) != 0)
		return ("memory: sigma0 gave no superpage for the contiguous pool");
	vm_contig_physical = contig_physical;
	cursor = window_grow(cursor, VM_SUPERPAGE_ORDER);
	cursor = window_grow(cursor, L4_PAGESHIFT);
	window_pages = (cursor - VM_WINDOW_BASE) >> L4_PAGESHIFT;
	/* The index also holds the runs' pages: each is one distinct page, as a window page is. */
	layout = erx_backend_vm_layout(window_pages + ERX_FIASCO_CONTIG_PAGES + VM_DEVICE_PAGES);
	if (layout.index_pages >= window_pages)
		return ("memory: sigma0 gave too little to hold the page index");

	vm_index = (erx_backend_vm_page_t *)(uintptr_t)VM_WINDOW_BASE;
	vm_index_slots = (size_t)layout.index_slots;
	erx_backend_vm_index_init(vm_index, vm_index_slots);
	for (uint64_t page = layout.index_pages; page < window_pages; page++)
		erx_fiasco_pool_add(&vm_pool, (uintptr_t)(VM_WINDOW_BASE + (page << L4_PAGESHIFT)));
	erx_backend_grow_table_init(&vm_tasks, sizeof(vm_task_t), &erx_fiasco_vm_records);
	erx_backend_grow_table_init(&vm_objects, sizeof(vm_object_t), &erx_fiasco_vm_records);
	/* The first page now, as object.c takes its records', so a first object's page count is its own pages. */
	if (erx_backend_grow_table_room(&vm_objects, 1) != ERX_OK)
		return ("memory: the pool cannot hold the object table");
	if (erx_fiasco_vm_task_open(0) != ERX_OK)
		return ("memory: the pool cannot hold the root's range table");
	return (NULL);
}

uint64_t
erx_fiasco_vm_free_pages(void)
{
	return (vm_pool.free_pages);
}

uint64_t
erx_fiasco_vm_used_pages(void)
{
	return (vm_pool.held_pages);
}

uint64_t
erx_fiasco_vm_pool_pages(void)
{
	return (vm_pool.pages);
}

int
erx_fiasco_vm_task_open(uint32_t task)
{
	uint32_t label;

	/* A label map entry holds the task plus one, so the last two indices have none. */
	if (task >= VM_LABEL_OBJECT - 1)
		return (ERX_ENOMEM);
	if (erx_backend_grow_table_room(&vm_tasks, task + 1) != ERX_OK)
		return (ERX_ENOMEM);
	label = vm_label_take(task + 1);
	if (label == VM_LABELS)
		return (ERX_ENOMEM);
	*vm_task(task) = (vm_task_t){ 0 };
	erx_backend_vm_table_init(&vm_task(task)->table, label, vm_index, vm_index_slots, ERX_FIASCO_AREA_START, VM_AREA_END,
	    &erx_fiasco_vm_records);
	return (ERX_OK);
}

void
erx_fiasco_vm_task_close(uint32_t task)
{
	vm_task_t *const row = vm_task(task);

	erx_backend_vm_table_clear(&row->table, &vm_no_effects);
	vm_label_put(row->table.label);
}

void
erx_fiasco_vm_object_free(uint32_t object)
{
	erx_backend_vm_table_clear(&vm_object(object)->table, &vm_no_effects);
	vm_label_put(vm_object(object)->table.label);
}

uintptr_t
erx_fiasco_vm_task_window(uint32_t task, uint64_t addr)
{
	return (erx_backend_vm_window(&vm_task(task)->table, addr));
}

/*
 * Fills a new object's table with size bytes through these effects. An object over a
 * run names the run's first page, which vm_run_take reads; a pool object names 0. A
 * refused fill holds no label or page.
 */
static int
object_fill(uint32_t index, uint64_t size, const erx_backend_vm_effects_t *effects, vm_object_kind_t kind,
    uintptr_t run)
{
	const erx_backend_vm_request_t reserve = { .op = ERX_BACKEND_VM_RESERVE, .addr = VM_OBJECT_AREA_START,
	    .size = size, .flags = ERX_VM_FIXED };
	const erx_backend_vm_request_t commit = { .op = ERX_BACKEND_VM_COMMIT, .addr = VM_OBJECT_AREA_START, .size = size };
	vm_object_t *object;
	uint32_t label;
	int status;

	if (erx_backend_grow_table_room(&vm_objects, index + 1) != ERX_OK)
		return (ERX_ENOMEM);
	object = vm_object(index);
	label = vm_label_take(VM_LABEL_OBJECT);
	if (label == VM_LABELS)
		return (ERX_ENOMEM);
	vm_run_window = run;
	erx_backend_vm_table_init(&object->table, label, vm_index, vm_index_slots, VM_OBJECT_AREA_START, VM_OBJECT_AREA_END,
	    &erx_fiasco_vm_records);
	status = erx_backend_vm_call(&object->table, effects, &reserve, NULL);
	if (status == ERX_OK)
		status = erx_backend_vm_call(&object->table, effects, &commit, NULL);
	if (status != ERX_OK) {
		erx_backend_vm_table_clear(&object->table, &vm_no_effects);
		vm_label_put(label);
		return (status == ERX_ERANGE ? ERX_ENOMEM : status);
	}
	object->kind = kind;
	object->size = size;
	return (ERX_OK);
}

int
erx_fiasco_vm_object_create(uint32_t object, uint64_t size)
{
	return (object_fill(object, size, &vm_no_effects, VM_OBJECT_PAGES, 0));
}

int
erx_fiasco_vm_physical_create(uint32_t object, uint64_t base, uint64_t size)
{
	const uint64_t pages = size >> L4_PAGESHIFT;
	const uintptr_t window = (uintptr_t)(VM_DEVICE_BASE + ((uint64_t)vm_device_pages_used << L4_PAGESHIFT));
	int status;

	if (pages > VM_DEVICE_PAGES - vm_device_pages_used)
		return (ERX_ENOMEM);
	status = l4sigma0_map_iomem(L4_BASE_PAGER_CAP, (l4_addr_t)base, (l4_addr_t)window, (l4_addr_t)size, 0);
	/* sigma0's library leaves a receive window armed, and no request may map anything here. */
	l4_utcb_br()->br[0] = 0;
	if (status != 0)
		return (ERX_ERANGE);
	status = object_fill(object, size, &vm_run_effects, VM_OBJECT_PHYSICAL, window);
	if (status != ERX_OK)
		return (status);
	vm_device_pages_used += (uint32_t)pages;
	return (ERX_OK);
}

int
erx_fiasco_vm_contiguous_create(uint32_t object, uint64_t size, uint64_t limit)
{
	const uint64_t reach = limit == 0 ? UINT64_MAX : limit <= vm_contig_physical ? 0 : limit - vm_contig_physical;
	const uint64_t reach_pages = reach >> L4_PAGESHIFT;
	uint32_t first;
	uintptr_t window;
	int status;

	first = erx_fiasco_contig_take(&vm_contig, (uint32_t)(size >> L4_PAGESHIFT),
	    reach_pages < ERX_FIASCO_CONTIG_PAGES ? (uint32_t)reach_pages : ERX_FIASCO_CONTIG_PAGES);
	if (first == ERX_FIASCO_CONTIG_NONE)
		return (ERX_ENOMEM);
	window = (uintptr_t)(VM_CONTIG_BASE + ((uint64_t)first << L4_PAGESHIFT));
	bzero((void *)window, (size_t)size);
	status = object_fill(object, size, &vm_run_effects, VM_OBJECT_CONTIGUOUS, window);
	if (status != ERX_OK)
		return (status);
	vm_object(object)->device_base = vm_contig_physical + ((uint64_t)first << L4_PAGESHIFT);
	return (ERX_OK);
}

int
erx_fiasco_vm_object_dma_addr(uint32_t index, uint64_t offset, uint64_t *addr)
{
	const vm_object_t *const object = vm_object(index);

	if (object->kind != VM_OBJECT_CONTIGUOUS)
		return (ERX_ETYPE);
	if (offset >= object->size)
		return (ERX_ERANGE);
	*addr = object->device_base + offset;
	return (ERX_OK);
}

int
erx_fiasco_vm_object_map(uint32_t task, uint32_t index, uint64_t addr, uint64_t size, uint64_t offset, uint32_t prot)
{
	const vm_object_t *const object = vm_object(index);

	/* A device's memory is never code: registers fault, and a device could write a run. */
	if (object->kind != VM_OBJECT_PAGES && prot == ERX_PROT_RX)
		return (ERX_ERIGHTS);
	const int status = erx_backend_vm_map_object(&vm_task(task)->table, &object->table, index, &vm_effects, addr, size,
	    offset, prot);

	/* Each record counts once, here, and goes once, by vm_unmapped or a revoke: the count is the records' number. */
	if (status == ERX_OK)
		erx_fiasco_object_mapped(index);
	return (status);
}

/*
 * Every mapping of the object goes at once: unmapping each of its window pages from
 * the other spaces removes every mapping derived from it, in every task and the
 * root's own aliases too, and keeps the window's. Then each task's table drops its
 * records of it. A row of a task that never opened, or has closed, holds none.
 */
void
erx_fiasco_vm_object_revoke(uint32_t index)
{
	const vm_object_t *const object = vm_object(index);

	for (uint64_t offset = 0; offset < object->size; offset += ERX_PAGE_SIZE) {
		const uintptr_t window = erx_backend_vm_window(&object->table, VM_OBJECT_AREA_START + offset);
		const l4_msgtag_t tag = l4_task_unmap(L4_BASE_TASK_CAP, l4_fpage(window, L4_PAGESHIFT, L4_FPAGE_RWX),
		    L4_FP_OTHER_SPACES);

		if (l4_error(tag) < 0)
			vm_refused("erx: memory: the kernel refused a revoke\n");
	}
	for (uint32_t task = 0; task < erx_backend_grow_table_capacity(&vm_tasks); task++)
		erx_backend_vm_forget_object(&vm_task(task)->table, index);
}

int
erx_fiasco_vm_body(uint32_t task, erx_backend_vm_op_t op, uint64_t addr, uint64_t size, uint32_t word, uint64_t *reserved)
{
	const erx_backend_vm_request_t request = { .op = op, .addr = addr, .size = size,
	    .flags = op == ERX_BACKEND_VM_RESERVE ? word : 0,
	    .prot = op == ERX_BACKEND_VM_PROTECT ? word : ERX_PROT_NONE };

	return (erx_backend_vm_call(&vm_task(task)->table, &vm_effects, &request, reserved));
}

/*
 * Extends the window in pages of one order until sigma0 refuses or the window
 * meets the area; returns its new end.
 */
static uint64_t
window_grow(uint64_t cursor, unsigned order)
{
	l4_addr_t physical;

	while (cursor < ERX_FIASCO_AREA_START &&
	    l4sigma0_map_anypage(L4_BASE_PAGER_CAP, (l4_addr_t)cursor, order, &physical, order) == 0)
		cursor += UINT64_C(1) << order;
	return (cursor);
}

static uintptr_t
vm_run_take(uint64_t addr)
{
	return (vm_run_window + (uintptr_t)(addr - VM_OBJECT_AREA_START));
}

/* A commit asks for exactly the run's pages, so the check for enough free pages always passes. */
static uint64_t
vm_run_free_pages(void)
{
	return (UINT64_MAX);
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
vm_map(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot)
{
	const l4_msgtag_t tag = l4_task_map(erx_fiasco_task_cap(vm_label_task(label)), L4_BASE_TASK_CAP,
	    l4_fpage(window, L4_PAGESHIFT, fpage_rights(prot)), l4_map_control(addr, 0, 0));

	if (l4_error(tag) < 0)
		vm_refused("erx: memory: the kernel refused a map\n");
}

static void
vm_unmap(uint32_t label, uint64_t addr, uint32_t rights)
{
	const l4_msgtag_t tag = l4_task_unmap(erx_fiasco_task_cap(vm_label_task(label)),
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
