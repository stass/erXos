/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VM_H
#define ERX_FIASCO_VM_H

#include <stdint.h>

#include "erx/cdefs.h"

/*
 * The root task's own memory on Fiasco (docs/design-stopgap.md, "Budgets and the
 * ownership of pages"). The results are those of the call table's row for these
 * calls; vm_table.h lists each refusal. Nothing here takes a lock: one thread
 * alone calls them.
 */

/*
 * Takes all of sigma0's free memory into the window and readies the pool and the
 * root's range table. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_vm_init(void);

/* How many pages the pool holds now. */
uint64_t	erx_fiasco_vm_free_pages(void);

/* Without ERX_VM_FIXED the address is ignored; *reserved says where it landed. */
int	erx_vm_reserve(uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
	    ERX_WARN_UNUSED_RESULT;
int	erx_vm_commit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_decommit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_release(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_space_protect(uint64_t addr, uint64_t size, uint32_t prot) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_VM_H */
