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
 * The line is fixed words and two numbers, so it needs no escape.
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
#define REPORT_HEAD		"erx: root task: group: parked "
#define REPORT_OF		" of "
/*
 * The words, two 32-bit counts of at most ten digits each, and the newline. The appends
 * below check no bounds of their own: no line they build is longer than this.
 */
#define REPORT_LINE_MAX		((sizeof(REPORT_HEAD) - 1) + (sizeof(REPORT_OF) - 1) + 2 * 10 + 1)

static void	report_main(uint64_t);

static _Alignas(16) uint8_t report_stack[REPORT_STACK_BYTES];

static size_t
report_append(char *line, size_t used, const char *text)
{
	while (*text != '\0')
		line[used++] = *text++;
	return (used);
}

static size_t
report_append_decimal(char *line, size_t used, uint32_t value)
{
	char digits[10];
	size_t count = 0;

	do {
		digits[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0)
		line[used++] = digits[--count];
	return (used);
}

/* The line for one look at the page, and its length: REPORT_LINE_MAX holds the longest. */
static size_t
report_line(char line[static REPORT_LINE_MAX], uint32_t parked, uint32_t executors)
{
	size_t used = 0;

	used = report_append(line, used, REPORT_HEAD);
	used = report_append_decimal(line, used, parked);
	used = report_append(line, used, REPORT_OF);
	used = report_append_decimal(line, used, executors);
	line[used++] = '\n';
	return (used);
}

static void
report_main(uint64_t unused)
{
	const erx_group_stat_t *const status = erx_fiasco_group_status();
	const l4_timeout_t period = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(REPORT_US));
	uint32_t last_parked = UINT32_MAX;
	uint32_t last_executors = UINT32_MAX;
	char line[REPORT_LINE_MAX];

	(void)unused;
	for (;;) {
		const uint32_t parked = atomic_load_explicit(&status->parked, memory_order_relaxed);
		const uint32_t executors = erx_group_status_executors(status);

		if (parked != last_parked || executors != last_executors) {
			erx_fiasco_console_write(line, report_line(line, parked, executors));
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
