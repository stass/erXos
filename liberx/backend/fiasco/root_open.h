/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ROOT_OPEN_H
#define ERX_FIASCO_ROOT_OPEN_H

#include "erx/core/boot_handoff.h"
#include "erx/pack.h"

/*
 * The root's steps before its memory: finds bootstrap's handoff record through the
 * kernel information page, accepts it, opens the archive the record names and checks
 * its last entry. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_root_open(erx_boot_handoff_view_t *handoff, erx_pack_view_t *pack);

#endif /* ERX_FIASCO_ROOT_OPEN_H */
