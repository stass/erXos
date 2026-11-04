/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_TIME_H
#define ERX_FIASCO_TIME_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The time page (docs/design-stopgap.md, the call table): the service fills and
 * writes it, and reading it needs no call.
 */

/* On the first thread, before the service starts. */
void		erx_fiasco_time_init(void);

const erx_time_page_t *erx_time_page(void);
uint64_t	erx_time_monotonic_ns(void);
/* False when the page's sequence has run out, which leaves wall time unavailable. */
bool		erx_time_wall_ns(uint64_t *wall_ns) ERX_WARN_UNUSED_RESULT;

/* Sets wall time from now on. ERX_ELIMIT when the page's sequence has run out. */
int		erx_time_set_wall(uint64_t wall_ns) ERX_WARN_UNUSED_RESULT;
/* The call's body, on the service. */
int		erx_fiasco_time_set_wall_body(uint64_t wall_ns);

#endif /* ERX_FIASCO_TIME_H */
