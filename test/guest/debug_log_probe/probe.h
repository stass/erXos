/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DEBUG_LOG_PROBE_H
#define ERX_DEBUG_LOG_PROBE_H

/*
 * The debug-log probe: one program that makes good and malformed erx_debug_log
 * calls and reports what came back through the log itself. It builds for each
 * backend; tools/lib/erx/debug_log_probe.rb compares their transcripts.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/abi_trap.h"

/* Runs every case; the last line it logs is "probe end". */
void erx_probe_run(void);

/* What each backend provides. */

/* The calling thread's UTCB, in the caller's own address space. */
erx_utcb_t *erx_utcb_self(void);

/* A kernel call with exactly these register values. */
void erx_probe_raw_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT]);

/*
 * Makes an empty debug-log call with every other register holding a known
 * value and returns how many of those values the call changed.
 */
uint64_t erx_probe_preserved_changes(uint64_t debug_log_number);

/* Waits past the current one-second window of the log's rate limit. */
void erx_probe_pause(void);

#endif /* ERX_DEBUG_LOG_PROBE_H */
