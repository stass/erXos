/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PARK_H
#define ERX_FIASCO_PARK_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/core/park_table.h"

/*
 * The task's park record, over the park core (docs/design-stopgap.md, "The park
 * protocol"): the readiness of the task's one home group, whose executors are the
 * task's, with its dispatcher and its entries' labels.
 */

/* A slot for the thread of this index, or ERX_BACKEND_PARK_NO_SLOT when the group is full. */
uint32_t	erx_fiasco_executor_claim(uint32_t index);
void		erx_fiasco_executor_release(uint32_t slot);

/* The page the epochs are mirrored in: an executor reads them before its empty check. */
const erx_group_stat_t *erx_fiasco_group_status(void);

/*
 * Starts the thread of park_report.c, which writes a line to the console each time the page's
 * count of parked executors or of executors changes. The root's program calls it once, under
 * erx.group_report=1. Returns NULL, or why it could not.
 */
const char	*erx_fiasco_park_report_start(void);

/* The epoch advances and the longest parked wakes. */
void		erx_fiasco_group_trigger(void);
/* What the dispatcher runs for an object's delivery: it lists the object, then as a trigger. */
void		erx_fiasco_group_signal(uint32_t object);
/* Moves up to max listed objects into objects, oldest first, and returns how many. */
uint32_t	erx_fiasco_group_take(uint32_t max, uint32_t *objects);

/*
 * Starts the task's dispatcher, a worker created in group (ERX_CAP_NULL, which names no
 * record, for a task's), and names it to the service: once per task, at its backend's
 * start, or the root's with its first group. A second is ERX_EINVAL. Once the thread
 * is made a later refusal leaves it, idle, and the call is not retried.
 */
int	erx_fiasco_dispatcher_start(uint64_t group, uint64_t *thread) ERX_WARN_UNUSED_RESULT;

/* A worker is ERX_ETYPE. ERX_OK when woken or an epoch moved, ERX_ETIMEDOUT at the deadline. */
int	erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline) ERX_WARN_UNUSED_RESULT;
/* An empty slot is ERX_EINVAL. */
int	erx_executor_wake(uint32_t slot) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_PARK_H */
