/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The reports of erx_object_info on liberx's Phase 1 backends, and the one field they
 * count only partly (docs/design-stopgap.md, "Reporting kernel objects"). Per topic:
 *
 *   machine  cpus_online, the count of the kernel's map, reported when the map is known
 *   cpu      a CPU of that map, with nothing reported
 *   group    the report erx_group_info wrote, its own reported bits kept
 *   budget   used, the pool's count, never reported: erx_info_partial names it
 *   thread   the index-th thread of the space, its id its index in the backend's table,
 *            with nothing reported, since only a kernel knows a thread's state
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/mem.h"
#include "liberx/backend/core/object_info.h"

#define THREAD_BITS	(8 * sizeof(((erx_info_facts_t *)NULL)->threads))

uint32_t
erx_info_partial(uint32_t topic)
{
	return (topic == ERX_INFO_BUDGET ? ERX_INFO_BUDGET_REPORTED_USED : 0);
}

uint64_t
erx_info_report_size(uint32_t topic)
{
	switch (topic) {
	case ERX_INFO_MACHINE:
		return (sizeof(erx_info_machine_t));
	case ERX_INFO_CPU:
		return (sizeof(erx_info_cpu_t));
	case ERX_INFO_GROUP:
		return (sizeof(erx_info_group_t));
	case ERX_INFO_BUDGET:
		return (sizeof(erx_info_budget_t));
	case ERX_INFO_THREAD:
		return (sizeof(erx_info_thread_t));
	default:
		return (0);
	}
}

/* The position of the index-th set bit of the thread map, or false when it has fewer. */
static bool
nth_thread(const uint64_t threads[2], uint64_t index, uint64_t *id)
{
	uint64_t seen = 0;

	for (uint64_t bit = 0; bit < THREAD_BITS; bit++) {
		if ((threads[bit / 64] >> (bit % 64) & 1) == 0)
			continue;
		if (seen++ == index) {
			*id = bit;
			return (true);
		}
	}
	return (false);
}

int
erx_info_report(uint32_t topic, uint64_t index, const erx_info_facts_t *facts, void *window, uint64_t size)
{
	const uint64_t bytes = erx_info_report_size(topic);
	union {
		erx_info_machine_t	machine;
		erx_info_cpu_t		cpu;
		erx_info_group_t	group;
		erx_info_budget_t	budget;
		erx_info_thread_t	thread;
	} report;
	uint64_t id;

	if (topic == ERX_INFO_BASIC || topic == ERX_INFO_IMAGE_ENTRY)
		return (ERX_ENOTSUP);
	if (bytes == 0 || window == NULL || size < bytes)
		return (ERX_EINVAL);
	bzero(&report, sizeof(report));
	switch (topic) {
	case ERX_INFO_MACHINE:
		report.machine.cpus_online = (uint32_t)__builtin_popcountll(facts->cpus_online);
		report.machine.reported = facts->cpus_online != 0 ? ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE : 0;
		break;
	case ERX_INFO_CPU:
		if (index >= 64 || (facts->cpus_online >> index & 1) == 0)
			return (ERX_ERANGE);
		break;
	case ERX_INFO_GROUP:
		report.group = facts->group;
		break;
	case ERX_INFO_BUDGET:
		report.budget.used = facts->budget_used;
		break;
	case ERX_INFO_THREAD:
		if (!nth_thread(facts->threads, index, &id))
			return (ERX_ERANGE);
		report.thread.id = id;
		break;
	}
	bcopy(&report, window, (size_t)bytes);
	return (ERX_OK);
}
