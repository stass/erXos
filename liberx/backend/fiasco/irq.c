/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The IRQ calls' bodies, on the service, which alone touches this table
 * (docs/design-stopgap.md, "Interrupts and readiness"). An IRQ object is an object
 * record of kind IRQ, any task's to make as a doorbell and the root's alone as a line,
 * and any holder's to trigger, ack and bind; its kernel object sits in one of the root's
 * slots, kept here with its bind. The root binds
 * into any group it holds, as the domain library binds a domain's bell, and the root's own
 * drivers their lines; another holder binds only within the group it is the home of
 * (irq_group_allowed).
 *
 * A bind gives the object a free entry of its group, one of the 64 the group's home
 * task has labels for, stores the caller's label on the home's label page through the
 * window, and only then binds the object to the home's dispatcher with the entry as
 * Fiasco's label, so a delivery never reaches an entry before its label. Until the
 * group has a home with a dispatcher the bind waits, and group.c makes it once both
 * exist; a software fire before then arrives at the bind, as Fiasco keeps it for a
 * detached object. A bind goes with its group, whose end detaches the object. A bound
 * line stays masked from each delivery until its ack, which is Fiasco's own behaviour
 * for a level interrupt.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/icu.h>
#include <l4/sys/irq.h>
#include <l4/sys/rcv_endpoint.h>
#include <l4/sys/task.h>

#include "liberx/backend/core/handles.h"
#include "liberx/backend/core/park_table.h"
#include "liberx/backend/core/vm_table.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

/* What a slot's group holds while the object is bound to none. */
#define IRQ_UNBOUND	0u

/* One kernel object and its bind. */
typedef struct irq_object {
	uint32_t	record;	/* the object record's index plus one, 0 for a free slot */
	uint32_t	group;	/* the group record's index plus one, or IRQ_UNBOUND */
	uint32_t	entry;	/* its entry in the group, while bound */
	bool		made;	/* bound to the home's dispatcher, not waiting */
	uint64_t	label;	/* the caller's, which the home's label page holds once made */
} irq_object_t;

static irq_object_t irq_objects[ERX_FIASCO_IRQS_MAX];

static l4_cap_idx_t
irq_cap(const irq_object_t *object)
{
	return ((l4_cap_idx_t)erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_IRQS + (uint32_t)(object - irq_objects)));
}

/* The slot an IRQ record's object is in: every live IRQ record has one. */
static irq_object_t *
irq_of(uint32_t record)
{
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].record == record + 1)
			return (&irq_objects[slot]);
	return (NULL);
}

/* The object a task's handle names, or the lookup's refusal. */
static int
irq_named(uint32_t task, uint64_t irq, irq_object_t **object)
{
	uint32_t record;
	const int status = erx_fiasco_object_find(task, irq, ERX_BACKEND_OBJECT_IRQ, &record);

	if (status != ERX_OK)
		return (status);
	*object = irq_of(record);
	return (*object != NULL ? ERX_OK : ERX_ESTALE);
}

/*
 * Stores label as the entry's on the home task's label page, through the window, with
 * release order; ERX_EINVAL when the task has given up the page.
 */
static int
irq_label_store(uint32_t home, uint32_t entry, uint64_t label)
{
	const uint64_t addr = (uint64_t)(uintptr_t)&erx_fiasco_labels()[entry];
	const uintptr_t window = erx_fiasco_vm_task_window(home, addr & ~ERX_BACKEND_VM_PAGE_MASK);

	if (window == 0)
		return (ERX_EINVAL);
	atomic_store_explicit((_Atomic uint64_t *)(window + (uintptr_t)(addr & ERX_BACKEND_VM_PAGE_MASK)), label,
	    memory_order_release);
	return (ERX_OK);
}

/* The lowest entry of the group record no object holds, or ERX_BACKEND_PARK_OBJECTS_MAX when all do. */
static uint32_t
irq_free_entry(uint32_t group)
{
	uint64_t used = 0;

	_Static_assert(ERX_BACKEND_PARK_OBJECTS_MAX == 64, "a group's entries fill one word");
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].group == group + 1)
			used |= UINT64_C(1) << irq_objects[slot].entry;
	return (used == UINT64_MAX ? ERX_BACKEND_PARK_OBJECTS_MAX : (uint32_t)__builtin_ctzll(~used));
}

/*
 * Tries to make a waiting bind: once its group has a home with a dispatcher, stores
 * the label, binds the object to the dispatcher and lets a line deliver, setting made.
 * Before then the bind keeps waiting, made stays false, and the result is ERX_OK; a
 * refusal of the label page or of the kernel's bind is ERX_EINVAL.
 */
static int
irq_try_make(irq_object_t *object)
{
	uint32_t home, dispatcher;

	if (!erx_fiasco_task_group_home(object->group - 1, &home) || erx_fiasco_task(home)->dispatcher == 0)
		return (ERX_OK);
	dispatcher = erx_fiasco_task(home)->dispatcher - 1;
	if (irq_label_store(home, object->entry, object->label) != ERX_OK)
		return (ERX_EINVAL);
	if (l4_error(l4_rcv_ep_bind_thread(irq_cap(object), (l4_cap_idx_t)erx_fiasco_task_thread_cap(home, dispatcher),
	    object->entry)) < 0)
		return (ERX_EINVAL);
	object->made = true;
	(void)l4_irq_unmask(irq_cap(object));
	return (ERX_OK);
}

/*
 * The bind goes: Fiasco masks a line it detaches, and owes a software object's later
 * fire to the next bind. The entry's label is cleared first, so a delivery still
 * listed under it reports 0, which names no sink.
 */
static void
irq_unbind(irq_object_t *object)
{
	uint32_t home;

	if (object->made) {
		if (erx_fiasco_task_group_home(object->group - 1, &home))
			(void)irq_label_store(home, object->entry, 0);
		(void)l4_irq_detach(irq_cap(object));
	}
	object->group = IRQ_UNBOUND;
	object->made = false;
}

/* The record's object, in the lowest free slot: a line's is attached to it here. */
static int
irq_fill(uint32_t record, const void *argument)
{
	const erx_fiasco_irq_create_request_t *const request = argument;
	irq_object_t *object = irq_objects;

	while (object < irq_objects + ERX_FIASCO_IRQS_MAX && object->record != 0)
		object++;
	if (object == irq_objects + ERX_FIASCO_IRQS_MAX ||
	    l4_error(l4_factory_create_irq(L4_BASE_FACTORY_CAP, irq_cap(object))) < 0)
		return (ERX_ENOMEM);
	if (request->kind == ERX_IRQ_LINE &&
	    l4_error(l4_icu_bind(L4_BASE_ICU_CAP, (unsigned)request->selector, irq_cap(object))) < 0) {
		(void)l4_task_delete_obj(L4_BASE_TASK_CAP, irq_cap(object));
		return (ERX_EBUSY);
	}
	*object = (irq_object_t){ .record = record + 1 };
	return (ERX_OK);
}

int
erx_fiasco_irq_create_body(uint32_t task, const erx_fiasco_irq_create_request_t *request, uint64_t *irq)
{
	/* MSI is not offered, and a line is the root's alone. */
	if (request->kind == ERX_IRQ_MSI || (task != ERX_FIASCO_TASK_ROOT && request->kind == ERX_IRQ_LINE))
		return (ERX_ENOTSUP);
	if ((request->kind != ERX_IRQ_SOFT && request->kind != ERX_IRQ_LINE) || request->selector > UINT32_MAX)
		return (ERX_EINVAL);
	return (erx_fiasco_object_create(task, ERX_BACKEND_OBJECT_IRQ, request->budget, irq_fill, request, irq));
}

/*
 * Whether the task may bind into the group record, or move or unbind an object bound
 * there: the root in any group it holds, and any other task only in the group it is the
 * home of (docs/design-stopgap.md, "Device records"), so a holder's driver binds the
 * line it was given to its own group and reaches no other domain's. A task's row names
 * the one group it is the home of (group.c), and the caller's row is live.
 */
static bool
irq_group_allowed(uint32_t task, uint32_t group)
{
	return (task == ERX_FIASCO_TASK_ROOT || erx_fiasco_task(task)->group == group + 1);
}

/* ERX_CAP_SELF names the caller's home group, which the root's first group is for the root. */
static int
irq_group_named(uint32_t task, uint64_t group, uint32_t *record)
{
	if (group != ERX_CAP_SELF)
		return (erx_fiasco_object_find(task, group, ERX_BACKEND_OBJECT_GROUP, record));
	if (erx_fiasco_task(task)->group == 0)
		return (ERX_EINVAL);
	*record = erx_fiasco_task(task)->group - 1;
	return (ERX_OK);
}

int
erx_fiasco_irq_bind_body(uint32_t task, const erx_fiasco_irq_bind_request_t *request)
{
	irq_object_t *object;
	uint32_t group, entry, home;
	int status;

	status = irq_named(task, request->irq, &object);
	if (status == ERX_OK)
		status = irq_group_named(task, request->group, &group);
	if (status != ERX_OK)
		return (status);
	/* The target, and the group a bound object is in, must both be the caller's to name. */
	if (!irq_group_allowed(task, group) || (object->group != IRQ_UNBOUND && !irq_group_allowed(task, object->group - 1)))
		return (ERX_ETYPE);
	if (object->group != IRQ_UNBOUND) {
		/* A move changes only the label a later take reads: the dispatcher stays its receiver. */
		if (object->group != group + 1)
			return (ERX_ENOTSUP);
		if (object->made && erx_fiasco_task_group_home(group, &home)) {
			status = irq_label_store(home, object->entry, request->label);
			if (status != ERX_OK)
				return (status);
		}
		object->label = request->label;
		return (ERX_OK);
	}
	entry = irq_free_entry(group);
	if (entry == ERX_BACKEND_PARK_OBJECTS_MAX)
		return (ERX_ELIMIT);
	*object = (irq_object_t){ .record = object->record, .group = group + 1, .entry = entry, .label = request->label };
	status = irq_try_make(object);
	if (status != ERX_OK)
		irq_unbind(object);
	return (status);
}

int
erx_fiasco_irq_unbind_body(uint32_t task, uint64_t irq)
{
	irq_object_t *object;
	int status = irq_named(task, irq, &object);

	if (status == ERX_OK && object->group != IRQ_UNBOUND && !irq_group_allowed(task, object->group - 1))
		status = ERX_ETYPE;
	if (status == ERX_OK)
		irq_unbind(object);
	return (status);
}

int
erx_fiasco_irq_ack_body(uint32_t task, uint64_t irq)
{
	irq_object_t *object;
	const int status = irq_named(task, irq, &object);

	/* An object not bound has no receiver: its bind is what opens it. */
	if (status == ERX_OK && object->made)
		(void)l4_irq_unmask(irq_cap(object));
	return (status);
}

int
erx_fiasco_irq_trigger_body(uint32_t task, uint64_t irq)
{
	irq_object_t *object;
	const int status = irq_named(task, irq, &object);

	if (status == ERX_OK)
		(void)l4_irq_trigger(irq_cap(object));
	return (status);
}

void
erx_fiasco_irq_free(uint32_t record)
{
	irq_object_t *const object = irq_of(record);

	if (object == NULL)
		return;
	irq_unbind(object);
	(void)l4_task_delete_obj(L4_BASE_TASK_CAP, irq_cap(object));
	*object = (irq_object_t){ 0 };
}

/* A bind the kernel refuses here has no caller to tell, so it goes, leaving the object unbound. */
void
erx_fiasco_irq_group_ready(uint32_t record)
{
	for (irq_object_t *object = irq_objects; object < irq_objects + ERX_FIASCO_IRQS_MAX; object++) {
		if (object->group != record + 1 || object->made)
			continue;
		if (irq_try_make(object) != ERX_OK)
			irq_unbind(object);
	}
}

void
erx_fiasco_irq_group_end(uint32_t record)
{
	for (uint32_t slot = 0; slot < ERX_FIASCO_IRQS_MAX; slot++)
		if (irq_objects[slot].group == record + 1)
			irq_unbind(&irq_objects[slot]);
}
