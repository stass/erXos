/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_DEBUG_LOG_H
#define ERX_CORE_DEBUG_LOG_H

/*
 * Who takes the debug log's records: its console, as each is written, or a reader through
 * erx_debug_log_read, once a console driver owns the UART (docs/design-stopgap.md, "The
 * console"). One position says what has been taken, whoever took it, so a record leaves
 * exactly once and in order across a change of taker.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/log.h"

/* From here on, records wait in the ring for a reader and the console gets none. */
void	erx_debug_log_hand_to_reader(void);

/* Writes every record not yet taken to the console, which takes each new one from here on. */
void	erx_debug_log_take_back(void);

/*
 * Copies whole records that nobody has taken into the window, and counts them as taken.
 * The log has one reader, the system domain's console, which passes 0 first and then the
 * cursor each read returned. Reading always starts at what has been taken, so a cursor
 * behind it, the reader's first or one from before the console took records back, gets
 * what nobody had, and a cursor past it, which only a second reader or a forged cursor
 * holds, is ERX_EINVAL. A window too short for a record is ERX_EINVAL.
 */
erx_log_copy_result_t erx_debug_log_read(uint64_t cursor, uint8_t *window, size_t window_size);

#endif /* ERX_CORE_DEBUG_LOG_H */
