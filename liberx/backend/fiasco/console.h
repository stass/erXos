/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_CONSOLE_H
#define ERX_FIASCO_CONSOLE_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/core/console_ring.h"

/*
 * The root task's way to the kernel's polled UART output, and the sleep of a thread
 * that has nothing left to do (docs/design-fiasco.md, "The console"). None of them
 * takes a lock: the threads that call them take none around them.
 */
void erx_fiasco_console_write(const char *, size_t);

/*
 * The kernel's ring console (docs/design-fiasco.md, "The kernel's lines"). The take,
 * Vlog's operation ERX_CONSOLE_RING_OP_TAKE, moves the kernel's lines from the UART to the ring and copies the
 * reply's words out of the message registers, which a tag's word count bounds at
 * ERX_CONSOLE_RING_REPLY_WORDS; it returns false when the kernel refuses the call. The close, ERX_CONSOLE_RING_OP_CLOSE,
 * writes the ring out to the UART and sends every later line there.
 */
bool erx_fiasco_console_take(erx_console_reply_words_t *);
void erx_fiasco_console_close(void);
_Noreturn void	erx_fiasco_sleep_forever(void);

#endif /* ERX_FIASCO_CONSOLE_H */
