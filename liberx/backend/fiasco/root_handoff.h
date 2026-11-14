/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_ROOT_HANDOFF_H
#define ERX_FIASCO_ROOT_HANDOFF_H

#include "erx/core/boot_handoff.h"

/*
 * Maps the kernel information page while sigma0 is still the root's pager, finds
 * bootstrap's handoff record through it and accepts it into handoff. Returns NULL,
 * or why the record cannot be had.
 */
const char	*erx_fiasco_root_handoff(erx_boot_handoff_view_t *handoff);

#endif /* ERX_FIASCO_ROOT_HANDOFF_H */
