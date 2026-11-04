/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PARK_TABLE_H
#define ERX_FIASCO_PARK_TABLE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The park protocol's core (docs/design-stopgap.md, "The park protocol"): one
 * state machine over the group's epoch, each slot's epoch and the parked list in
 * order. It reads no clock and calls no kernel. Each step says what its caller
 * does once the lock is released, and a slot taken off the list is owed exactly
 * one up, so a semaphore holds 0 whenever its executor enters a park.
 */

#define ERX_FIASCO_PARK_NO_SLOT	UINT32_MAX

typedef struct erx_fiasco_park {
	uint64_t	group_epoch;
	uint64_t	slot_epoch[ERX_GROUP_EXECUTORS_MAX];
	uint64_t	used;		/* one bit per slot */
	uint8_t		parked[ERX_GROUP_EXECUTORS_MAX];	/* oldest first */
	uint32_t	parked_count;
} erx_fiasco_park_t;

typedef enum erx_fiasco_park_op {
	ERX_FIASCO_PARK_OP_CLAIM = 1,	/* a new executor takes the lowest free slot */
	ERX_FIASCO_PARK_OP_RELEASE,	/* an executor's death: as a trigger, and its slot is free */
	ERX_FIASCO_PARK_OP_TRIGGER,
	ERX_FIASCO_PARK_OP_PARK,
	ERX_FIASCO_PARK_OP_TIMEOUT,
	ERX_FIASCO_PARK_OP_WAKE
} erx_fiasco_park_op_t;

typedef struct erx_fiasco_park_event {
	erx_fiasco_park_op_t op;
	uint32_t	slot;		/* every op but CLAIM and TRIGGER */
	uint64_t	group_seen;	/* for PARK: the epochs the executor read */
	uint64_t	slot_seen;
} erx_fiasco_park_event_t;

typedef enum erx_fiasco_park_action {
	ERX_FIASCO_PARK_NOTHING = 1,
	ERX_FIASCO_PARK_REFUSED,	/* no such slot, or no free one */
	ERX_FIASCO_PARK_CLAIMED,	/* result.slot is the caller's */
	ERX_FIASCO_PARK_RETURN,		/* an epoch moved: the park returns ERX_OK */
	ERX_FIASCO_PARK_SLEEP,		/* down with the deadline */
	ERX_FIASCO_PARK_TIMED_OUT,	/* the park returns ERX_ETIMEDOUT */
	ERX_FIASCO_PARK_OWED,		/* a waker took the slot: an unbounded down, then ERX_OK */
	ERX_FIASCO_PARK_UP		/* up result.slot's semaphore */
} erx_fiasco_park_action_t;

typedef struct erx_fiasco_park_result {
	erx_fiasco_park_action_t action;
	uint32_t	slot;		/* for CLAIMED and UP */
} erx_fiasco_park_result_t;

erx_fiasco_park_result_t erx_fiasco_park_step(erx_fiasco_park_t *, const erx_fiasco_park_event_t *);

/*
 * What the protocol asks of its caller. down blocks the slot's own executor until
 * its up or the deadline, and returns false at the deadline, never before it.
 * absorb blocks until an up already on its way arrives. up never blocks. Only the
 * step and the status mirror run under the lock.
 */
typedef struct erx_fiasco_park_effects {
	void	(*lock)(void *);
	void	(*unlock)(void *);
	bool	(*down)(void *, uint32_t, uint64_t);
	void	(*absorb)(void *, uint32_t);
	void	(*up)(void *, uint32_t);
} erx_fiasco_park_effects_t;

typedef struct erx_fiasco_park_group {
	erx_fiasco_park_t	 park;
	erx_group_stat_t	*status;	/* the page runtimes read the epochs from */
} erx_fiasco_park_group_t;

/* The calls, each one step under the lock with its effect after it. */
uint32_t erx_fiasco_park_claim(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *, void *);
void	erx_fiasco_park_release(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *, void *, uint32_t);
void	erx_fiasco_park_trigger(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *, void *);
/* ERX_OK when woken or when an epoch moved, ERX_ETIMEDOUT at the deadline. */
int	erx_fiasco_park_wait(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *, void *, uint32_t,
	    uint64_t, uint64_t, uint64_t);
/* ERX_OK, or ERX_EINVAL for an empty slot. */
int	erx_fiasco_park_wake(erx_fiasco_park_group_t *, const erx_fiasco_park_effects_t *, void *, uint32_t);

#endif /* ERX_FIASCO_PARK_TABLE_H */
