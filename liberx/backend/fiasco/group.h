/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_GROUP_H
#define ERX_FIASCO_GROUP_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * Interrupts and readiness (docs/design-stopgap.md, "Interrupts and readiness"):
 * the task's group, its dispatcher, and the IRQ objects bound to it. An object's
 * handle is its index in the service's table.
 */

/*
 * Starts the dispatcher of the task's one group and returns the group's handle. A
 * second create is ERX_ELIMIT, and budget and parent are ignored: a recorded difference.
 */
int	erx_group_create(uint64_t budget, uint64_t parent, uint64_t *group) ERX_WARN_UNUSED_RESULT;

/*
 * Writes up to max listed objects' labels, at most ERX_MSG_WORDS, into the caller's
 * public UTCB and returns how many, each object once however often it fired. Never
 * blocks. A worker is ERX_ETYPE.
 */
int	erx_group_take_ready(uint32_t max) ERX_WARN_UNUSED_RESULT;

/*
 * kind is ERX_IRQ_SOFT, or ERX_IRQ_LINE with selector the line. budget and
 * resource are ignored. A line already taken is ERX_EBUSY.
 */
int	erx_irq_create(uint64_t budget, uint64_t resource, uint64_t kind, uint64_t selector,
	    uint64_t *irq) ERX_WARN_UNUSED_RESULT;
/*
 * Binds the object to the group with the label its deliveries report, and lets a
 * line deliver. Binding an object twice is ERX_ENOTSUP.
 */
int	erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label) ERX_WARN_UNUSED_RESULT;
/* Lets a line deliver again, which it does not after a delivery until this call. */
int	erx_irq_ack(uint64_t irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_trigger(uint64_t irq) ERX_WARN_UNUSED_RESULT;

/* The calls' bodies, on the service. */
int	erx_fiasco_irq_create_body(uint64_t kind, uint64_t selector, uint64_t *irq);
int	erx_fiasco_irq_bind_body(uint64_t irq, uint64_t thread, uint64_t record);
int	erx_fiasco_irq_ack_body(uint64_t irq);
int	erx_fiasco_irq_trigger_body(uint64_t irq);

#ifdef ERX_FIASCO_TEST_HOOKS
/*
 * Maps a page of device registers at virt, on the first thread. The suite's stand-in
 * for erx_mem_create_physical, the device NIF's call. Returns sigma0's status.
 */
int	erx_fiasco_test_map_device(uint64_t phys, uint64_t virt);
#endif

#endif /* ERX_FIASCO_GROUP_H */
