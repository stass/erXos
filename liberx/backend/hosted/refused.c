/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The calls of api.h's domain-building list that a hosted runtime links: the
 * erx_domain_lib NIF module names them for the domain library's fault gate
 * and its crash copies. The hosted process is the system domain alone and
 * builds no domain library (liberx/backend/core/dom_lib_none.c), so the
 * module calls none of them. Each is ERX_ENOTSUP for every hosted caller, as
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
