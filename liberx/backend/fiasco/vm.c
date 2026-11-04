/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The effects under vm_table.c and page_pool.c: taking sigma0's memory, and the
 * root mapping its own window pages at the addresses its range table names.
 * Every decision is in those cores.
 *
 * The window maps all RAM, read, write and execute, as sigma0 gives it, and is
 * never unmapped: it is where a page lives, and a task's mapping of the page is
 * the window's child, so unmapping that child leaves the page and its contents
 * alone. The root is its own sender and receiver here, so each call names
 * L4_BASE_TASK_CAP twice.
 */

#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/err.h>
#include <l4/sys/task.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/page_pool.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/backend/fiasco/vm_table.h"

/* The backend's address layout: above all RAM, and below 2^39, Fiasco's user limit here. */
#define VM_WINDOW_BASE	UINT64_C(0x1000000000)
#define VM_AREA_START	ERX_FIASCO_AREA_START
#define VM_AREA_END	UINT64_C(0x8000000000)
/* The window's two grains: sigma0 gives 2 MiB until refused, then 4 KiB until refused. */
#define VM_SUPERPAGE_ORDER	21u
/* How many separate reserved runs the root may hold; more is ERX_ENOMEM. */
#define VM_RANGES_MAX	4096u

_Static_assert(VM_WINDOW_BASE % (UINT64_C(1) << VM_SUPERPAGE_ORDER) == 0,
    "the window starts on a superpage");

static unsigned	fpage_rights(uint32_t);
static void	vm_map(uintptr_t, uint64_t, uint32_t);
static void	vm_unmap(uint64_t, uint32_t);
static uint64_t	window_grow(uint64_t, unsigned);
static _Noreturn void vm_refused(const char *);

static const erx_fiasco_vm_effects_t vm_effects = { .map = vm_map, .unmap = vm_unmap };
static erx_fiasco_vm_range_t vm_ranges[VM_RANGES_MAX];
static erx_fiasco_vm_table_t vm_table;
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

	erx_fiasco_vm_table_init(&vm_table, vm_ranges, VM_RANGES_MAX,
	    (erx_fiasco_vm_page_t *)(uintptr_t)VM_WINDOW_BASE, (size_t)layout.index_slots,
	    VM_AREA_START, VM_AREA_END);
	for (uint64_t page = layout.index_pages; page < window_pages; page++)
		erx_fiasco_pool_put(&vm_pool, (uintptr_t)(VM_WINDOW_BASE + (page << L4_PAGESHIFT)));
	return (NULL);
}

uint64_t
erx_fiasco_vm_free_pages(void)
{
	return (vm_pool.free_pages);
}

int
erx_fiasco_vm_body(erx_fiasco_vm_op_t op, uint64_t addr, uint64_t size, uint32_t word, uint64_t *reserved)
{
	const erx_fiasco_vm_request_t request = { .op = op, .addr = addr, .size = size,
	    .flags = op == ERX_FIASCO_VM_RESERVE ? word : 0,
	    .prot = op == ERX_FIASCO_VM_PROTECT ? word : ERX_PROT_NONE };

	return (erx_fiasco_vm_call(&vm_table, &vm_pool, &vm_effects, &request, reserved));
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
vm_map(uintptr_t window, uint64_t addr, uint32_t prot)
{
	const l4_msgtag_t tag = l4_task_map(L4_BASE_TASK_CAP, L4_BASE_TASK_CAP,
	    l4_fpage(window, L4_PAGESHIFT, fpage_rights(prot)), l4_map_control(addr, 0, 0));

	if (l4_error(tag) < 0)
		vm_refused("erx: memory: the kernel refused a map\n");
}

static void
vm_unmap(uint64_t addr, uint32_t rights)
{
	const l4_msgtag_t tag = l4_task_unmap(L4_BASE_TASK_CAP,
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
