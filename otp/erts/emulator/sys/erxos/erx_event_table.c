/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdatomic.h>
#include <stddef.h>

#include "erx_event_table.h"

/* A test fires at each numbered gap of the sleep step; a build for ERTS has no gaps. */
#ifdef ERX_EVENT_TEST_GAP
void	erx_event_test_gap(int gap);
#else
#define ERX_EVENT_TEST_GAP(n)	((void)0)
#endif

int
erx_event_table_add(erx_event_table_t *table, const erx_event_sink_t *sink, uint32_t *label)
{
	for (uint32_t index = 0; index < ERX_EVENT_LABELS; index++) {
		if (table->sinks[index].kind == ERX_EVENT_SINK_FREE) {
			table->sinks[index] = *sink;
			*label = ERX_LABEL_SPLIT + index;
			return (ERX_OK);
		}
	}
	return (ERX_ELIMIT);
}

const erx_event_sink_t *
erx_event_table_find(const erx_event_table_t *table, uint32_t label)
{
	const erx_event_sink_t *sink;

	if (label < ERX_LABEL_SPLIT || label - ERX_LABEL_SPLIT >= ERX_EVENT_LABELS)
		return (NULL);
	sink = &table->sinks[label - ERX_LABEL_SPLIT];
	return (sink->kind == ERX_EVENT_SINK_FREE ? NULL : sink);
}

erx_event_sink_t
erx_event_table_remove(erx_event_table_t *table, uint32_t label)
{
	const erx_event_sink_t *const sink = erx_event_table_find(table, label);
	const erx_event_sink_t removed = sink != NULL ? *sink : (erx_event_sink_t){ .kind = ERX_EVENT_SINK_FREE };

	if (sink != NULL)
		table->sinks[label - ERX_LABEL_SPLIT] = (erx_event_sink_t){ .kind = ERX_EVENT_SINK_FREE };
	return (removed);
}

uint32_t
erx_event_dispatch_ready(const erx_event_table_t *table, const erx_event_ops_t *ops)
{
	uint32_t labels[ERX_MSG_WORDS];
	uint32_t total = 0;
	int taken;

	do {
		taken = ops->take(labels, ops->arg);
		if (taken <= 0)
			break;
		ops->read_lock(ops->arg);
		for (int index = 0; index < taken; index++) {
			const erx_event_sink_t *const sink = erx_event_table_find(table, labels[index]);

			if (sink != NULL)
				ops->deliver(sink, ops->arg);
		}
		ops->read_unlock(ops->arg);
		total += (uint32_t)taken;
	} while ((uint32_t)taken == ERX_MSG_WORDS);
	return (total);
}

uint32_t
erx_event_leave_wait_ready(const erx_group_stat_t *status, const erx_event_table_t *table, const erx_event_ops_t *ops)
{
#ifdef ERX_EVENT_SEED_LEAVE_WITHOUT_TAKING
	/* The seeded exit: a fire that crossed the waker's wake stays listed behind this executor. */
	(void)status;
	(void)table;
	(void)ops;
	return (0);
#else
	if (atomic_load_explicit(&status->ready, memory_order_acquire) == 0)
		return (0);
	return (erx_event_dispatch_ready(table, ops));
#endif
}

static void
read_epochs(const erx_group_stat_t *status, uint32_t slot, erx_event_epochs_t *epochs)
{
	epochs->group = atomic_load_explicit(&status->epoch, memory_order_acquire);
	epochs->slot = atomic_load_explicit(&status->exec[slot].epoch, memory_order_acquire);
}

bool
erx_event_sleep_prepare(const erx_group_stat_t *status, uint32_t slot, bool (*set_flag)(void *arg), void *arg,
    erx_event_epochs_t *epochs)
{
	bool empty;

	ERX_EVENT_TEST_GAP(0);
#ifdef ERX_EVENT_SEED_LOOK_BEFORE_EPOCHS
	/* The seeded lost wake: a fire between the look and the epochs is seen by neither. */
	empty = atomic_load_explicit(&status->ready, memory_order_acquire) == 0;
	ERX_EVENT_TEST_GAP(1);
	read_epochs(status, slot, epochs);
	ERX_EVENT_TEST_GAP(2);
	return (set_flag(arg) && empty);
#elif defined(ERX_EVENT_SEED_EPOCHS_AFTER_FLAG)
	/* The seeded lost wake: a waker between the flag and the epochs leaves nothing to see. */
	ERX_EVENT_TEST_GAP(1);
	if (!set_flag(arg))
		return (false);
	read_epochs(status, slot, epochs);
	ERX_EVENT_TEST_GAP(2);
	empty = atomic_load_explicit(&status->ready, memory_order_acquire) == 0;
	ERX_EVENT_TEST_GAP(3);
	return (empty);
#else
	read_epochs(status, slot, epochs);
	ERX_EVENT_TEST_GAP(1);
	if (!set_flag(arg))
		return (false);
	ERX_EVENT_TEST_GAP(2);
	empty = atomic_load_explicit(&status->ready, memory_order_acquire) == 0;
	ERX_EVENT_TEST_GAP(3);
	return (empty);
#endif
}
