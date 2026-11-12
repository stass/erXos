/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A task's side of its start (docs/design-stopgap.md, "Helper threads"): its first
 * thread readies its own record, starts the task's reaper and its dispatcher through
 * the ordinary calls, runs the program, and stops the task with the program's status.
 * A task reaches the service through the gate the root mapped at the pager's slot, and
 * makes its groups here, where the root's own stubs in group.c are not linked.
 */

#include <stdint.h>

#include <l4/sys/consts.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/task_start.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"

ERX_DECLARE_ABI_NOTE(erx_task_abi_note);

void erx_fiasco_task_main(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

_Static_assert(ERX_FIASCO_START_ARGS == 8, "erx_fiasco_task_main takes each argument register the trampoline loads");
/* program_arg's last value, the session's doorbell, is its highest index. */
_Static_assert(ERX_PROGRAM_ARG_DOORBELL < ERX_FIASCO_START_ARGS, "a program's values fit the argument registers");

uint64_t
erx_fiasco_service_gate(void)
{
	return (L4_BASE_PAGER_CAP);
}

/*
 * A task's group create is the request alone, and starts no dispatcher, since the
 * task's dispatcher already runs. The group's first thread fixes its home.
 * parent is ignored, as in the root.
 */
int
erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group)
{
	const erx_fiasco_group_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget };
	erx_fiasco_reply_t reply;
	int status;

	(void)parent;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_GROUP_CREATE, &request, sizeof(request), &reply);
	if (status == ERX_OK)
		*group = reply.first;
	return (status);
}

/* The service mapped it at the task's creation (time_page.c). */
const erx_time_page_t *
erx_time_page(void)
{
	return ((const erx_time_page_t *)(uintptr_t)ERX_FIASCO_TIME_PAGE_ADDR);
}

/* The trampoline's eight argument registers, as the task's starter wrote them. */
void
erx_fiasco_task_main(uint64_t arg0, uint64_t arg1, uint64_t arg2, uint64_t arg3, uint64_t arg4, uint64_t arg5,
    uint64_t arg6, uint64_t arg7)
{
	const uint64_t args[ERX_FIASCO_START_ARGS] = { arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7 };
	int64_t status = ERX_FIASCO_TASK_STATUS_UP;
	uint64_t dispatcher;

	erx_fiasco_thread_first_init();
	if (erx_fiasco_reaper_start() == NULL && erx_fiasco_dispatcher_start(ERX_CAP_NULL, &dispatcher) == ERX_OK)
		status = erx_task_main(args);
	(void)erx_space_stop(ERX_CAP_SELF, status);
	erx_fiasco_sleep_forever();
}
