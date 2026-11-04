/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VM_H
#define ERX_FIASCO_VM_H

#include <stdint.h>

#include "erx/cdefs.h"
#include "liberx/backend/fiasco/vm_table.h"

/* The first address of the area the root's range table hands out. */
#define ERX_FIASCO_AREA_START	UINT64_C(0x4000000000)

/*
 * The root task's own memory on Fiasco (docs/design-stopgap.md, "Budgets and the
 * ownership of pages"). The results are those of the call table's row for these
 * calls; vm_table.h lists each refusal. The service alone runs the bodies, and the
 * root's first thread before the service runs, so nothing here takes a lock. The
 * calls themselves are stubs that send it a request (service_stubs.c).
 */

/*
 * Takes all of sigma0's free memory into the window and readies the pool and the
 * root's range table. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_vm_init(void);

/* How many pages the pool holds now. */
uint64_t	erx_fiasco_vm_free_pages(void);

/*
 * One call's body. word is the flags of a reserve or the protection of a protect,
 * and otherwise 0; *reserved is set by a reserve alone.
 */
int	erx_fiasco_vm_body(erx_fiasco_vm_op_t op, uint64_t addr, uint64_t size, uint32_t word,
	    uint64_t *reserved) ERX_WARN_UNUSED_RESULT;

/* Without ERX_VM_FIXED the address is ignored; *reserved says where it landed. */
int	erx_vm_reserve(uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
	    ERX_WARN_UNUSED_RESULT;
int	erx_vm_commit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_decommit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_release(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_space_protect(uint64_t addr, uint64_t size, uint32_t prot) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_VM_H */
