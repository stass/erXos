/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_EFFECTS_H
#define ERX_CORE_EFFECTS_H

/*
 * The effects a host of the cores provides (docs/design-stopgap.md,
 * "Interfaces"): each of them acts on the world the cores never touch.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The one lock around the kernel log and every space's log rate state. */
void erx_effect_log_lock(void);
void erx_effect_log_unlock(void);

/* The kernel clock, in nanoseconds. */
uint64_t erx_effect_clock_ns(void);

/*
 * Writes one line to the early console: a rendered log line or a line of the
 * crash frame. It holds only what those writers made, and failing to write it
 * is not the caller's concern.
 */
void erx_effect_console_write(const char *line, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_EFFECTS_H */
