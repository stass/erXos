/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_LOG_H
#define ERX_FIASCO_LOG_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/abi_trap.h"

/* The calling thread's UTCB, as the erx backend's erx_utcb_self returns it. */
erx_utcb_t *erx_utcb_self(void);

/*
 * One call as the ABI defines it: any number and any register values, through
 * the kernel's dispatch core. The typed erx_fiasco_* calls are built on it;
 * tests use it to make calls no typed wrapper can express.
 */
void erx_fiasco_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT]);

/* Monotonic time since an arbitrary start, from the architecture's counter. */
uint64_t erx_fiasco_clock_ns(void);
/* The counter itself and its frequency, which the time page scales. */
uint64_t erx_fiasco_counter(void);
uint64_t erx_fiasco_counter_hz(void);

#endif /* ERX_FIASCO_LOG_H */
