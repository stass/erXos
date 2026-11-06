/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The group's report on the native root, under erx.group_report=1 (docs/design-stopgap.md,
 * "The command line"): a thread of its own looks at the status page park.c keeps ten times a
 * second, and the console gets a line each time the count of parked executors or of executors
 * changes, as ERX_HOSTED_GROUP_REPORT gives the hosted backend. That is how the QEMU suite
 * reads an idle machine. The thread only reads the page and sleeps; the machine's end ends it.
 * The line is erx_group_report_line's, which the host tests check.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/group_report.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/thread.h"

#define REPORT_STACK_BYTES	8192u
/* How often the thread looks at the status page, as the hosted report does. */
#define REPORT_US		100000u
#define REPORT_HEAD		"erx: root task: group: "

static void	report_main(uint64_t);

static _Alignas(16) uint8_t report_stack[REPORT_STACK_BYTES];

static void
report_main(uint64_t unused)
{
	const erx_group_stat_t *const status = erx_fiasco_group_status();
	const l4_timeout_t period = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(REPORT_US));
	uint32_t last_parked = UINT32_MAX;
	uint32_t last_executors = UINT32_MAX;
	char line[ERX_GROUP_REPORT_LINE_SIZE(REPORT_HEAD)];

	(void)unused;
	for (;;) {
		const uint32_t parked = atomic_load_explicit(&status->parked, memory_order_relaxed);
		const uint32_t executors = erx_group_status_executors(status);

		if (parked != last_parked || executors != last_executors) {
			erx_fiasco_console_write(line,
			    erx_group_report_line(line, sizeof(line), REPORT_HEAD, parked, executors));
			last_parked = parked;
			last_executors = executors;
		}
		(void)l4_ipc_sleep(period);
	}
}

const char *
erx_fiasco_park_report_start(void)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	int status;

	start.regs.sp = (uint64_t)(uintptr_t)(report_stack + sizeof(report_stack));
	start.regs.pc = (uint64_t)(uintptr_t)report_main;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	status = erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, &thread);
	if (status == ERX_OK)
		status = erx_thread_start(thread);
	return (status == ERX_OK ? NULL : "the group's report: the backend refused its thread");
}
