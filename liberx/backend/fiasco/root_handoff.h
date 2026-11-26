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
 * or why the record cannot be had. With the record, it decides from its line whether
 * the kernel's rings record in this boot, as the kernel decided (erx_fiasco_trace_boot),
 * so every root that reads its handoff decides before anything can end it.
 */
const char	*erx_fiasco_root_handoff(erx_boot_handoff_view_t *handoff);

#endif /* ERX_FIASCO_ROOT_HANDOFF_H */
