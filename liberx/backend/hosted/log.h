/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_HOSTED_LOG_H
#define ERX_HOSTED_LOG_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/abi_trap.h"

/* The calling thread's UTCB, as the erx backend's erx_utcb_self returns it. */
erx_utcb_t *erx_utcb_self(void);

/*
 * One kernel call as a trap makes it: any number and any register values,
 * through the same dispatch the kernel runs. The typed erx_hosted_* calls are
 * built on it; tests use it to make calls no typed wrapper can express.
 */
void erx_hosted_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT]);

#endif /* ERX_HOSTED_LOG_H */
