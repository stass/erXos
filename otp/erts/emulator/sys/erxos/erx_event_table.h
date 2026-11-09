/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The event table's core (docs/design-runtime.md, "The event table"): what a label names
 * and the order of an executor's sleep step. It knows nothing of ERTS and calls no kernel,
 * so a host test can drive every path. erx_event.c holds its effects.
 */

#ifndef ERX_EVENT_TABLE_H
#define ERX_EVENT_TABLE_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The runtime's half of the label space, from ERX_LABEL_SPLIT. A label indexes the table
 * directly and the lowest free one is taken first, so labels stay dense and a lookup never
 * searches.
 */
#define ERX_EVENT_LABELS	256
/*
 * The system domain's half, below ERX_LABEL_SPLIT: the labels it bound the domain's bells
 * with, one per connection, each a connection sink. A domain holds few connections, and
 * the label is the system domain's choice, so these are searched.
 */
#define ERX_EVENT_CONNECTIONS	64	/* one bit each in a uint64_t mask */

typedef enum {
	ERX_EVENT_SINK_FREE = 0,
	ERX_EVENT_SINK_PORT,
	ERX_EVENT_SINK_PROCESS,
	ERX_EVENT_SINK_CONNECTION
} erx_event_sink_kind_t;

/* A sink names its owner by id, never by pointer, so a stale entry finds nothing to touch. */
typedef struct {
	erx_event_sink_kind_t	kind;
	uint64_t		owner;		/* the port's or the process's id; a connection's label */
	uint64_t		detail;		/* the driver's event, the message term, or a connection's port */
	void			*storage;	/* what holds the message term */
} erx_event_sink_t;

typedef struct {
	erx_event_sink_t	sinks[ERX_EVENT_LABELS];
	erx_event_sink_t	connections[ERX_EVENT_CONNECTIONS];
} erx_event_table_t;

/* ERX_OK with the label, or ERX_ELIMIT with the table full. The caller holds the write lock. */
int	erx_event_table_add(erx_event_table_t *table, const erx_event_sink_t *sink, uint32_t *label);
/*
 * A connection sink at the label the system domain chose, below ERX_LABEL_SPLIT: ERX_OK,
 * ERX_EINVAL for a label of the runtime's half or one already a sink, or ERX_ELIMIT with
 * the connections full. A free slot whose bit is set in unsettled is passed over: a task
 * of the connection that last held it may still hold one of its handles
 * (erx_event.c). The caller holds the write lock.
 */
int	erx_event_table_add_connection(erx_event_table_t *table, uint32_t label, uint64_t port,
	    uint64_t unsettled);
/* The sink the label named, for the caller to release, or a free one if it named none. */
erx_event_sink_t erx_event_table_remove(erx_event_table_t *table, uint32_t label);
/* The sink, or NULL: a label whose entry is gone is dropped, since a delivery is a hint. */
const erx_event_sink_t *erx_event_table_find(const erx_event_table_t *table, uint32_t label);

typedef struct {
	/* Up to ERX_MSG_WORDS labels into `labels`; negative where the caller may not take. */
	int	(*take)(uint32_t *labels, void *arg);
	void	(*read_lock)(void *arg);
	void	(*read_unlock)(void *arg);
	void	(*deliver)(const erx_event_sink_t *sink, void *arg);
	void	*arg;
} erx_event_ops_t;

/* Takes the ready list until it runs short and delivers each label; answers how many. */
uint32_t erx_event_dispatch_ready(const erx_event_table_t *table, const erx_event_ops_t *ops);

/*
 * The exit of an executor's wait that has slept. A fire wakes one executor, and that may be the one a
 * waker has just told to leave, whose flags then say nothing of the fire. So a leaver takes
 * whatever `ready` shows, whatever woke it, and no executor leaves with a label listed that
 * it could have seen. Answers how many it took.
 */
uint32_t erx_event_leave_wait_ready(const erx_group_stat_t *status, const erx_event_table_t *table,
	    const erx_event_ops_t *ops);

typedef struct {
	uint64_t	group;
	uint64_t	slot;
} erx_event_epochs_t;

/*
 * The interlock of a sleep, in the one order that loses no wake: read both epochs, set
 * the sleep flag, then look at `ready`. A fire before the look shows in `ready`, and one
 * after it moves the group's epoch, which the park compares. The epochs come before the
 * flag because a waker clears the flag and then moves the slot's epoch, so its wake too
 * moves what the park compares. Answers whether to park.
 * set_flag answers false when a waker has already cleared the flags.
 */
bool	erx_event_sleep_prepare(const erx_group_stat_t *status, uint32_t slot,
	    bool (*set_flag)(void *arg), void *arg, erx_event_epochs_t *epochs);

#endif /* ERX_EVENT_TABLE_H */
