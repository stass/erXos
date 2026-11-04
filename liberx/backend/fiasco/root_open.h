/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ROOT_OPEN_H
#define ERX_FIASCO_ROOT_OPEN_H

#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/pack.h"

/*
 * The root's steps before its memory: finds bootstrap's handoff record through the
 * kernel information page, accepts it, opens the archive the record names and checks
 * its last entry. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_root_open(erx_boot_handoff_view_t *handoff, erx_pack_view_t *pack);

/*
 * Finds the system manifest in the open archive, checks its file hash and reads it
 * through the generated C reader, which allocates nothing and leaves the view
 * pointing into the archive. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_root_read_manifest(const erx_pack_view_t *pack, erx_manifest_view_t *manifest);

#endif /* ERX_FIASCO_ROOT_OPEN_H */
