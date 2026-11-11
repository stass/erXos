/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The reports of erx_object_info on liberx's Phase 1 backends, and the fields they
 * count only partly (docs/design-stopgap.md, "Reporting kernel objects"). Per topic:
 *
 *   machine  build and boot_value, the boot handoff's, reported when the backend has one;
 *            cpus_online, the count of the kernel's map, reported when the map is known;
 *            uptime, the kernel's clock, reported when it is known; memory_total and
 *            memory_free, the root's pool's pages in bytes, never reported:
 *            erx_info_partial names them, since RAM outside the pool is not counted
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
	switch (topic) {
	case ERX_INFO_MACHINE:
		return (ERX_INFO_MACHINE_REPORTED_MEMORY_TOTAL | ERX_INFO_MACHINE_REPORTED_MEMORY_FREE);
	case ERX_INFO_BUDGET:
		return (ERX_INFO_BUDGET_REPORTED_USED);
	default:
		return (0);
	}
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
		report.machine.uptime = facts->uptime_ns;
		/* A product that does not fit leaves the field 0, which a partial reader sees as such. */
		if (__builtin_mul_overflow(facts->pool_pages, (uint64_t)ERX_PAGE_SIZE, &report.machine.memory_total) ||
		    __builtin_mul_overflow(facts->pool_free_pages, (uint64_t)ERX_PAGE_SIZE, &report.machine.memory_free))
			report.machine.memory_total = report.machine.memory_free = 0;
		report.machine.reported = (facts->cpus_online != 0 ? ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE : 0) |
		    (facts->uptime_ns != 0 ? ERX_INFO_MACHINE_REPORTED_UPTIME : 0);
		if (facts->boot_known) {
			bcopy(facts->build, report.machine.build, sizeof(report.machine.build));
			report.machine.boot_value = facts->boot_value;
			report.machine.reported |= ERX_INFO_MACHINE_REPORTED_BUILD | ERX_INFO_MACHINE_REPORTED_BOOT_VALUE;
		}
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
