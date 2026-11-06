/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The group report's pure part, on the host: how many executors a status page holds,
 * and the line each backend's reporter writes. A line must read exactly, fit the size
 * ERX_GROUP_REPORT_LINE_SIZE gives for the longest counts, and never write past a
 * buffer too small for it.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "liberx/backend/core/group_report.h"

#define HEAD		"erx: root task: group: "
#define GUARD		0x5a
#define GUARD_BYTES	16u

static int failures;
static unsigned cases;

static void
expect(bool holds, const char *what)
{
	cases++;
	if (!holds) {
		(void)printf("group report: %s\n", what);
		failures++;
	}
}

static void
check_executors(void)
{
	static erx_group_stat_t status;
	static const uint32_t states[] = { ERX_EXEC_STATE_RUNNING, ERX_EXEC_STATE_READY, ERX_EXEC_STATE_PARKED,
		ERX_EXEC_STATE_BLOCKED, ERX_EXEC_STATE_THROTTLED, ERX_EXEC_STATE_PAUSED };

	memset(&status, 0, sizeof(status));
	expect(erx_group_status_executors(&status) == 0, "an empty page counts executors");
	atomic_store(&status.exec[0].state, ERX_EXEC_STATE_PARKED);
	atomic_store(&status.exec[ERX_GROUP_EXECUTORS_MAX - 1].state, ERX_EXEC_STATE_RUNNING);
	expect(erx_group_status_executors(&status) == 2, "the first and last slots are not both counted");
	for (uint32_t slot = 0; slot < ERX_GROUP_EXECUTORS_MAX; slot++)
		atomic_store(&status.exec[slot].state, states[slot % (sizeof(states) / sizeof(states[0]))]);
	expect(erx_group_status_executors(&status) == ERX_GROUP_EXECUTORS_MAX, "a state other than none is not counted");
}

/* The line for parked and executors in a buffer of size bytes followed by guard bytes. */
static void
check_line(uint32_t parked, uint32_t executors, size_t size, const char *want)
{
	char buffer[ERX_GROUP_REPORT_LINE_SIZE(HEAD) + GUARD_BYTES];
	char what[160];
	size_t length;
	bool guarded = true;

	memset(buffer, GUARD, sizeof(buffer));
	length = erx_group_report_line(buffer, size, HEAD, parked, executors);
	for (size_t at = size; at < sizeof(buffer); at++)
		guarded = guarded && buffer[at] == (char)GUARD;
	(void)snprintf(what, sizeof(what), "parked %u of %u in %zu bytes wrote past them", parked, executors, size);
	expect(guarded, what);
	if (want == NULL) {
		(void)snprintf(what, sizeof(what), "parked %u of %u in %zu bytes fit", parked, executors, size);
		expect(length == 0 && (size == 0 || buffer[0] == '\0'), what);
		return;
	}
	(void)snprintf(what, sizeof(what), "parked %u of %u reads wrongly", parked, executors);
	expect(length == strlen(want) && memcmp(buffer, want, length + 1) == 0, what);
}

int
main(void)
{
	const size_t longest = ERX_GROUP_REPORT_LINE_SIZE(HEAD);

	check_executors();
	check_line(3, 4, longest, HEAD "parked 3 of 4\n");
	check_line(0, 0, longest, HEAD "parked 0 of 0\n");
	check_line(10, 10, longest, HEAD "parked 10 of 10\n");
	check_line(UINT32_MAX, UINT32_MAX, longest, HEAD "parked 4294967295 of 4294967295\n");
	check_line(UINT32_MAX, UINT32_MAX, longest - 1, NULL);
	check_line(3, 4, sizeof(HEAD "parked 3 of 4\n"), HEAD "parked 3 of 4\n");
	check_line(3, 4, sizeof(HEAD "parked 3 of 4\n") - 1, NULL);
	check_line(3, 4, 1, NULL);
	check_line(3, 4, 0, NULL);
	(void)printf("group report: %u cases, %d failures\n", cases, failures);
	return (failures == 0 ? 0 : 1);
}
