/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * BeamAsm's code space, as erx_jit_memory.h describes it; built only with
 * BeamAsm. The kernel admits a JIT object only in a space created with
 * ERX_SPACE_JIT and never maps one writable and executable at once. Each alias
 * is a reservation of its own, so an unmap releases each whole and removes its
 * mapping; the object's handle is closed once both mappings hold it, so the
 * second release ends the object. This file is the runtime's one erx_vm_map
 * outside the device shim, and it maps only the object it has just created.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "liberx/backend/api.h"
#include "erx_jit_memory.h"

static int
jit_memory_result(int status)
{
    if (status == ERX_OK)
	return ERX_JIT_MEMORY_OK;
    return status == ERX_ENOMEM ? ERX_JIT_MEMORY_NO_ROOM : ERX_JIT_MEMORY_REFUSED;
}

size_t
erx_jit_memory_page(void)
{
    return ERX_PAGE_SIZE;
}

int
erx_jit_memory_map(size_t size, void **rx, void **rw)
{
    uint64_t mem, rx_addr = 0, rw_addr = 0;
    int status, closed;

    *rx = NULL;
    *rw = NULL;
    if (size == 0 || (size & (ERX_PAGE_SIZE - 1)) != 0)
	return ERX_JIT_MEMORY_REFUSED;
    status = erx_mem_create(0, size, ERX_MEM_JIT, &mem);
    if (status != ERX_OK)
	return jit_memory_result(status);
    status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &rx_addr);
    if (status == ERX_OK)
	status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &rw_addr);
    if (status == ERX_OK)
	status = erx_vm_map(ERX_CAP_SELF, rx_addr, size, mem, 0, ERX_PROT_RX);
    if (status == ERX_OK)
	status = erx_vm_map(ERX_CAP_SELF, rw_addr, size, mem, 0, ERX_PROT_RW);
    closed = erx_cap_close(mem);
    if (status == ERX_OK && closed != ERX_OK)
	status = closed;
    if (status != ERX_OK) {
	if (rx_addr != 0 && erx_vm_release(ERX_CAP_SELF, rx_addr, size) != ERX_OK)
	    erts_exit(ERTS_ABORT_EXIT, "jit: cannot release a code alias\n");
	if (rw_addr != 0 && erx_vm_release(ERX_CAP_SELF, rw_addr, size) != ERX_OK)
	    erts_exit(ERTS_ABORT_EXIT, "jit: cannot release a code alias\n");
	return jit_memory_result(status);
    }
    *rx = (void *) (UWord) rx_addr;
    *rw = (void *) (UWord) rw_addr;
    return ERX_JIT_MEMORY_OK;
}

int
erx_jit_memory_unmap(void *rx, void *rw, size_t size)
{
    int status = erx_vm_release(ERX_CAP_SELF, (uint64_t) (UWord) rx, size);

    if (status == ERX_OK)
	status = erx_vm_release(ERX_CAP_SELF, (uint64_t) (UWord) rw, size);
    return jit_memory_result(status);
}
