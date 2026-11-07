/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_PARK_TABLE_H
#define ERX_BACKEND_PARK_TABLE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The park protocol's core (docs/design-stopgap.md, "The park protocol"), which
 * both backends run: one state machine over the group's epoch, each slot's epoch,
 * the parked list in order, the ready list in order and the listed flags. It reads
 * no clock and calls no kernel. Each step says what its caller does once the lock is
 * released, and a slot taken off the parked list is owed exactly one up, so a
 * semaphore holds 0 whenever its executor enters a park.
 */

#define ERX_BACKEND_PARK_NO_SLOT	UINT32_MAX
/* How many IRQ objects a group holds: one listed bit each, and an index fits ready's bytes. */
#define ERX_BACKEND_PARK_OBJECTS_MAX	64u

typedef struct erx_backend_park {
	uint64_t	group_epoch;
	uint64_t	slot_epoch[ERX_GROUP_EXECUTORS_MAX];
	uint64_t	used;		/* one bit per slot */
	uint8_t		parked[ERX_GROUP_EXECUTORS_MAX];	/* oldest first */
	uint32_t	parked_count;
	uint64_t	listed;		/* one bit per object: on ready, so at most once */
	uint8_t		ready[ERX_BACKEND_PARK_OBJECTS_MAX];	/* oldest first */
	uint32_t	ready_count;
} erx_backend_park_t;

typedef enum erx_backend_park_op {
	ERX_BACKEND_PARK_OP_CLAIM = 1,	/* a new executor takes the lowest free slot */
	ERX_BACKEND_PARK_OP_RELEASE,	/* an executor's death: as a trigger, and its slot is free */
	ERX_BACKEND_PARK_OP_TRIGGER,	/* the epoch advances and the oldest parked slot wakes */
	ERX_BACKEND_PARK_OP_PARK,
	ERX_BACKEND_PARK_OP_TIMEOUT,
	ERX_BACKEND_PARK_OP_WAKE,
	ERX_BACKEND_PARK_OP_TAKE,	/* the oldest listed object leaves the ready list */
	ERX_BACKEND_PARK_OP_SIGNAL	/* an object fired: on the ready list at most once, then as a trigger */
} erx_backend_park_op_t;

typedef struct erx_backend_park_event {
	erx_backend_park_op_t op;
	uint32_t	slot;		/* every op but CLAIM, TRIGGER, TAKE and SIGNAL */
	uint32_t	object;		/* for SIGNAL */
	uint64_t	group_seen;	/* for PARK: the epochs the executor read */
	uint64_t	slot_seen;
} erx_backend_park_event_t;

typedef enum erx_backend_park_action {
	ERX_BACKEND_PARK_NOTHING = 1,
	ERX_BACKEND_PARK_REFUSED,	/* no such slot, or no free one */
	ERX_BACKEND_PARK_CLAIMED,	/* result.slot is the caller's */
	ERX_BACKEND_PARK_RETURN,		/* an epoch moved: the park returns ERX_OK */
	ERX_BACKEND_PARK_SLEEP,		/* down with the deadline */
	ERX_BACKEND_PARK_TIMED_OUT,	/* the park returns ERX_ETIMEDOUT */
	ERX_BACKEND_PARK_OWED,		/* a waker took the slot: an unbounded down, then ERX_OK */
	ERX_BACKEND_PARK_UP,		/* up result.slot's semaphore */
	ERX_BACKEND_PARK_TAKEN		/* result.object left the ready list */
} erx_backend_park_action_t;

typedef struct erx_backend_park_result {
	erx_backend_park_action_t action;
	uint32_t	slot;		/* for CLAIMED and UP */
	uint32_t	object;		/* for TAKEN */
} erx_backend_park_result_t;

erx_backend_park_result_t erx_backend_park_step(erx_backend_park_t *, const erx_backend_park_event_t *);

/*
 * What the protocol asks of its caller. down blocks the slot's own executor until
 * its up or the deadline, and returns false at the deadline, never before it.
 * absorb blocks until an up already on its way arrives. up never blocks. trace records
 * the slot executor's own park (ERX_TRACE_EVENT_PARK, with its deadline) and the end of
 * that park (ERX_TRACE_EVENT_WAKE, with its status) on the trace ring, outside the park
 * lock (docs/design-stopgap.md, "The trace ring"). Only the step and the status mirror
 * run under the lock.
 */
typedef struct erx_backend_park_effects {
	void	(*lock)(void *);
	void	(*unlock)(void *);
	bool	(*down)(void *, uint32_t, uint64_t);
	void	(*absorb)(void *, uint32_t);
	void	(*up)(void *, uint32_t);
	void	(*trace)(void *, uint32_t, uint32_t, uint64_t);	/* event, slot, deadline or status */
} erx_backend_park_effects_t;

typedef struct erx_backend_park_group {
	erx_backend_park_t	 park;
	erx_group_stat_t	*status;	/* the page runtimes read the epochs from */
} erx_backend_park_group_t;

/* The calls, each one step under the lock with its effect after it. */
uint32_t erx_backend_park_claim(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *);
void	erx_backend_park_release(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *, uint32_t);
void	erx_backend_park_trigger(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *);
/* ERX_OK, or ERX_EINVAL for an object index of ERX_BACKEND_PARK_OBJECTS_MAX or more. */
int	erx_backend_park_signal(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *, uint32_t);
/* Moves up to max listed objects into objects, oldest first, and returns how many. Never blocks. */
uint32_t erx_backend_park_take(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *, uint32_t, uint32_t *);
/* ERX_OK when woken or when an epoch moved, ERX_ETIMEDOUT at the deadline. */
int	erx_backend_park_wait(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *, uint32_t,
	    uint64_t, uint64_t, uint64_t);
/* ERX_OK, or ERX_EINVAL for an empty slot. */
int	erx_backend_park_wake(erx_backend_park_group_t *, const erx_backend_park_effects_t *, void *, uint32_t);

#endif /* ERX_BACKEND_PARK_TABLE_H */
