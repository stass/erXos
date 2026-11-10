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
 * moves from here to its stub in service_stubs.c.
 */

#include <stddef.h>
#include <stdint.h>

#include <stdbool.h>

#include "erx/abi.h"
#include "erx/dom_lib.h"
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

int
erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label)
{
	(void)irq;
	(void)group;
	(void)label;
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

/*
 * The domain library is the system domain's alone: a domain's runtime links the
 * erx_domain_lib NIF module like every ERTS, and here it finds no library, so the
 * module loads inert and answers {error, enotsup}. Only erx_dom_lib_system is ever
 * called; the rest answer ERX_ENOTSUP so the link resolves.
 */
erx_dom_lib_t *
erx_dom_lib_system(void)
{
	return (NULL);
}

erx_status_t
erx_dom_lib_create(erx_dom_lib_t *lib, const erx_dom_spec_t *req, const erx_runtime_limits_t *limits,
    uint32_t given, erx_dom_created_t *created)
{
	(void)lib, (void)req, (void)limits, (void)given, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_configured(erx_dom_lib_t *lib, uint32_t id, uint32_t row, erx_dom_pid_t domain_pid,
    erx_dom_created_t *created)
{
	(void)lib, (void)id, (void)row, (void)domain_pid, (void)created;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_start(erx_dom_lib_t *lib, uint32_t id)
{
	(void)lib, (void)id;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_stop(erx_dom_lib_t *lib, uint32_t id, int64_t status)
{
	(void)lib, (void)id, (void)status;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_connect(erx_dom_lib_t *lib, uint32_t a, uint32_t b, uint32_t a_reads, uint32_t b_reads,
    erx_dom_linked_t *linked)
{
	(void)lib, (void)a, (void)b, (void)a_reads, (void)b_reads, (void)linked;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_disconnect(erx_dom_lib_t *lib, uint32_t number)
{
	(void)lib, (void)number;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_retire(erx_dom_lib_t *lib, uint32_t id)
{
	(void)lib, (void)id;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_crash_copy(erx_dom_lib_t *lib, uint32_t id, uint64_t dst)
{
	(void)lib, (void)id, (void)dst;
	return (ERX_ENOTSUP);
}

erx_status_t
erx_dom_lib_take(uint64_t wait_by, uint64_t *label, erx_fault_t *record)
{
	(void)wait_by, (void)label, (void)record;
	return (ERX_ENOTSUP);
}

bool
erx_dom_lib_record(erx_dom_lib_t *lib, uint64_t label, const erx_fault_t *record, erx_dom_report_t *report)
{
	(void)lib, (void)label, (void)record, (void)report;
	return (false);
}
