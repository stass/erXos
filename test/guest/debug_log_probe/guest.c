/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The debug-log probe as the root task on Fiasco, over the backend's native
 * path: a raw call runs the kernel's dispatch core in this task, and each
 * record reaches the console through the kernel's log object. After the cases
 * the machine powers off.
 */

#include <stdint.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "probe.h"

void erx_fiasco_root_main(void);

void
erx_probe_raw_call(uint64_t number, const uint64_t args[ERX_TRAP_ARG_COUNT],
    uint64_t results[ERX_TRAP_RESULT_COUNT])
{
	erx_fiasco_call(number, args, results);
}

void
erx_probe_pause(void)
{
	uint64_t start = erx_fiasco_clock_ns();

	while (erx_fiasco_clock_ns() - start < UINT64_C(1200000000))
		continue;
}

void
erx_fiasco_root_main(void)
{
	erx_probe_run();
	erx_fiasco_machine_off();
}
