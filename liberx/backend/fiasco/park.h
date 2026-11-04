/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PARK_H
#define ERX_FIASCO_PARK_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "liberx/backend/fiasco/park_table.h"

/*
 * The task's one group of executors, over the park core (docs/design-stopgap.md,
 * "The park protocol"). A group's creation, its dispatcher and its ready ring come
 * with their consumers; every thread of the task belongs to this group.
 */

/* A slot for the thread of this index, or ERX_FIASCO_PARK_NO_SLOT when the group is full. */
uint32_t	erx_fiasco_executor_claim(uint32_t index);
void		erx_fiasco_executor_release(uint32_t slot);

/* The page the epochs are mirrored in: an executor reads them before its empty check. */
const erx_group_stat_t *erx_fiasco_group_status(void);

/* What the dispatcher runs for an object's delivery: the epoch advances and the longest parked wakes. */
void		erx_fiasco_group_trigger(void);

/* A worker is ERX_ETYPE. ERX_OK when woken or an epoch moved, ERX_ETIMEDOUT at the deadline. */
int	erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline) ERX_WARN_UNUSED_RESULT;
/* An empty slot is ERX_EINVAL. */
int	erx_executor_wake(uint32_t slot) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_PARK_H */
