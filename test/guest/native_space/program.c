/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The tasks of the mapping suite, loaded from the boot image by
 * test/guest/native_space/guest.c, which maps their pages before their first thread
 * runs. The status is the report: 0 is success, any other names the first step that
 * went wrong, and a revoked reader's fault goes to its fault gate, where it stays
 * blocked until the root stops it.
 */

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/native_space/modes.h"

#define PAGE	((uint64_t)ERX_PAGE_SIZE)

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
	default:
		return (90);
	}
}
