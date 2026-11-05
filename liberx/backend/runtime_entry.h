/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_RUNTIME_ENTRY_H
#define ERX_BACKEND_RUNTIME_ENTRY_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * What a backend's entry and sys/erxos share beside the call table
 * (docs/design-stopgap.md, "Boot information"): an entry fills the page and calls
 * erx_runtime_main, and ERTS's start reads only the page.
 */

/* The page, ERX_PAGE_SIZE bytes. Check it with erx_boot_info_read. */
const erx_boot_info_t	*erx_boot_info(void);
/* Wall time in nanoseconds, moving with erx_clock_ns. False when it is unavailable. */
bool			 erx_time_wall_ns(uint64_t *wall_ns) ERX_WARN_UNUSED_RESULT;
/* In sys/erxos: starts ERTS on the page. */
void			 erx_runtime_main(void);

#endif /* ERX_BACKEND_RUNTIME_ENTRY_H */
