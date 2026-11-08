/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The test-task launcher in the root (docs/design-stopgap.md, "The call table"): a
 * task from a boot-image program, started, and later waited for. It uses the
 * ordinary calls; only the wait is the backend's own, as a task has no exit record.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"

/* A test task's handles: room enough for any test, and pages are taken only as they fill. */
#define LAUNCHER_CAP_LIMIT	4096u

static bool	launcher_path_equal(const uint8_t *, size_t, const char *);

static bool
launcher_path_equal(const uint8_t *path, size_t length, const char *wanted)
{
	size_t index = 0;

	while (index < length && wanted[index] != '\0' && path[index] == (uint8_t)wanted[index])
		index++;
	return (index == length && wanted[index] == '\0');
}

int
erx_fiasco_launcher_find(const erx_pack_view_t *view, const char *path, uint32_t *entry)
{
	for (uint32_t index = 0; index < view->header.nentries; index++) {
		const uint8_t *name;
		size_t length;

		if (erx_pack_path_at(view, index, &name, &length) && launcher_path_equal(name, length, path)) {
			*entry = index;
			return (ERX_OK);
		}
	}
	return (ERX_EINVAL);
}

int
erx_fiasco_launch(uint32_t entry, uint32_t flags, uint64_t argument, uint64_t *task)
{
	uint64_t space;
	int status = erx_fiasco_launch_make(entry, flags, &space);

	if (status == ERX_OK)
		status = erx_fiasco_launch_start(space, argument);
	if (status == ERX_OK)
		*task = space;
	return (status);
}

int
erx_fiasco_launch_make(uint32_t entry, uint32_t flags, uint64_t *task)
{
	uint64_t space, pc;
	int64_t ignored;
	int status = erx_space_create(0, ERX_CAP_SELF, 0, 0, flags, LAUNCHER_CAP_LIMIT, &space);

	if (status != ERX_OK)
		return (status);
	/* The service keeps the entry for the first thread, so pc is not needed here. */
	status = erx_image_map(space, 0, entry, &pc);
	if (status != ERX_OK) {
		(void)erx_space_stop(space, status);
		(void)erx_fiasco_task_join(space, &ignored);
		return (status);
	}
	*task = space;
	return (ERX_OK);
}

int
erx_fiasco_launch_start(uint64_t task, uint64_t argument)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	int64_t ignored;
	int status;

	start.regs.gpr[0] = argument;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, task, 0, ERX_THREAD_CLASS_WORKER, &thread);
	if (status == ERX_OK)
		status = erx_thread_start(thread);
	if (status != ERX_OK) {
		(void)erx_space_stop(task, status);
		(void)erx_fiasco_task_join(task, &ignored);
	}
	return (status);
}

int
erx_fiasco_task_join(uint64_t task, int64_t *status)
{
	return (erx_fiasco_task_join_until(task, ERX_FIASCO_UMTX_FOREVER, status));
}

int
erx_fiasco_task_join_until(uint64_t task, uint64_t deadline, int64_t *status)
{
	const erx_fiasco_task_join_request_t request = { .caller = erx_fiasco_thread_self()->index, .task = task };
	erx_fiasco_reply_t reply;
	int result;

	if (!erx_fiasco_semaphore_down(erx_fiasco_task_ended_cap(task), deadline))
		return (ERX_ETIMEDOUT);
	result = erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_JOIN, &request, sizeof(request), &reply);
	if (result == ERX_OK)
		*status = (int64_t)reply.first;
	return (result);
}
