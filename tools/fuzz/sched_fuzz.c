/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the scheduler core with the bytes a domain controls: each grant is
 * ERX_SHARE_SIZE raw bytes copied as the kernel copies them out of a UTCB,
 * and urgencies and affinities are raw operands. The rest of the input is a
 * sequence of operations on a small machine. It aborts when an invariant
 * breaks:
 *
 *   a normalized grant is within every limit, and normalizing it again
 *   changes nothing;
 *   a refused grant or depth changes no record;
 *   S5: a thread's urgency is at most every ceiling on its path, and its
 *   CPUs are not empty and are within the machine's, the root's and the
 *   group's effective cpuset, so its placement is a CPU that exists;
 *   capacity is within the effective cpuset, and the first position within
 *   its size;
 *   a wake or a pick leaves every queue whole: each ready thread on exactly
 *   one level, of the state its record says, with the bitmap and both link
 *   directions agreeing, and no thread both ready and running;
 *   a pick moves at most ERX_PICK_MOVES threads, a dispatched thread runs at
 *   the urgency it resolves to, on a CPU it may run on, for a whole positive
 *   slice within its group's.
 *
 * Each operation is one byte of opcode followed by its operands.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sched_impl.h"

#define FUZZ_CPUS	4
#define FUZZ_GROUPS	12
#define FUZZ_THREADS	16
#define FUZZ_MACHINE	((UINT64_C(1) << FUZZ_CPUS) - 1)

typedef struct fuzz_input {
	const uint8_t	*data;
	size_t		 size;
} fuzz_input_t;

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static erx_sched_group_t	groups[FUZZ_GROUPS];
static erx_sched_thread_t	threads[FUZZ_THREADS];
static erx_sched_cpu_t		cpus[FUZZ_CPUS];
static uint32_t			ngroups;
static uint32_t			nthreads;
static erx_group_flags_t	cap;

static uint64_t
fuzz_take(fuzz_input_t *in, size_t width)
{
	uint64_t value = 0;
	size_t i;

	for (i = 0; i < width && in->size > 0; i++) {
		value |= (uint64_t)in->data[0] << (8 * i);
		in->data++;
		in->size--;
	}
	return (value);
}

/* A grant as user mode wrote it; a short input leaves the rest zero. */
static erx_grant_t
fuzz_grant(fuzz_input_t *in)
{
	erx_grant_t grant;
	size_t length = in->size < ERX_SHARE_SIZE ? in->size : ERX_SHARE_SIZE;

	memset(&grant, 0, sizeof(grant));
	if (length > 0)
		memcpy(&grant, in->data, length);
	in->data += length;
	in->size -= length;
	return (grant);
}

static void
check_grant(const erx_grant_t *grant)
{
	erx_grant_t again;

	if (grant->period_ns < ERX_PERIOD_MIN ||
	    grant->period_ns > ERX_PERIOD_MAX ||
	    grant->slice_us < ERX_SLICE_MIN_US ||
	    grant->slice_us > ERX_SLICE_MAX_US ||
	    grant->grace_us < ERX_GRACE_MIN_US ||
	    grant->grace_us > ERX_GRACE_MAX_US ||
	    grant->ceiling.raw > ERX_URGENCY_MAX ||
	    grant->base.raw > grant->ceiling.raw ||
	    (grant->flags & (erx_group_flags_t)~cap) != 0)
		abort();
	if (erx_grant_normalize(grant, cap, &again) != ERX_OK ||
	    memcmp(grant, &again, sizeof(again)) != 0)
		abort();
}

static void
check_group(const erx_sched_group_t *group)
{
	const erx_sched_group_t *level;
	erx_sched_capacity_t capacity;
	erx_grant_t grant;
	uint64_t cpuset, root_cpuset = 0;
	uint32_t size = 0;
	uint64_t rest;

	erx_sched_group_grant(group, &grant);
	check_grant(&grant);
	cpuset = erx_sched_group_cpuset(group);
	for (level = group; level != NULL; level = level->parent) {
		if (erx_sched_group_ceiling(group).raw >
		    atomic_load_explicit(&level->ceiling, memory_order_relaxed))
			abort();
		if (level->parent == NULL)
			root_cpuset = atomic_load_explicit(&level->cpuset,
			    memory_order_relaxed);
	}
	if (cpuset == 0 || (cpuset & ~(root_cpuset & FUZZ_MACHINE)) != 0)
		abort();
	if (erx_sched_group_base(group).raw > erx_sched_group_ceiling(group).raw)
		abort();
	for (rest = cpuset; rest != 0; rest &= rest - 1)
		size++;
	capacity = erx_sched_group_capacity(group);
	if (capacity.mcpu > size * 1000 || capacity.first >= size)
		abort();
}

static void
check_thread(const erx_sched_thread_t *thread)
{
	uint64_t allowed = erx_sched_thread_cpus(thread);
	uint32_t place;

	if (erx_sched_resolve(thread).raw >
	    erx_sched_group_ceiling(thread->group).raw)
		abort();
	if (allowed == 0 ||
	    (allowed & ~erx_sched_group_cpuset(thread->group)) != 0)
		abort();
	place = erx_sched_place(thread, 0);
	if (place >= FUZZ_CPUS || (allowed >> place & 1) == 0)
		abort();
}

/* Every list of every CPU, both ways, against each record and the bitmap. */
static void
check_queues(void)
{
	uint32_t cpu, seen = 0;
	int level;

	for (cpu = 0; cpu < FUZZ_CPUS; cpu++) {
		const erx_sched_cpu_t *c = &cpus[cpu];

		if (c->running != NULL && c->running->where !=
		    sched_where(SCHED_THREAD_RUNNING, c->index))
			abort();
		for (level = 0; level < SCHED_LEVELS; level++) {
			const sched_fifo_t *fifo = &c->levels[level];
			const erx_sched_thread_t *t, *last = NULL;

			if ((fifo->head != NULL) != ((c->ready >> level & 1) != 0))
				abort();
			for (t = fifo->head; t != NULL; t = t->next) {
				if (t->prev != last || t->level != level || t->where !=
				    sched_where(SCHED_THREAD_READY, c->index) ||
				    erx_sched_thread_home(t) != c->index)
					abort();
				seen++;
				if (seen > nthreads)
					abort();
				last = t;
			}
			if (fifo->tail != last)
				abort();
		}
	}
	for (cpu = 0; cpu < nthreads; cpu++) {
		if (sched_where_state(threads[cpu].where) == SCHED_THREAD_READY)
			seen--;
	}
	if (seen != 0)
		abort();
}

static void
check_decision(const erx_sched_cpu_t *cpu, const erx_sched_decision_t *decision)
{
	const erx_sched_thread_t *run = decision->run;
	uint32_t i;

	if (decision->nleaving > ERX_PICK_MOVES)
		abort();
	for (i = 0; i < decision->nleaving; i++) {
		if (decision->leaving[i]->where != SCHED_WHERE_OFF)
			abort();
	}
	if (cpu->running != run || (run != NULL && decision->again))
		abort();
	if (run == NULL)
		return;
	if (decision->urgency.raw != erx_sched_resolve(run).raw ||
	    (erx_sched_thread_cpus(run) >> cpu->index & 1) == 0 ||
	    decision->slice_ns == 0 ||
	    decision->slice_ns > erx_sched_group_slice_ns(run->group))
		abort();
}

static void
op_group(fuzz_input_t *in)
{
	uint64_t parent = fuzz_take(in, 1);
	erx_grant_t raw = fuzz_grant(in);
	erx_grant_t normalized;

	if (ngroups == FUZZ_GROUPS)
		return;
	if (erx_grant_normalize(&raw, cap, &normalized) == ERX_OK)
		check_grant(&normalized);
	if (erx_sched_group_init(&groups[ngroups], &groups[parent % ngroups],
	    &raw, cap) == ERX_OK)
		ngroups++;
}

static void
op_configure(fuzz_input_t *in)
{
	erx_sched_group_t *group = &groups[fuzz_take(in, 1) % ngroups];
	erx_grant_t raw = fuzz_grant(in);
	erx_grant_t before, after;

	erx_sched_group_grant(group, &before);
	if (erx_sched_group_configure(group, &raw, cap) != ERX_OK) {
		erx_sched_group_grant(group, &after);
		if (memcmp(&before, &after, sizeof(after)) != 0)
			abort();
	}
}

static void
op_thread(fuzz_input_t *in)
{
	uint64_t group = fuzz_take(in, 1);

	if (nthreads < FUZZ_THREADS)
		erx_sched_thread_init(&threads[nthreads++],
		    &groups[group % ngroups]);
}

static void
op_urgency(fuzz_input_t *in, erx_sched_thread_t *thread)
{
	erx_urgency_t urgency;
	erx_urgency_t before = erx_sched_resolve(thread);

	urgency.raw = (uint8_t)fuzz_take(in, 1);
	if (erx_sched_thread_set_urgency(thread, urgency) == ERX_OK) {
		if (urgency.raw > ERX_URGENCY_MAX)
			abort();
	} else if (urgency.raw <= ERX_URGENCY_MAX ||
	    erx_sched_resolve(thread).raw != before.raw) {
		abort();
	}
}

/* Places every thread that left, as the effect layer does, on a CPU it has. */
static void
op_pick(fuzz_input_t *in, erx_sched_cpu_t *cpu)
{
	erx_sched_decision_t decision;
	uint32_t i;

	erx_sched_pick(cpu, (erx_sched_why_t)(fuzz_take(in, 1) % 4),
	    fuzz_take(in, 8), &decision);
	check_decision(cpu, &decision);
	for (i = 0; i < decision.nleaving; i++) {
		uint32_t target = erx_sched_place(decision.leaving[i], UINT64_MAX);

		if (target >= FUZZ_CPUS)
			abort();
		(void)erx_sched_wake(&cpus[target], decision.leaving[i]);
	}
}

static void
fuzz_reset(fuzz_input_t *in)
{
	erx_grant_t root = fuzz_grant(in);
	uint32_t i;

	/* Three machines in four are capped to C0, the configuration under test. */
	cap = (fuzz_take(in, 1) & 3) == 0 ? (erx_group_flags_t)fuzz_take(in, 2) :
	    ERX_SCHED_C0_FLAGS;
	ngroups = 0;
	nthreads = 0;
	for (i = 0; i < FUZZ_CPUS; i++) {
		if (erx_sched_cpu_init(&cpus[i], i) != ERX_OK)
			abort();
	}
	if (erx_sched_cpu_init(&cpus[0], 64) != ERX_EINVAL ||
	    erx_sched_cpu_init(&cpus[0], 0) != ERX_OK)
		abort();
	/* The root is the kernel's, and holds the fuzzer's first valid grant. */
	if (erx_sched_root_init(&groups[0], FUZZ_MACHINE, &root, cap) == ERX_OK) {
		ngroups = 1;
		return;
	}
	memset(&root, 0, sizeof(root));
	root.cpuset = 15;
	if (erx_sched_root_init(&groups[0], FUZZ_MACHINE, &root, cap) != ERX_OK)
		abort();
	ngroups = 1;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_input_t in = { data, size };
	uint32_t i;

	fuzz_reset(&in);
	erx_sched_thread_init(&threads[0], &groups[0]);
	nthreads = 1;
	while (in.size > 0) {
		uint64_t opcode = fuzz_take(&in, 1);
		erx_sched_thread_t *thread = &threads[(opcode >> 4) % nthreads];
		erx_sched_cpu_t *cpu = &cpus[opcode >> 4 & 3];

		switch (opcode & 15) {
		case 0:
			op_group(&in);
			break;
		case 1:
			op_configure(&in);
			break;
		case 2:
			op_thread(&in);
			break;
		case 3:
			op_urgency(&in, thread);
			break;
		case 4:
			erx_sched_thread_set_affinity(thread, fuzz_take(&in, 8));
			break;
		case 5:
		case 6:
		case 7:
			(void)erx_sched_wake(cpu, &threads[fuzz_take(&in, 1) % nthreads]);
			break;
		case 8:
			(void)erx_sched_remove(cpu, &threads[fuzz_take(&in, 1) % nthreads]);
			break;
		default:
			op_pick(&in, cpu);
			break;
		}
		check_queues();
	}
	for (i = 0; i < ngroups; i++)
		check_group(&groups[i]);
	for (i = 0; i < nthreads; i++)
		check_thread(&threads[i]);
	return (0);
}
