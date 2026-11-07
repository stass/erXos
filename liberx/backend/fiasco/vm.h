/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_VM_H
#define ERX_FIASCO_VM_H

#include <stdint.h>

#include "erx/cdefs.h"
#include "liberx/backend/core/vm_table.h"
#include "liberx/backend/fiasco/service_wire.h"

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
/* How many pages the pool has handed out and not taken back: the root budget's used. */
uint64_t	erx_fiasco_vm_used_pages(void);

/* Readies a task's empty range table, before the task's first page. */
void	erx_fiasco_vm_task_open(uint32_t task);
/* Gives back every page of a task and of its objects: the task's space must be gone. */
void	erx_fiasco_vm_task_close(uint32_t task);
/* The window page behind a task's committed address, or 0. */
uintptr_t	erx_fiasco_vm_task_window(uint32_t task, uint64_t addr);

/*
 * One call's body, for this task. word is the flags of a reserve or the protection
 * of a protect, and otherwise 0; *reserved is set by a reserve alone.
 */
int	erx_fiasco_vm_body(uint32_t task, erx_backend_vm_op_t op, uint64_t addr, uint64_t size,
	    uint32_t word, uint64_t *reserved) ERX_WARN_UNUSED_RESULT;

/*
 * A shared object of the task's, every page taken at once (docs/design-stopgap.md,
 * "Shared objects and the JIT alias"). No room for it or no pages is ERX_ENOMEM. It
 * lives as long as the task.
 */
int	erx_fiasco_vm_object_create(uint32_t task, uint64_t size, uint64_t *handle) ERX_WARN_UNUSED_RESULT;
/*
 * An object over a device's registers, mapped at a device window address and from
 * there anywhere its task reserves. A full window, or no slot, is ERX_ENOMEM;
 * sigma0's refusal, which RAM gets, is ERX_ERANGE. Its arguments are checked already.
 */
int	erx_fiasco_vm_physical_create(uint32_t task, uint64_t base, uint64_t size, uint64_t *handle) ERX_WARN_UNUSED_RESULT;
/*
 * An object over a zeroed run of the contiguous pool, wholly below device address
 * limit (0 for none). No such run, or no slot, is ERX_ENOMEM. Its size is checked
 * already. The run stays held when the object goes: a device may still write it.
 */
int	erx_fiasco_vm_contiguous_create(uint32_t task, uint64_t size, uint64_t limit, uint64_t *handle) ERX_WARN_UNUSED_RESULT;
/* A contiguous object's device address at an offset in it; another kind of object is ERX_ETYPE, an offset past it ERX_ERANGE. */
int	erx_fiasco_vm_object_dma_addr(uint32_t task, uint64_t handle, uint64_t offset, uint64_t *addr) ERX_WARN_UNUSED_RESULT;
/* Maps an object's pages into its own task: vm_table.h lists each refusal. A device's object mapped to run is ERX_ERIGHTS. */
int	erx_fiasco_vm_object_map(uint32_t task, uint64_t handle, uint64_t addr, uint64_t size,
	    uint64_t offset, uint32_t prot) ERX_WARN_UNUSED_RESULT;

/* Without ERX_VM_FIXED the address is ignored; *reserved says where it landed. */
int	erx_vm_reserve(uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
	    ERX_WARN_UNUSED_RESULT;
int	erx_vm_commit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_decommit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_release(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_space_protect(uint64_t addr, uint64_t size, uint32_t prot) ERX_WARN_UNUSED_RESULT;
/*
 * flags is ERX_MEM_JIT or 0; a JIT object is ERX_ERIGHTS from a task made without
 * ERX_SPACE_JIT.
 */
int	erx_mem_create(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_VM_H */
