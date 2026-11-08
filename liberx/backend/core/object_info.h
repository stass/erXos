/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_CORE_OBJECT_INFO_H
#define ERX_BACKEND_CORE_OBJECT_INFO_H

#include <stdint.h>

#include "erx/abi.h"

/*
 * erx_object_info's reports on liberx's Phase 1 backends (docs/design-stopgap.md,
 * "Reporting kernel objects"), the same on both. A backend gathers what it knows into
 * facts, from its own tables and never from a task's memory, and this core writes the
 * topic's report from them: a reported bit is set only for a field the backend has
 * with the attribute's full meaning. The core reads nothing else, so it builds for the
 * host.
 */

/* What the backend knows when it answers. Each topic reads only its own facts. */
typedef struct erx_info_facts {
	uint64_t		cpus_online;	/* machine, cpu: the kernel's map, 0 when it did not say */
	uint64_t		uptime_ns;	/* machine: the kernel's clock since boot, 0 when it did not say */
	uint64_t		pool_pages;	/* machine: the pages the root's pool was built with */
	uint64_t		pool_free_pages; /* machine: those of them it holds now */
	uint64_t		budget_used;	/* budget: the pages the pool handed out and has not taken back */
	uint64_t		threads[2];	/* thread: bit n, thread n of the space is created or started */
	erx_info_group_t	group;		/* group: the report erx_group_info wrote */
} erx_info_facts_t;

/* The bytes a topic's report takes, or 0 for a topic with no report of its own. */
uint64_t	erx_info_report_size(uint32_t topic);

/*
 * Writes the topic's report for index into the window of size bytes, the report's
 * bytes alone. basic and image entry are ERX_ENOTSUP, an unknown topic, a NULL window
 * or one shorter than the report ERX_EINVAL, and a CPU outside the map or a thread
 * index past the last ERX_ERANGE, which ends a listing. Nothing is written on a refusal.
 */
int	erx_info_report(uint32_t topic, uint64_t index, const erx_info_facts_t *facts, void *window,
	    uint64_t size);

#endif /* ERX_BACKEND_CORE_OBJECT_INFO_H */
