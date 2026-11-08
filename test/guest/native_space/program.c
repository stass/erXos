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
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PAGE	((uint64_t)ERX_PAGE_SIZE)
/* The handle table of each space the creator makes. */
#define CREATED_CAP_LIMIT	16u

int64_t	erx_task_main(uint64_t);

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
	default:
		return (90);
	}
}
