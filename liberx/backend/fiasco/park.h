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
 * The task's one group of executors, over the park core (docs/design-stopgap.md,
 * "The park protocol"). Every thread of the task belongs to this group; group.c
 * holds its dispatcher and its objects' labels.
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

/* A worker is ERX_ETYPE. ERX_OK when woken or an epoch moved, ERX_ETIMEDOUT at the deadline. */
int	erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline) ERX_WARN_UNUSED_RESULT;
/* An empty slot is ERX_EINVAL. */
int	erx_executor_wake(uint32_t slot) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_PARK_H */
