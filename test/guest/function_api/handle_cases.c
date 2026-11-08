/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Handles to memory objects (docs/design-stopgap.md, "Capabilities in Fiasco's object
 * space", and the "A stale handle" and "Generations" rows of its tests), which only
 * native has calls for: hosted gets them with the rest of the handle rows. A stale
 * handle is told from a live one by a map two pages long, which the stale handle's own
 * object of one page refuses and the two-page object made after it would take, so a
 * handle that named its successor shows.
 *
 * generations must run before any other case destroys an object: every record is then
 * either live or never used, so its first object takes a record at generation 0, the
 * value a generation that wrapped would come back to.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/vm.h"

bool	function_api_case_generations(void);
bool	function_api_case_stale_handle(void);
bool	function_api_case_dup_and_close(void);

#define PAGE	((uint64_t)ERX_PAGE_SIZE)

/* What a two-page map through mem answers, with nothing left mapped or reserved either way. */
static int
map_two_pages(uint64_t mem)
{
	uint64_t addr;
	int status;

	if (erx_vm_reserve(0, 2 * PAGE, 0, &addr) != ERX_OK)
		return (ERX_ENOMEM);
	status = erx_vm_map(ERX_CAP_SELF, addr, 2 * PAGE, mem, 0, ERX_PROT_RW);
	if (erx_vm_release(addr, 2 * PAGE) != ERX_OK)
		return (ERX_EFAULT);
	return (status);
}

/* A record at its last generation retires when its object goes, and the next create takes another. */
bool
function_api_case_generations(void)
{
	uint64_t first, aged, next;

	if (erx_mem_create(0, PAGE, 0, &first) != ERX_OK || erx_object_destroy(first) != ERX_OK)
		return (false);
	erx_fiasco_test_object_age();
	if (erx_mem_create(0, PAGE, 0, &aged) != ERX_OK || erx_object_destroy(aged) != ERX_OK ||
	    erx_mem_create(0, 2 * PAGE, 0, &next) != ERX_OK)
		return (false);
	return (map_two_pages(first) == ERX_ESTALE && map_two_pages(aged) == ERX_ESTALE &&
	    erx_cap_close(first) == ERX_OK && erx_cap_close(aged) == ERX_OK && erx_object_destroy(next) == ERX_OK &&
	    erx_cap_close(next) == ERX_OK);
}

/* A handle to a destroyed object is ERX_ESTALE, and stays so once its record holds a new object. */
bool
function_api_case_stale_handle(void)
{
	uint64_t gone, successor, copy;

	if (erx_mem_create(0, PAGE, 0, &gone) != ERX_OK || erx_object_destroy(gone) != ERX_OK)
		return (false);
	if (map_two_pages(gone) != ERX_ESTALE || erx_cap_dup(gone, &copy) != ERX_ESTALE ||
	    erx_object_destroy(gone) != ERX_ESTALE)
		return (false);
	if (erx_mem_create(0, 2 * PAGE, 0, &successor) != ERX_OK)
		return (false);
	return (map_two_pages(gone) == ERX_ESTALE && erx_object_destroy(gone) == ERX_ESTALE &&
	    erx_cap_close(gone) == ERX_OK && erx_cap_close(gone) == ERX_EINVAL && erx_object_destroy(gone) == ERX_EINVAL &&
	    erx_object_destroy(successor) == ERX_OK && erx_cap_close(successor) == ERX_OK);
}

/*
 * A dup names the same object; the object outlives its first handle and goes with its
 * last, giving its pages back; a mapped object outlives every handle. A dup of a dup is
 * how this case sees a handle is good, since a map would keep the object.
 */
bool
function_api_case_dup_and_close(void)
{
	const uint64_t before = erx_vm_free_pages();
	uint64_t mem, copy, probe, mapped, addr;

	if (erx_mem_create(0, 2 * PAGE, 0, &mem) != ERX_OK || erx_cap_dup(mem, &copy) != ERX_OK || copy == mem ||
	    erx_vm_free_pages() >= before)
		return (false);
	if (erx_cap_close(mem) != ERX_OK || erx_cap_dup(copy, &probe) != ERX_OK || erx_cap_close(probe) != ERX_OK ||
	    erx_cap_close(mem) != ERX_EINVAL ||
	    erx_cap_close(0) != ERX_EINVAL || erx_cap_dup(0, &mem) != ERX_EINVAL)
		return (false);
	if (erx_cap_close(copy) != ERX_OK || erx_vm_free_pages() != before)
		return (false);
	if (erx_mem_create(0, PAGE, 0, &mapped) != ERX_OK || erx_vm_reserve(0, PAGE, 0, &addr) != ERX_OK ||
	    erx_vm_map(ERX_CAP_SELF, addr, PAGE, mapped, 0, ERX_PROT_RW) != ERX_OK)
		return (false);
	*(volatile uint64_t *)(uintptr_t)addr = 0x5eed;
	return (erx_object_destroy(mapped) == ERX_ENOTSUP && erx_cap_close(mapped) == ERX_OK &&
	    *(volatile uint64_t *)(uintptr_t)addr == 0x5eed);
}
