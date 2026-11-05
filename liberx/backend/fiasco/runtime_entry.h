/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H
#define ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H

#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "liberx/backend/fiasco/boot_args.h"

/*
 * What the root task runs once it is up: it fills the boot information page and enters
 * musl's start path. Returns only on a refusal, with the reason. A root built without a
 * program answers this with root_no_program.c.
 */
const char	*erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *manifest,
	    const erx_boot_args_t *boot_args);

/*
 * Enters musl's start path with program as main, on a stack of its own with a guard below
 * it (docs/design-stopgap.md, "musl over the backend"). Needs the root service running.
 */
_Noreturn void	 erx_fiasco_libc_root_start(int (*program)(int, char **, char **));

#endif /* ERX_BACKEND_FIASCO_RUNTIME_ENTRY_H */
