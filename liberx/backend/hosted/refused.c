/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The calls of api.h's domain-building list that a hosted runtime links: the
 * erx_domain_lib NIF module names them for the domain library's fault gate
 * and its crash copies, the gate worker (sys/erxos/erx_gate.c) for its fault
 * gate, and the erx_program driver (sys/erxos/erx_program_drv.c) for a
 * program's spaces. The hosted process is the system domain alone, builds no
 * domain library (liberx/backend/core/dom_lib_none.c) and has no sub-space
 * group, so the NIF module and the gate worker call none of them. Each is ERX_ENOTSUP for every hosted caller, as
 * the call table answers a call it does not offer (docs/design-stopgap.md,
 * "The hosted backend"): a hosted BeamAsm image, which none builds, would
 * find its code space (sys/erxos/erx_jit_memory.c) refused here.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"

int
erx_mem_create(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem)
{
	(void)budget, (void)size, (void)flags, (void)mem;
	return (ERX_ENOTSUP);
}

int
erx_cap_close(uint64_t cap)
{
	(void)cap;
	return (ERX_ENOTSUP);
}

int
erx_gate_bind(uint64_t gate, uint64_t thread, uint64_t label)
{
	(void)gate, (void)thread, (void)label;
	return (ERX_ENOTSUP);
}

int
erx_gate_create(uint64_t budget, uint64_t *gate)
{
	(void)budget, (void)gate;
	return (ERX_ENOTSUP);
}

int
erx_ipc_wait(uint64_t wait_by, erx_msgtag_t *tag, uint64_t *label)
{
	(void)wait_by, (void)tag, (void)label;
	return (ERX_ENOTSUP);
}

/*
 * The erx_program driver's (sys/erxos/erx_program_drv.c): a hosted runtime runs no
 * programs, so its first step, the channel's memory, is refused by erx_mem_create above and
 * erx_program:start/1 answers {error, enotsup}.
 */
int
erx_budget_create(uint64_t parent, uint32_t kind, uint64_t guarantee, uint64_t cap, uint64_t *budget)
{
	(void)parent, (void)kind, (void)guarantee, (void)cap, (void)budget;
	return (ERX_ENOTSUP);
}

int
erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group)
{
	(void)budget, (void)parent, (void)group;
	return (ERX_ENOTSUP);
}

int
erx_space_create(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags,
    uint32_t cap_limit, uint64_t *space)
{
	(void)budget, (void)parent, (void)fault, (void)label, (void)flags, (void)cap_limit, (void)space;
	return (ERX_ENOTSUP);
}

int
erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start)
{
	(void)space, (void)image, (void)entry, (void)start;
	return (ERX_ENOTSUP);
}

int
erx_object_destroy(uint64_t object)
{
	(void)object;
	return (ERX_ENOTSUP);
}

int
erx_cap_pass(uint64_t from, uint64_t to, uint32_t n)
{
	(void)from, (void)to, (void)n;
	return (ERX_ENOTSUP);
}
