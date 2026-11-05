/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The event table's core against a model of the group's status page. It fires at every gap
 * of an executor's sleep step and checks that no fire is lost, then has dispatchers and
 * firers race under ThreadSanitizer. Built with ERX_EVENT_SEED_LOOK_BEFORE_EPOCHS it must
 * report the lost wake, which proves the first check sees one, and built with
 * ERX_EVENT_SEED_LEAVE_WITHOUT_TAKING it must report the label a leaver left behind.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_event_table.h"

#define DISPATCHERS	4
#define FIRERS		4
#define FIRES_EACH	20000
#define LABELS_RACED	8

#define CHECK(cond)	do { if (!(cond)) { printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #cond); exit(1); } } while (0)

static erx_group_stat_t model_status;
static atomic_uint model_listed[ERX_EVENT_LABELS];
static int fire_at_gap = -1;

/* What a trigger does to the page: list the object, mirror ready, move the group's epoch. */
static void
model_fire(uint32_t index)
{
	if (atomic_exchange(&model_listed[index], 1) == 0)
		atomic_fetch_add(&model_status.ready, 1);
	atomic_fetch_add(&model_status.epoch, 1);
}

void
erx_event_test_gap(int gap)
{
	if (gap == fire_at_gap)
		model_fire(0);
}

static bool
flag_set(void *arg)
{
	return (*(bool *)arg);
}

/* What erx_park answers: at once if an epoch moved, otherwise it sleeps. */
static bool
model_park_returns(const erx_event_epochs_t *epochs)
{
	return (atomic_load(&model_status.epoch) != epochs->group ||
	    atomic_load(&model_status.exec[0].epoch) != epochs->slot);
}

static void
check_every_gap_of_the_sleep_step(void)
{
	for (fire_at_gap = 0; fire_at_gap <= 3; fire_at_gap++) {
		erx_event_epochs_t epochs;
		bool still_waiting = true;
		bool park;

		memset(&model_status, 0, sizeof(model_status));
		memset(model_listed, 0, sizeof(model_listed));
		park = erx_event_sleep_prepare(&model_status, 0, flag_set, &still_waiting, &epochs);
		if (park && !model_park_returns(&epochs) && atomic_load(&model_status.ready) != 0) {
			printf("LOST WAKE: fire at gap %d: the park sleeps with ready at %u\n", fire_at_gap,
			    (unsigned)atomic_load(&model_status.ready));
			exit(1);
		}
	}
	fire_at_gap = -1;
}

static void
check_a_cleared_flag_stops_the_sleep(void)
{
	erx_event_epochs_t epochs;
	bool still_waiting = false;

	memset(&model_status, 0, sizeof(model_status));
	CHECK(!erx_event_sleep_prepare(&model_status, 0, flag_set, &still_waiting, &epochs));
}

static uint32_t crossed_delivered;

static int
crossed_take(uint32_t *labels, void *arg)
{
	(void)arg;
	if (atomic_exchange(&model_listed[0], 0) == 0)
		return (0);
	atomic_fetch_sub(&model_status.ready, 1);
	labels[0] = ERX_LABEL_SPLIT;
	return (1);
}

static void crossed_nothing(void *arg) { (void)arg; }

static void
crossed_deliver(const erx_event_sink_t *sink, void *arg)
{
	(void)sink;
	(void)arg;
	crossed_delivered++;
}

/*
 * A waker's wake and a fire cross, which no run can be made to do on demand. The loop of
 * scheduler_wait has dispatched and goes to sleep; the fire lands at each gap of that step,
 * and the waker's cleared flag or a park answering at once sends the executor out with no
 * pass of the loop's dispatch. Leaving by the one exit must take the label.
 */
static void
check_no_executor_leaves_with_a_label(void)
{
	static erx_event_table_t table;
	const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PROCESS };
	const erx_event_ops_t ops = { .take = crossed_take, .read_lock = crossed_nothing, .read_unlock = crossed_nothing,
		.deliver = crossed_deliver };
	uint32_t label;

	CHECK(erx_event_table_add(&table, &sink, &label) == ERX_OK && label == ERX_LABEL_SPLIT);
	for (int cleared = 0; cleared <= 1; cleared++) {
		for (fire_at_gap = 0; fire_at_gap <= 3; fire_at_gap++) {
			erx_event_epochs_t epochs;
			bool still_waiting = cleared == 0;
			bool fired;

			memset(&model_status, 0, sizeof(model_status));
			memset(model_listed, 0, sizeof(model_listed));
			crossed_delivered = 0;
			(void)erx_event_sleep_prepare(&model_status, 0, flag_set, &still_waiting, &epochs);
			fired = atomic_load(&model_status.ready) != 0;
			(void)erx_event_leave_wait_ready(&model_status, &table, &ops);
			if (atomic_load(&model_status.ready) != 0) {
				printf("LEFT WITH A LABEL: fire at gap %d, flag %s\n", fire_at_gap,
				    cleared != 0 ? "cleared" : "set");
				exit(1);
			}
			CHECK(crossed_delivered == (fired ? 1u : 0u));
		}
	}
	fire_at_gap = -1;
	/* The exit with nothing listed takes nothing: the next fire stays for whoever it wakes. */
	CHECK(erx_event_leave_wait_ready(&model_status, &table, &ops) == 0);
}

static void
check_the_table(void)
{
	static erx_event_table_t table;
	const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PROCESS, .owner = 7 };
	uint32_t label = 0;

	CHECK(erx_event_table_find(&table, 0) == NULL);
	CHECK(erx_event_table_find(&table, ERX_LABEL_SPLIT - 1) == NULL);
	CHECK(erx_event_table_find(&table, ERX_LABEL_SPLIT + ERX_EVENT_LABELS) == NULL);
	CHECK(erx_event_table_find(&table, UINT32_MAX) == NULL);
	for (uint32_t index = 0; index < ERX_EVENT_LABELS; index++) {
		CHECK(erx_event_table_find(&table, ERX_LABEL_SPLIT + index) == NULL);
		CHECK(erx_event_table_add(&table, &sink, &label) == ERX_OK);
		CHECK(label == ERX_LABEL_SPLIT + index);
		CHECK(erx_event_table_find(&table, label)->owner == 7);
	}
	CHECK(erx_event_table_add(&table, &sink, &label) == ERX_ELIMIT);
	/* A freed label is the next one given, and a second removal finds nothing. */
	CHECK(erx_event_table_remove(&table, ERX_LABEL_SPLIT + 3).kind == ERX_EVENT_SINK_PROCESS);
	CHECK(erx_event_table_remove(&table, ERX_LABEL_SPLIT + 3).kind == ERX_EVENT_SINK_FREE);
	CHECK(erx_event_table_remove(&table, 12).kind == ERX_EVENT_SINK_FREE);
	CHECK(erx_event_table_add(&table, &sink, &label) == ERX_OK && label == ERX_LABEL_SPLIT + 3);
}

/* A burst longer than one take arrives whole, and a label with no entry is dropped. */
static uint32_t burst_next;
static uint32_t burst_end;
static uint32_t burst_delivered;

static int
burst_take(uint32_t *labels, void *arg)
{
	int taken = 0;

	(void)arg;
	while ((uint32_t)taken < ERX_MSG_WORDS && burst_next < burst_end)
		labels[taken++] = ERX_LABEL_SPLIT + burst_next++;
	return (taken);
}

static void burst_nothing(void *arg) { (void)arg; }

static void
burst_deliver(const erx_event_sink_t *sink, void *arg)
{
	(void)sink;
	(void)arg;
	burst_delivered++;
}

static void
check_a_long_burst_arrives_whole(void)
{
	static erx_event_table_t table;
	const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PROCESS };
	const erx_event_ops_t ops = { .take = burst_take, .read_lock = burst_nothing, .read_unlock = burst_nothing,
		.deliver = burst_deliver };
	uint32_t label;

	for (uint32_t index = 0; index < ERX_MSG_WORDS * 2 + 1; index++)
		CHECK(erx_event_table_add(&table, &sink, &label) == ERX_OK);
	CHECK(erx_event_table_remove(&table, ERX_LABEL_SPLIT + 1).kind == ERX_EVENT_SINK_PROCESS);
	burst_end = ERX_MSG_WORDS * 2 + 1;
	CHECK(erx_event_dispatch_ready(&table, &ops) == ERX_MSG_WORDS * 2 + 1);
	CHECK(burst_delivered == ERX_MSG_WORDS * 2);
}

/* The race: every fire leaves a label listed, and every listed label is delivered once. */
static erx_event_table_t raced_table;
static pthread_rwlock_t raced_lock = PTHREAD_RWLOCK_INITIALIZER;
static atomic_ulong delivered[LABELS_RACED];
static atomic_ulong taken_labels;
static atomic_int firers_left = FIRERS;

static int
race_take(uint32_t *labels, void *arg)
{
	int taken = 0;

	(void)arg;
	for (uint32_t index = 0; index < LABELS_RACED && (uint32_t)taken < ERX_MSG_WORDS; index++) {
		if (atomic_exchange(&model_listed[index], 0) != 0) {
			atomic_fetch_sub(&model_status.ready, 1);
			labels[taken++] = ERX_LABEL_SPLIT + index;
		}
	}
	return (taken);
}

static void race_lock(void *arg) { (void)arg; (void)pthread_rwlock_rdlock(&raced_lock); }
static void race_unlock(void *arg) { (void)arg; (void)pthread_rwlock_unlock(&raced_lock); }

static void
race_deliver(const erx_event_sink_t *sink, void *arg)
{
	(void)arg;
	atomic_fetch_add(&delivered[sink->owner], 1);
	atomic_fetch_add(&taken_labels, 1);
}

static void *
dispatcher(void *unused)
{
	const erx_event_ops_t ops = { .take = race_take, .read_lock = race_lock, .read_unlock = race_unlock,
		.deliver = race_deliver };

	(void)unused;
	while (atomic_load(&firers_left) > 0 || atomic_load(&model_status.ready) != 0)
		(void)erx_event_dispatch_ready(&raced_table, &ops);
	return (NULL);
}

static void *
firer(void *arg)
{
	const uint32_t base = (uint32_t)(uintptr_t)arg;

	for (uint32_t round = 0; round < FIRES_EACH; round++)
		model_fire((base + round) % LABELS_RACED);
	atomic_fetch_sub(&firers_left, 1);
	return (NULL);
}

static void
check_the_race(void)
{
	pthread_t threads[DISPATCHERS + FIRERS];
	unsigned long total = 0;
	uint32_t label;

	memset(&model_status, 0, sizeof(model_status));
	memset(model_listed, 0, sizeof(model_listed));
	for (uint32_t index = 0; index < LABELS_RACED; index++) {
		const erx_event_sink_t sink = { .kind = ERX_EVENT_SINK_PORT, .owner = index };

		CHECK(erx_event_table_add(&raced_table, &sink, &label) == ERX_OK);
	}
	for (int index = 0; index < DISPATCHERS; index++)
		CHECK(pthread_create(&threads[index], NULL, dispatcher, NULL) == 0);
	for (int index = 0; index < FIRERS; index++)
		CHECK(pthread_create(&threads[DISPATCHERS + index], NULL, firer, (void *)(uintptr_t)index) == 0);
	for (int index = 0; index < DISPATCHERS + FIRERS; index++)
		CHECK(pthread_join(threads[index], NULL) == 0);
	CHECK(atomic_load(&model_status.ready) == 0);
	for (uint32_t index = 0; index < LABELS_RACED; index++) {
		CHECK(atomic_load(&model_listed[index]) == 0);
		CHECK(atomic_load(&delivered[index]) > 0);
		total += atomic_load(&delivered[index]);
	}
	CHECK(total == atomic_load(&taken_labels));
}

int
main(void)
{
	check_every_gap_of_the_sleep_step();
	check_a_cleared_flag_stops_the_sleep();
	check_no_executor_leaves_with_a_label();
	check_the_table();
	check_a_long_burst_arrives_whole();
	check_the_race();
	puts("event table done");
	return (0);
}
