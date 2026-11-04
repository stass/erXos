/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The debug log on Fiasco with no root service: one thread in one task runs
 * the call's body directly (docs/design-stopgap.md, "Boot handoff"),
 * which is the kernel's own dispatch and log cores, as on the hosted backend.
 * Each record goes out through the kernel's log object as it is written. A
 * public UTCB of this file's own holds what the caller stores, since each
 * native call overwrites the native UTCB's message registers.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "erx/log.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/generated/calls.h"
#include "liberx/backend/fiasco/log.h"

/* The task's number in every record: the one task there is. */
#define ERX_FIASCO_LOG_SPACE	1

/* The task's log rate; one thread touches it, so the cores' lock is empty. */
static erx_log_rate_t erx_fiasco_log_rate;

static erx_utcb_t erx_fiasco_public_utcb;

erx_utcb_t *
erx_utcb_self(void)
{
	return (&erx_fiasco_public_utcb);
}

void
erx_effect_log_lock(void)
{
}

void
erx_effect_log_unlock(void)
{
}

void
erx_effect_console_write(const char *line, size_t length)
{
	erx_fiasco_console_write(line, length);
}

uint64_t
erx_effect_clock_ns(void)
{
	return (erx_fiasco_clock_ns());
}

void
erx_fiasco_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_sys_caller_t caller = {
		.utcb = &erx_fiasco_public_utcb,
		.log_rate = &erx_fiasco_log_rate,
		.space = ERX_FIASCO_LOG_SPACE,
		.executor = false,
	};

	erx_dispatch(&caller, number, args, results);
}

erx_status_t
erx_fiasco_debug_log(erx_utcb_length_t len)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { (uint64_t)len.raw };
	uint64_t results[ERX_TRAP_RESULT_COUNT];
	uint32_t raw_status;

	erx_fiasco_call(ERX_CALL_DEBUG_LOG, args, results);
	raw_status = (uint32_t)results[0];
	return (raw_status <= UINT32_C(2147483647) ? (int32_t)raw_status :
	    -INT32_C(1) - (int32_t)(UINT32_C(4294967295) - raw_status));
}
