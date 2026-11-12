/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_GROUP_H
#define ERX_FIASCO_GROUP_H

#include <stdint.h>

#include <stdbool.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * Groups as records and interrupts (docs/design-stopgap.md, "Budgets and groups as
 * records", "Interrupts and readiness"): the service's group records, and the root's
 * stubs of the group and IRQ calls. An IRQ object is an object record, which handles
 * name as they name every other.
 */

/* What erx_fiasco_group_admit gives for a thread that names no group. */
#define ERX_FIASCO_GROUP_NONE	UINT32_MAX

/*
 * Makes a group record with no home and returns its handle, from any task (the root's
 * stub in group.c, a task's in task_start.c). The root's first also starts the root's
 * dispatcher in it, which makes it the root's own group. parent is ignored: a recorded difference.
 */
int	erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group) ERX_WARN_UNUSED_RESULT;

/*
 * Writes up to max listed objects' labels, at most ERX_MSG_WORDS, into the caller's
 * public UTCB and returns how many, each object once however often it fired. Never
 * blocks. A worker is ERX_ETYPE. Local to the home task (park.c).
 */
int	erx_group_take_ready(uint32_t max) ERX_WARN_UNUSED_RESULT;

/* The service's group bodies. */
int	erx_fiasco_group_create_body(uint32_t task, uint64_t budget, uint64_t *group);
/*
 * erx_group_configure on a group the root did not take as its own: a handle that names
 * no group of task's is the lookup's refusal, an empty CPU set ERX_EINVAL; the grant is
 * otherwise accepted and not kept, since nothing in the stopgap reads it.
 */
int	erx_fiasco_group_configure_body(uint32_t task, const erx_fiasco_group_configure_request_t *request);
/*
 * Before a thread's kernel objects: the record of the group a thread created in task by
 * caller joins, or ERX_FIASCO_GROUP_NONE for ERX_CAP_NULL, which names none. A group
 * homed in another task, or a homeless one while task is another group's home, is
 * ERX_ENOTSUP; a handle that names no group of the caller's, the lookup's refusal.
 */
int	erx_fiasco_group_admit(uint32_t caller, uint32_t task, uint64_t group, uint32_t *record);
/* Once the thread exists: makes task the home of what admit gave. */
void	erx_fiasco_group_join(uint32_t task, uint32_t record);
/*
 * Whether the record's home task has any thread; always so for the root. Such a group
 * outlives its handles and refuses its destroy, and goes with its home.
 */
bool	erx_fiasco_group_home_has_threads(uint32_t record);
/* The release of a record that ends: its binds go, and its home, if any, is a home no more. */
void	erx_fiasco_group_free(uint32_t record);
/* Names the task's dispatcher, one of its own threads, once; a second is ERX_EINVAL. */
int	erx_fiasco_dispatcher_set_body(uint32_t task, uint64_t thread);

/*
 * IRQ objects (docs/design-stopgap.md, "Interrupts and readiness"): kind is
 * ERX_IRQ_SOFT, a doorbell, which any task makes, or ERX_IRQ_LINE with selector the line,
 * which only the root makes, and resource is ignored. A line the kernel will not attach,
 * taken or not there, is ERX_EBUSY; an object past the machine's ERX_FIASCO_IRQS_MAX,
 * ERX_ENOMEM; a task's line or any MSI, ERX_ENOTSUP.
 */
int	erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector,
	    uint64_t *irq) ERX_WARN_UNUSED_RESULT;
/*
 * Binds the object to the group, or ERX_CAP_SELF for the caller's home, with the label
 * its deliveries report, and lets a line deliver. A bind waits until the group has a
 * home with a dispatcher. Binding a bound object to its group again moves its label; to
 * another group, ERX_ENOTSUP. A group's 65th object is ERX_ELIMIT. A group of ERX_CAP_NULL
 * unbinds it. A task other than the root names only the group it is the home of or a
 * group it created, as the target and as the group a bound object is in, and any other
 * is ERX_ETYPE.
 */
int	erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label) ERX_WARN_UNUSED_RESULT;
/* From any task holding the object. An ack lets a line deliver again, which it does not after a delivery until then. */
int	erx_irq_ack(uint64_t irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_trigger(uint64_t irq) ERX_WARN_UNUSED_RESULT;

/* The calls' bodies, on the service, for the calling task. */
int	erx_fiasco_irq_create_body(uint32_t task, const erx_fiasco_irq_create_request_t *request, uint64_t *irq);
int	erx_fiasco_irq_bind_body(uint32_t task, const erx_fiasco_irq_bind_request_t *request);
int	erx_fiasco_irq_unbind_body(uint32_t task, uint64_t irq);
int	erx_fiasco_irq_ack_body(uint32_t task, uint64_t irq);
int	erx_fiasco_irq_trigger_body(uint32_t task, uint64_t irq);
/* What an IRQ record's end gives back: its bind goes, then its kernel object. */
void	erx_fiasco_irq_free(uint32_t record);
/* Makes every waiting bind to the group record once its home and the home's dispatcher both exist. */
void	erx_fiasco_irq_group_ready(uint32_t record);
/* A group's end: every bind to it goes, so its objects stay, unbound. */
void	erx_fiasco_irq_group_end(uint32_t record);

#endif /* ERX_FIASCO_GROUP_H */
