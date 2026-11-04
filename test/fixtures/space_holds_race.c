/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Races the drops of one parent's holds, for ThreadSanitizer: each child's
 * free on its own thread against the parent's readiness on another, as CPUs'
 * reapers run them. Each thread writes its own word before its drop. Exactly
 * one drop may report the last, and that thread reads every word, as whoever
 * frees a record reads what the other holders wrote, so an ordering too weak
 * to pass those writes on is a reported race.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/space.h"

#define CHILDREN	7
#define ROUNDS		300

static erx_space_t *parent;
static erx_space_t *children[CHILDREN];
static uint64_t written[CHILDREN + 1];
static atomic_int lasts;
static atomic_int started;
static uint64_t round_now;

static void
last_drop(void)
{
	for (int i = 0; i <= CHILDREN; i++)
		if (written[i] != round_now)
			abort();
	atomic_fetch_add_explicit(&lasts, 1, memory_order_relaxed);
}

static void
wait_for_all(void)
{
	atomic_fetch_add_explicit(&started, 1, memory_order_relaxed);
	while (atomic_load_explicit(&started, memory_order_relaxed) <
	    CHILDREN + 1)
		continue;
}

static void *
child_free(void *argument)
{
	int i;

	i = *(const int *)argument;
	wait_for_all();
	written[i] = round_now;
	if (erx_space_unhold_parent(children[i]) == parent)
		last_drop();
	return (NULL);
}

static void *
parent_ready(void *argument)
{
	(void)argument;
	wait_for_all();
	written[CHILDREN] = round_now;
	if (erx_space_free_ready(parent))
		last_drop();
	return (NULL);
}

static erx_space_t *
new_record(void)
{
	erx_space_t *record;
	size_t align, bytes;

	align = erx_space_record_align();
	bytes = (erx_space_record_size() + align - 1) / align * align;
	record = aligned_alloc(align, bytes);
	if (record == NULL)
		abort();
	erx_space_record_init(record);
	return (record);
}

static void
build_tree(void)
{
	erx_space_plan_t plan;

	if (erx_space_init_first(parent, 1, 16) != ERX_OK)
		abort();
	for (int i = 0; i < CHILDREN; i++) {
		plan = (erx_space_plan_t){ .stage = ERX_SPACE_PLANNED,
		    .parent = parent, .depth = 1, .cap_limit = 16 };
		if (erx_space_attach(&plan, children[i],
		    (uint64_t)i + 2) != ERX_OK)
			abort();
	}
}

int
main(void)
{
	pthread_t threads[CHILDREN + 1];
	int ids[CHILDREN];

	parent = new_record();
	for (int i = 0; i < CHILDREN; i++) {
		children[i] = new_record();
		ids[i] = i;
	}
	for (int round = 1; round <= ROUNDS; round++) {
		round_now = (uint64_t)round;
		build_tree();
		atomic_store_explicit(&lasts, 0, memory_order_relaxed);
		atomic_store_explicit(&started, 0, memory_order_relaxed);
		for (int i = 0; i < CHILDREN; i++)
			if (pthread_create(&threads[i], NULL, child_free,
			    &ids[i]) != 0)
				abort();
		if (pthread_create(&threads[CHILDREN], NULL, parent_ready,
		    NULL) != 0)
			abort();
		for (int i = 0; i <= CHILDREN; i++)
			if (pthread_join(threads[i], NULL) != 0)
				abort();
		if (atomic_load_explicit(&lasts, memory_order_relaxed) != 1)
			abort();
	}
	printf("%d rounds, one last drop each\n", ROUNDS);
	return (0);
}
