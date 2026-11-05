/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's side of its start (docs/design-stopgap.md, "Helper threads"): its first
 * thread readies its own record, starts the task's reaper through the ordinary calls,
 * runs the program, and stops the task with the program's status. A task reaches the
 * service through the gate the root mapped at the pager's slot.
 */

#include <stdint.h>

#include <l4/sys/consts.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"

ERX_DECLARE_ABI_NOTE(erx_task_abi_note);

void erx_fiasco_task_main(uint64_t);

uint64_t
erx_fiasco_service_gate(void)
{
	return (L4_BASE_PAGER_CAP);
}

void
erx_fiasco_task_main(uint64_t argument)
{
	int64_t status = ERX_FIASCO_TASK_STATUS_UP;

	erx_fiasco_thread_first_init();
	if (erx_fiasco_reaper_start() == NULL)
		status = erx_task_main(argument);
	(void)erx_space_stop(ERX_CAP_SELF, status);
	erx_fiasco_sleep_forever();
}

/* A task has no scheduler capability to ask, and runs where its thread was started. */
uint64_t
erx_fiasco_cpus_online(void)
{
	return (UINT64_C(1));
}
