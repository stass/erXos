/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_WATCHDOG_THREAD_H
#define ERX_FIASCO_WATCHDOG_THREAD_H

#include "erx/cdefs.h"
#include "erx/watchdog.h"

/*
 * The watchdog thread (docs/design-stopgap.md, "The watchdog"): it sleeps one
 * period and steps kernel/core/watchdog.c over the pet word. It takes no lock, so
 * a thread stopped under one cannot stop it, and it outranks every other thread.
 * The first thread starts it, once. Returns NULL, or why it could not.
 */
const char	*erx_fiasco_watchdog_start(const erx_watchdog_config_t *, erx_watchdog_mode_t);

#endif /* ERX_FIASCO_WATCHDOG_THREAD_H */
