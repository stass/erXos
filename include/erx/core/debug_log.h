/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_DEBUG_LOG_H
#define ERX_CORE_DEBUG_LOG_H

/*
 * Who writes the debug log's records on the UART: the early console, as each is written,
 * or, once a console driver owns the UART, the system domain's console, which takes them
 * with erx_debug_log_take (docs/design-stopgap.md, "The console"). One position says what
 * has been taken, whichever of them took it, so a line reaches the UART exactly once and in
 * order across a change of taker. Every other reader reads with erx_debug_log_read from a
 * cursor of its own and moves nothing.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/log.h"

/* From here on, records wait in the ring for the console's take, not the early console. */
void	erx_debug_log_hand_to_console(void);

/* Writes every record not yet taken to the early console, which takes each new one after. */
void	erx_debug_log_take_back(void);

/*
 * The console's read: copies whole records that nobody has taken into the window, as many as
 * fit, and counts them as taken. Records the ring overwrote before anyone took them are
 * counted as lost. A window too short for a record is ERX_EINVAL. Before the handoff and
 * after taking back, the early console has taken every record, so a take copies nothing.
 */
erx_log_copy_result_t erx_debug_log_take(uint8_t *window, size_t window_size);

/*
 * Any other reader's read: copies whole records from cursor on into the window, as many as
 * fit, and changes nothing another reader or the console sees. A cursor older than the
 * ring's oldest record starts there and the result counts the records lost. The cursor of
 * the end is the number the next record will get: a cursor there copies nothing, and one
 * past it, or a window too short for a record, is ERX_EINVAL.
 */
erx_log_copy_result_t erx_debug_log_read(uint64_t cursor, uint8_t *window, size_t window_size);

#endif /* ERX_CORE_DEBUG_LOG_H */
