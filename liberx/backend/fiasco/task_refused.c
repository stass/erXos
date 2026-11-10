/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The calls of ERTS's link that a task's program has no service answer for, so a
 * domain's runtime image (NativeRoot::DOMAIN_RUNTIME) links: each refuses or reports
 * its value unavailable, as the call table answers a call it does not offer
 * (docs/design-stopgap.md, "The call table"). The root's own bodies in group.c,
 * irq.c, time_page.c, vm.c, watchdog_thread.c and runtime_entry.c read the root's
 * tables, which a task does not hold. A call the service comes to serve a task
 * moves from here to its stub in service_stubs.c. The domain library's entries,
 * which a task finds none of, are liberx/backend/core/dom_lib_none.c's.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/vm.h"

int
erx_object_info(uint64_t object, uint32_t topic, uint64_t index, void *window, uint64_t size)
{
	(void)object;
	(void)topic;
	(void)index;
	(void)window;
	(void)size;
	return (ERX_ENOTSUP);
}

int
erx_group_info(uint64_t group)
{
	(void)group;
	return (ERX_ENOTSUP);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	(void)budget;
	(void)resource;
	(void)kind;
	(void)selector;
	(void)irq;
	return (ERX_ENOTSUP);
}

/* The machine's watchdog is the system domain's to pet, and no other's. */
int
erx_watchdog_pet(void)
{
	return (ERX_ENOTSUP);
}

/*
 * A task counts no pool, so it can promise no page beyond those it has committed:
 * erx_vm_free_pages reports none, the one answer that is never more than it can
 * commit.
 */
uint64_t
erx_fiasco_vm_free_pages(void)
{
	return (0);
}

