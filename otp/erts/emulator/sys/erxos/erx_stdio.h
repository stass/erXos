/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The seam between sys_tty_reset, which every exit of the runtime passes, and the console
 * device that made a terminal raw. The device is hosted mode's alone, so sys.c names it
 * only through this call.
 */

#ifndef ERX_STDIO_H
#define ERX_STDIO_H

void	erx_sys_set_tty_reset(void (*restore)(void));

#endif /* ERX_STDIO_H */
