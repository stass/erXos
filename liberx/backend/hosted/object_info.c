/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_object_info in a macOS process (docs/design-stopgap.md, "Reporting kernel
 * objects"): the same handles, refusals and reported bits as the Fiasco backend, from
 * the hosted backend's own tables. There is one space, the process, so the budget and
 * thread topics take ERX_CAP_SELF alone.
 */

#include <stdint.h>
#include <unistd.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/group_report.h"
#include "liberx/backend/core/object_info.h"
#include "liberx/backend/hosted/internal.h"

/* The host's online CPUs as a map, 0 when the host does not say. */
static uint64_t
host_cpus_online(void)
{
	const long cpus = sysconf(_SC_NPROCESSORS_ONLN);

	if (cpus <= 0)
		return (0);
	return (cpus >= 64 ? UINT64_MAX : (UINT64_C(1) << cpus) - 1);
}

int
erx_object_info(uint64_t object, uint32_t topic, uint64_t index, void *window, uint64_t size)
{
	erx_info_facts_t facts = { 0 };

	switch (topic) {
	case ERX_INFO_MACHINE:
	case ERX_INFO_CPU:
		facts.cpus_online = host_cpus_online();
		break;
	case ERX_INFO_GROUP:
		if (erx_group_info(object) != ERX_OK)
			return (ERX_ENOTSUP);
		facts.group = erx_info_group_load(erx_utcb_self());
		break;
	case ERX_INFO_BUDGET:
		if (object != ERX_CAP_SELF)
			return (ERX_ENOTSUP);
		facts.budget_used = erx_hosted_vm_used_pages();
		break;
	case ERX_INFO_THREAD:
		if (object != ERX_CAP_SELF)
			return (ERX_ENOTSUP);
		erx_hosted_thread_map(facts.threads);
		break;
	}
	return (erx_info_report(topic, index, &facts, window, size));
}
