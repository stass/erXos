/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_CONSOLE_H
#define ERX_FIASCO_CONSOLE_H

#include <stddef.h>

/*
 * The root task's way to the kernel's polled UART output and to the machine's
 * end (docs/design-stopgap.md, "The console" and "The end path"). Neither takes
 * a lock: the root task's one thread alone calls them.
 */
void erx_fiasco_console_write(const char *, size_t);
_Noreturn void erx_fiasco_machine_off(void);

#endif /* ERX_FIASCO_CONSOLE_H */
