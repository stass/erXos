/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The debug-log probe on the hosted backend: a raw call is erx_hosted_call,
 * which runs the kernel's dispatch, and no registers exist to change.
 */

#include <stdint.h>
#include <time.h>

#include "liberx/backend/hosted/log.h"
#include "probe.h"

void
erx_probe_raw_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_hosted_call(number, args, results);
}

uint64_t
erx_probe_preserved_changes(uint64_t debug_log_number)
{
	uint64_t args[ERX_TRAP_ARG_COUNT] = { 0 };
	uint64_t results[ERX_TRAP_RESULT_COUNT];

	erx_hosted_call(debug_log_number, args, results);
	return (0);
}

void
erx_probe_pause(void)
{
	struct timespec pause = { .tv_sec = 1, .tv_nsec = 200000000 };

	(void)nanosleep(&pause, NULL);
}

int
main(void)
{
	erx_probe_run();
	return (0);
}
