/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LIBC_START_H
#define ERX_FIASCO_LIBC_START_H

/* Runs main through musl's start. exit() ends the program, so this returns only on a bug. */
void	erx_fiasco_libc_start(void);

#endif /* ERX_FIASCO_LIBC_START_H */
