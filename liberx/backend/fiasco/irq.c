/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The IRQ calls' bodies, on the service, which alone touches this table: the kernel's
 * IRQ objects, each bound to a dispatcher with its record in the group as the kernel's
 * label. A bound line stays masked from each delivery until its ack, which is Fiasco's
 * own behaviour for a level interrupt.
 */

#include <stdbool.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/icu.h>
#include <l4/sys/irq.h>
#include <l4/sys/rcv_endpoint.h>
#include <l4/sys/task.h>

#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/thread.h"

#define IRQ_OBJECTS_MAX		ERX_BACKEND_PARK_OBJECTS_MAX

typedef struct irq_object {
	bool	present;
	bool	bound;
} irq_object_t;

static irq_object_t irq_objects[IRQ_OBJECTS_MAX];

static l4_cap_idx_t
irq_cap(uint32_t index)
{
	return ((l4_cap_idx_t)erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_IRQS + index));
}

int
erx_fiasco_irq_create_body(uint64_t kind, uint64_t selector, uint64_t *irq)
{
	uint32_t index = 0;

	if (kind == ERX_IRQ_MSI)
		return (ERX_ENOTSUP);
	if ((kind != ERX_IRQ_SOFT && kind != ERX_IRQ_LINE) || selector > UINT32_MAX)
		return (ERX_EINVAL);
	while (index < IRQ_OBJECTS_MAX && irq_objects[index].present)
		index++;
	if (index == IRQ_OBJECTS_MAX || l4_error(l4_factory_create_irq(L4_BASE_FACTORY_CAP, irq_cap(index))) < 0)
		return (ERX_ENOMEM);
	if (kind == ERX_IRQ_LINE &&
	    l4_error(l4_icu_bind(L4_BASE_ICU_CAP, (unsigned)selector, irq_cap(index))) < 0) {
		(void)l4_task_delete_obj(L4_BASE_TASK_CAP, irq_cap(index));
		return (ERX_EBUSY);
	}
	irq_objects[index].present = true;
	*irq = index;
	return (ERX_OK);
}

int
erx_fiasco_irq_bind_body(uint64_t irq, uint64_t thread, uint64_t record)
{
	if (irq >= IRQ_OBJECTS_MAX || !irq_objects[irq].present || thread >= ERX_FIASCO_THREADS_MAX ||
	    record >= IRQ_OBJECTS_MAX)
		return (ERX_EINVAL);
	if (irq_objects[irq].bound)
		return (ERX_ENOTSUP);
	if (l4_error(l4_rcv_ep_bind_thread(irq_cap((uint32_t)irq), (l4_cap_idx_t)erx_fiasco_thread_cap((uint32_t)thread),
	    record)) < 0)
		return (ERX_EINVAL);
	irq_objects[irq].bound = true;
	(void)l4_irq_unmask(irq_cap((uint32_t)irq));
	return (ERX_OK);
}

int
erx_fiasco_irq_ack_body(uint64_t irq)
{
	if (irq >= IRQ_OBJECTS_MAX || !irq_objects[irq].bound)
		return (ERX_EINVAL);
	(void)l4_irq_unmask(irq_cap((uint32_t)irq));
	return (ERX_OK);
}

int
erx_fiasco_irq_trigger_body(uint64_t irq)
{
	if (irq >= IRQ_OBJECTS_MAX || !irq_objects[irq].present)
		return (ERX_EINVAL);
	(void)l4_irq_trigger(irq_cap((uint32_t)irq));
	return (ERX_OK);
}

#ifdef ERX_FIASCO_TEST_HOOKS
int
erx_fiasco_test_map_device(uint64_t phys, uint64_t virt)
{
	return (l4sigma0_map_iomem(L4_BASE_PAGER_CAP, (l4_addr_t)phys, (l4_addr_t)virt, L4_PAGESIZE, 0));
}
#endif
