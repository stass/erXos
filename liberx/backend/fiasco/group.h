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
 * stubs of the group and IRQ calls. An IRQ object's handle is its index in the
 * service's table.
 */

/* What erx_fiasco_group_admit gives for a thread that names no group. */
#define ERX_FIASCO_GROUP_NONE	UINT32_MAX

/*
 * Makes a group record with no home and returns its handle; only the root makes one,
 * so a task is ERX_ENOTSUP. The root's first also starts the root's dispatcher in it,
 * which makes it the root's own group. parent is ignored: a recorded difference.
 */
int	erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group) ERX_WARN_UNUSED_RESULT;

/*
 * Writes up to max listed objects' labels, at most ERX_MSG_WORDS, into the caller's
 * public UTCB and returns how many, each object once however often it fired. Never
 * blocks. A worker is ERX_ETYPE. Local to the home task (park.c).
 */
int	erx_group_take_ready(uint32_t max) ERX_WARN_UNUSED_RESULT;

/* The service's group bodies. erx_group_create's: a task is ERX_ENOTSUP. */
int	erx_fiasco_group_create_body(uint32_t task, uint64_t budget, uint64_t *group);
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
/* The release of a record that ends: its home, if any, is a home no more. */
void	erx_fiasco_group_free(uint32_t record);
/* Names the task's dispatcher, one of its own threads, once; a second is ERX_EINVAL. */
int	erx_fiasco_dispatcher_set_body(uint32_t task, uint64_t thread);

/*
 * kind is ERX_IRQ_SOFT, or ERX_IRQ_LINE with selector the line. budget and
 * resource are ignored. A line the kernel will not attach, taken or not there, is ERX_EBUSY.
 */
int	erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector,
	    uint64_t *irq) ERX_WARN_UNUSED_RESULT;
/*
 * Binds the object to the group with the label its deliveries report, and lets a line
 * deliver. Binding a bound object moves its label; a group of ERX_CAP_NULL unbinds it.
 */
int	erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label) ERX_WARN_UNUSED_RESULT;
/* Lets a line deliver again, which it does not after a delivery until this call. */
int	erx_irq_ack(uint64_t irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_trigger(uint64_t irq) ERX_WARN_UNUSED_RESULT;

/* The calls' bodies, on the service. */
int	erx_fiasco_irq_create_body(uint64_t kind, uint64_t selector, uint64_t *irq);
int	erx_fiasco_irq_bind_body(uint64_t irq, uint64_t thread, uint64_t record);
int	erx_fiasco_irq_unbind_body(uint64_t irq);
int	erx_fiasco_irq_ack_body(uint64_t irq);
int	erx_fiasco_irq_trigger_body(uint64_t irq);

#endif /* ERX_FIASCO_GROUP_H */
