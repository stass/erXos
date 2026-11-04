/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The scheduler core for configuration C0 (docs/design-scheduler.md,
 * "Urgency resolution", "Pick and dispatch", "Placement and affinity").
 *
 * Grants are the only input a domain chooses. Each is normalized before it
 * enters a record, so a stored field is always in range. A thread's CPUs are
 * derived again at every decision from what the records hold then. Its urgency
 * is stored: every store is the thread's own resolve, at its wake, when it
 * rejoins the queues, or in erx_sched_refresh, so a thread never runs above a
 * ceiling its path had at its last store, and the pick moves nothing for it.
 *
 * Every walk up a group path is bounded by ERX_GROUP_DEPTH_MAX, which
 * erx_sched_group_init enforces. Every pick is bounded by ERX_PICK_MOVES.
 */

#include <stdalign.h>

#include "sched_impl.h"

#define GROUP_FLAGS_DEFINED						\
	((erx_group_flags_t)(ERX_GROUP_HINTS | ERX_GROUP_DEFER |	\
	    ERX_GROUP_STATUS | ERX_GROUP_PLACE))

#define CPUSET_BITS		UINT32_C(64)
#define MCPU_PER_CPU		UINT32_C(1000)
#define NS_PER_US		UINT64_C(1000)

_Static_assert(SCHED_LEVELS == 64, "a 64-bit bitmap covers every level");
_Static_assert(ERX_PERIOD_MAX <= INT64_MAX / CPUSET_BITS,
    "a capped quota fits a pool's int64_t, and the cap does not overflow");

size_t
erx_sched_group_record_size(void)
{
	return (sizeof(erx_sched_group_t));
}

size_t
erx_sched_group_record_align(void)
{
	return (alignof(erx_sched_group_t));
}

size_t
erx_sched_thread_record_size(void)
{
	return (sizeof(erx_sched_thread_t));
}

size_t
erx_sched_thread_record_align(void)
{
	return (alignof(erx_sched_thread_t));
}

size_t
erx_sched_cpu_record_size(void)
{
	return (sizeof(erx_sched_cpu_t));
}

size_t
erx_sched_cpu_record_align(void)
{
	return (alignof(erx_sched_cpu_t));
}

static uint64_t
clamp_u64(uint64_t value, uint64_t low, uint64_t high)
{
	if (value < low)
		return (low);
	return (value > high ? high : value);
}

static uint32_t
clamp_u32(uint32_t value, uint32_t low, uint32_t high)
{
	return ((uint32_t)clamp_u64(value, low, high));
}

static uint64_t
min_u64(uint64_t a, uint64_t b)
{
	return (a < b ? a : b);
}

static uint8_t
min_u8(uint8_t a, uint8_t b)
{
	return (a < b ? a : b);
}

static bool
cpuset_has(uint64_t cpuset, uint32_t cpu)
{
	return (cpu < CPUSET_BITS && (cpuset >> cpu & 1) != 0);
}

static uint32_t
cpuset_lowest(uint64_t cpuset)
{
	return ((uint32_t)__builtin_ctzll(cpuset));
}

/* A loop, since a popcount builtin may become a library call in the kernel. */
static uint32_t
cpuset_size(uint64_t cpuset)
{
	uint32_t size;

	for (size = 0; cpuset != 0; size++)
		cpuset &= cpuset - 1;
	return (size);
}

erx_status_t
erx_grant_normalize(const erx_grant_t *raw, uint64_t machine,
    erx_group_flags_t cap, erx_grant_t *result)
{
	erx_grant_t grant = *raw;
	size_t i;

	if (grant.base.raw > ERX_URGENCY_MAX ||
	    grant.ceiling.raw > ERX_URGENCY_MAX ||
	    (grant.flags & (erx_group_flags_t)~GROUP_FLAGS_DEFINED) != 0)
		return (ERX_EINVAL);
	for (i = 0; i < sizeof(grant.padding_0); i++) {
		if (grant.padding_0[i] != 0)
			return (ERX_EINVAL);
	}
	grant.period_ns = clamp_u64(grant.period_ns, ERX_PERIOD_MIN,
	    ERX_PERIOD_MAX);
	if (grant.quota_ns != ERX_QUOTA_NONE)
		grant.quota_ns = min_u64(grant.quota_ns,
		    grant.period_ns * cpuset_size(machine));
	grant.slice_us = clamp_u32(grant.slice_us, ERX_SLICE_MIN_US,
	    ERX_SLICE_MAX_US);
	grant.grace_us = clamp_u32(grant.grace_us, ERX_GRACE_MIN_US,
	    ERX_GRACE_MAX_US);
	grant.base.raw = min_u8(grant.base.raw, grant.ceiling.raw);
	grant.flags &= cap;
	*result = grant;
	return (ERX_OK);
}

/* Stores a normalized grant, field by field: include/erx/sched.h says why. */
static void
group_store(erx_sched_group_t *group, const erx_grant_t *grant)
{
	atomic_store_explicit(&group->quota_ns, grant->quota_ns,
	    memory_order_relaxed);
	atomic_store_explicit(&group->period_ns, grant->period_ns,
	    memory_order_relaxed);
	atomic_store_explicit(&group->cpuset, grant->cpuset,
	    memory_order_relaxed);
	atomic_store_explicit(&group->capacity_mcpu, grant->capacity_mcpu,
	    memory_order_relaxed);
	atomic_store_explicit(&group->capacity_first, grant->capacity_first,
	    memory_order_relaxed);
	atomic_store_explicit(&group->slice_us, grant->slice_us,
	    memory_order_relaxed);
	atomic_store_explicit(&group->grace_us, grant->grace_us,
	    memory_order_relaxed);
	atomic_store_explicit(&group->base, grant->base.raw,
	    memory_order_relaxed);
	atomic_store_explicit(&group->ceiling, grant->ceiling.raw,
	    memory_order_relaxed);
	atomic_store_explicit(&group->flags, grant->flags,
	    memory_order_relaxed);
}

/* The machine's CPUs, which only the root's record holds. */
static uint64_t
path_machine(const erx_sched_group_t *group)
{
	const erx_sched_group_t *level;

	for (level = group; level->parent != NULL; level = level->parent)
		continue;
	return (level->machine);
}

erx_status_t
erx_sched_root_init(erx_sched_group_t *root, uint64_t machine,
    const erx_grant_t *raw, erx_group_flags_t cap)
{
	erx_grant_t grant;
	erx_status_t error;

	error = erx_grant_normalize(raw, machine, cap, &grant);
	if (error != ERX_OK)
		return (error);
	if ((grant.cpuset & machine) == 0)
		return (ERX_EINVAL);
	root->parent = NULL;
	root->machine = machine;
	root->depth = 0;
	group_store(root, &grant);
	return (ERX_OK);
}

erx_status_t
erx_sched_group_init(erx_sched_group_t *group, const erx_sched_group_t *parent,
    const erx_grant_t *raw, erx_group_flags_t cap)
{
	erx_grant_t grant;
	erx_status_t error;

	error = erx_grant_normalize(raw, path_machine(parent), cap, &grant);
	if (error != ERX_OK)
		return (error);
	if (parent->depth + 1 >= ERX_GROUP_DEPTH_MAX)
		return (ERX_ELIMIT);
	group->parent = parent;
	group->machine = 0;
	group->depth = parent->depth + 1;
	group_store(group, &grant);
	return (ERX_OK);
}

erx_status_t
erx_sched_group_configure(erx_sched_group_t *group, const erx_grant_t *raw,
    erx_group_flags_t cap)
{
	erx_grant_t grant;
	erx_status_t error;

	error = erx_grant_normalize(raw, path_machine(group), cap, &grant);
	if (error != ERX_OK)
		return (error);
	if (group->parent == NULL && (grant.cpuset & group->machine) == 0)
		return (ERX_EINVAL);
	group_store(group, &grant);
	return (ERX_OK);
}

void
erx_sched_group_grant(const erx_sched_group_t *group, erx_grant_t *result)
{
	erx_grant_t grant = {0};

	grant.quota_ns = atomic_load_explicit(&group->quota_ns,
	    memory_order_relaxed);
	grant.period_ns = atomic_load_explicit(&group->period_ns,
	    memory_order_relaxed);
	grant.cpuset = atomic_load_explicit(&group->cpuset,
	    memory_order_relaxed);
	grant.capacity_mcpu = atomic_load_explicit(&group->capacity_mcpu,
	    memory_order_relaxed);
	grant.capacity_first = atomic_load_explicit(&group->capacity_first,
	    memory_order_relaxed);
	grant.slice_us = atomic_load_explicit(&group->slice_us,
	    memory_order_relaxed);
	grant.grace_us = atomic_load_explicit(&group->grace_us,
	    memory_order_relaxed);
	grant.base.raw = atomic_load_explicit(&group->base,
	    memory_order_relaxed);
	grant.ceiling.raw = atomic_load_explicit(&group->ceiling,
	    memory_order_relaxed);
	grant.flags = atomic_load_explicit(&group->flags,
	    memory_order_relaxed);
	*result = grant;
}

static uint8_t
path_ceiling(const erx_sched_group_t *group)
{
	const erx_sched_group_t *level;
	uint8_t ceiling = ERX_URGENCY_MAX;

	for (level = group; level != NULL; level = level->parent) {
		ceiling = min_u8(ceiling, atomic_load_explicit(&level->ceiling,
		    memory_order_relaxed));
	}
	return (ceiling);
}

erx_urgency_t
erx_sched_group_ceiling(const erx_sched_group_t *group)
{
	erx_urgency_t ceiling;

	ceiling.raw = path_ceiling(group);
	return (ceiling);
}

erx_urgency_t
erx_sched_group_base(const erx_sched_group_t *group)
{
	erx_urgency_t base;

	base.raw = min_u8(atomic_load_explicit(&group->base,
	    memory_order_relaxed), path_ceiling(group));
	return (base);
}

uint64_t
erx_sched_group_cpuset(const erx_sched_group_t *group)
{
	const erx_sched_group_t *level = group;
	uint64_t cpusets[ERX_GROUP_DEPTH_MAX];
	uint64_t effective, narrowed;
	uint32_t n = 0;

	cpusets[n++] = atomic_load_explicit(&level->cpuset, memory_order_relaxed);
	while (level->parent != NULL) {
		level = level->parent;
		cpusets[n++] = atomic_load_explicit(&level->cpuset,
		    memory_order_relaxed);
	}
	/* The fallback is defined from the root down; the root's meets the machine. */
	effective = level->machine & cpusets[--n];
	while (n > 0) {
		narrowed = effective & cpusets[--n];
		if (narrowed != 0)
			effective = narrowed;
	}
	return (effective);
}

uint64_t
erx_sched_group_slice_ns(const erx_sched_group_t *group)
{
	return (atomic_load_explicit(&group->slice_us, memory_order_relaxed) *
	    NS_PER_US);
}

/*
 * Thousandths of a CPU a quota per period pays for. Divided first, so that a
 * quota read from before a replacement and a period read from after one cannot
 * overflow: the remainder is below ERX_PERIOD_MAX.
 */
static uint64_t
quota_mcpu(uint64_t quota_ns, uint64_t period_ns)
{
	return (quota_ns / period_ns * MCPU_PER_CPU +
	    quota_ns % period_ns * MCPU_PER_CPU / period_ns);
}

erx_sched_capacity_t
erx_sched_group_capacity(const erx_sched_group_t *group)
{
	erx_sched_capacity_t capacity;
	uint64_t limit, quota_ns, period_ns;
	uint32_t cpus;

	cpus = cpuset_size(erx_sched_group_cpuset(group));
	limit = cpus * MCPU_PER_CPU;
	quota_ns = atomic_load_explicit(&group->quota_ns, memory_order_relaxed);
	period_ns = atomic_load_explicit(&group->period_ns,
	    memory_order_relaxed);
	if (quota_ns != ERX_QUOTA_NONE)
		limit = min_u64(limit, quota_mcpu(quota_ns, period_ns));
	capacity.mcpu = (uint32_t)min_u64(atomic_load_explicit(
	    &group->capacity_mcpu, memory_order_relaxed), limit);
	capacity.first = atomic_load_explicit(&group->capacity_first,
	    memory_order_relaxed) % cpus;
	return (capacity);
}

void
erx_sched_thread_init(erx_sched_thread_t *thread,
    const erx_sched_group_t *group)
{
	__builtin_memset(thread, 0, sizeof(*thread));
	thread->group = group;
	atomic_store_explicit(&thread->affinity, UINT64_MAX,
	    memory_order_relaxed);
	atomic_store_explicit(&thread->base, SCHED_BASE_OF_GROUP,
	    memory_order_relaxed);
	atomic_store_explicit(&thread->where, SCHED_WHERE_OFF,
	    memory_order_relaxed);
	atomic_store_explicit(&thread->last_cpu, ERX_SCHED_CPU_NONE,
	    memory_order_relaxed);
}

const erx_sched_group_t *
erx_sched_thread_group(const erx_sched_thread_t *thread)
{
	return (thread->group);
}

uint32_t
erx_sched_thread_on_cpu(const erx_sched_thread_t *thread)
{
	uint32_t where;

	where = atomic_load_explicit(&thread->where, memory_order_relaxed);
	if (where == SCHED_WHERE_OFF)
		return (ERX_SCHED_CPU_NONE);
	return (where >> SCHED_WHERE_STATE_BITS);
}

erx_status_t
erx_sched_thread_set_urgency(erx_sched_thread_t *thread, erx_urgency_t urgency)
{
	if (urgency.raw > ERX_URGENCY_MAX)
		return (ERX_EINVAL);
	atomic_store_explicit(&thread->base, urgency.raw, memory_order_relaxed);
	return (ERX_OK);
}

void
erx_sched_thread_set_affinity(erx_sched_thread_t *thread, uint64_t mask)
{
	atomic_store_explicit(&thread->affinity, mask, memory_order_relaxed);
}

erx_urgency_t
erx_sched_resolve(const erx_sched_thread_t *thread)
{
	erx_urgency_t urgency;
	uint8_t base;

	base = atomic_load_explicit(&thread->base, memory_order_relaxed);
	if (base == SCHED_BASE_OF_GROUP) {
		base = atomic_load_explicit(&thread->group->base,
		    memory_order_relaxed);
	}
	urgency.raw = min_u8(base, path_ceiling(thread->group));
	return (urgency);
}

uint64_t
erx_sched_thread_cpus(const erx_sched_thread_t *thread)
{
	uint64_t effective, allowed;

	effective = erx_sched_group_cpuset(thread->group);
	allowed = effective & atomic_load_explicit(&thread->affinity,
	    memory_order_relaxed);
	return (allowed != 0 ? allowed : effective);
}

uint32_t
erx_sched_place(const erx_sched_thread_t *thread, uint64_t idle)
{
	uint64_t allowed = erx_sched_thread_cpus(thread);
	uint64_t allowed_idle = allowed & idle;
	uint32_t last = atomic_load_explicit(&thread->last_cpu,
	    memory_order_relaxed);

	if (cpuset_has(allowed_idle, last))
		return (last);
	if (allowed_idle != 0)
		return (cpuset_lowest(allowed_idle));
	if (cpuset_has(allowed, last))
		return (last);
	return (cpuset_lowest(allowed));
}

erx_status_t
erx_sched_cpu_init(erx_sched_cpu_t *cpu, uint32_t index)
{
	if (index >= CPUSET_BITS)
		return (ERX_EINVAL);
	__builtin_memset(cpu, 0, sizeof(*cpu));
	cpu->index = index;
	return (ERX_OK);
}

/* A ready thread waits on the level of its stored urgency. */
static void
fifo_append(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread)
{
	sched_fifo_t *fifo = &cpu->levels[thread->urgency];

	thread->next = NULL;
	thread->prev = fifo->tail;
	if (fifo->tail != NULL)
		fifo->tail->next = thread;
	else
		fifo->head = thread;
	fifo->tail = thread;
	cpu->ready |= UINT64_C(1) << thread->urgency;
}

static void
fifo_prepend(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread)
{
	sched_fifo_t *fifo = &cpu->levels[thread->urgency];

	thread->prev = NULL;
	thread->next = fifo->head;
	if (fifo->head != NULL)
		fifo->head->prev = thread;
	else
		fifo->tail = thread;
	fifo->head = thread;
	cpu->ready |= UINT64_C(1) << thread->urgency;
}

/* Takes the thread off level, which is its stored urgency or the one before. */
static void
fifo_unlink(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread, uint8_t level)
{
	sched_fifo_t *fifo = &cpu->levels[level];

	if (thread->prev != NULL)
		thread->prev->next = thread->next;
	else
		fifo->head = thread->next;
	if (thread->next != NULL)
		thread->next->prev = thread->prev;
	else
		fifo->tail = thread->prev;
	thread->next = NULL;
	thread->prev = NULL;
	if (fifo->head == NULL)
		cpu->ready &= ~(UINT64_C(1) << level);
}
static void
thread_set_off(erx_sched_thread_t *thread)
{
	atomic_store_explicit(&thread->where, SCHED_WHERE_OFF,
	    memory_order_relaxed);
}

static void
thread_set_here(erx_sched_thread_t *thread, const erx_sched_cpu_t *cpu,
    sched_thread_state_t state)
{
	atomic_store_explicit(&thread->where, sched_where(state, cpu->index),
	    memory_order_relaxed);
}

static uint8_t
highest_level(const erx_sched_cpu_t *cpu)
{
	return ((uint8_t)(CPUSET_BITS - 1 -
	    (uint32_t)__builtin_clzll(cpu->ready)));
}

/* Whether a thread ready at urgency outranks what the CPU runs. */
static bool
must_pick(const erx_sched_cpu_t *cpu, uint8_t urgency)
{
	return (cpu->running == NULL || urgency > cpu->running->urgency);
}

/* Whether a ready thread outranks the running thread's urgency. */
static bool
ready_outranks(const erx_sched_cpu_t *cpu, uint8_t urgency)
{
	return (cpu->ready != 0 && highest_level(cpu) > urgency);
}

bool
erx_sched_wake(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread)
{
	if (atomic_load_explicit(&thread->where, memory_order_relaxed) !=
	    SCHED_WHERE_OFF)
		return (false);
	thread->urgency = erx_sched_resolve(thread).raw;
	thread_set_here(thread, cpu, SCHED_THREAD_READY);
	fifo_append(cpu, thread);
	return (must_pick(cpu, thread->urgency));
}

bool
erx_sched_refresh(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread)
{
	uint32_t where;
	uint8_t old = thread->urgency;

	where = atomic_load_explicit(&thread->where, memory_order_relaxed);
	if (where == sched_where(SCHED_THREAD_RUNNING, cpu->index)) {
		thread->urgency = erx_sched_resolve(thread).raw;
		return (ready_outranks(cpu, thread->urgency));
	}
	if (where != sched_where(SCHED_THREAD_READY, cpu->index))
		return (false);
	thread->urgency = erx_sched_resolve(thread).raw;
	if (thread->urgency != old) {
		fifo_unlink(cpu, thread, old);
		fifo_append(cpu, thread);
	}
	return (must_pick(cpu, thread->urgency));
}

bool
erx_sched_remove(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread)
{
	if (atomic_load_explicit(&thread->where, memory_order_relaxed) !=
	    sched_where(SCHED_THREAD_READY, cpu->index))
		return (false);
	fifo_unlink(cpu, thread, thread->urgency);
	thread_set_off(thread);
	return (true);
}

static bool
may_run_here(const erx_sched_cpu_t *cpu, const erx_sched_thread_t *thread)
{
	return (cpuset_has(erx_sched_thread_cpus(thread), cpu->index));
}

static void
decision_add_leaving(erx_sched_decision_t *decision, erx_sched_thread_t *thread)
{
	thread_set_off(thread);
	decision->leaving[decision->nleaving++] = thread;
}

/* The running thread gets the CPU for its slice: the rest it has, or a whole one. */
static void
pick_dispatch(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread,
    erx_sched_decision_t *decision)
{
	uint64_t slice_ns = erx_sched_group_slice_ns(thread->group);

	if (thread->slice_left_ns != 0 && thread->slice_left_ns < slice_ns)
		slice_ns = thread->slice_left_ns;
	thread->slice_left_ns = slice_ns;
	thread_set_here(thread, cpu, SCHED_THREAD_RUNNING);
	atomic_store_explicit(&thread->last_cpu, cpu->index,
	    memory_order_relaxed);
	cpu->running = thread;
	decision->run = thread;
	decision->slice_ns = slice_ns;
	decision->urgency.raw = thread->urgency;
}

/* The running thread gives up the CPU: it waits, leaves, or rejoins a level. */
static void
pick_outgoing(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread,
    erx_sched_why_t why, uint64_t ran_ns, erx_sched_decision_t *decision)
{
	thread->slice_left_ns = thread->slice_left_ns > ran_ns ?
	    thread->slice_left_ns - ran_ns : 0;
	if (why == ERX_PICK_SLICE_END)
		thread->slice_left_ns = 0;
	cpu->running = NULL;
	if (why == ERX_PICK_BLOCKED) {
		thread_set_off(thread);
		return;
	}
	if (!may_run_here(cpu, thread)) {
		decision_add_leaving(decision, thread);
		return;
	}
	thread->urgency = erx_sched_resolve(thread).raw;
	thread_set_here(thread, cpu, SCHED_THREAD_READY);
	/* A preempted thread with no slice left has come to its slice end. */
	if (why == ERX_PICK_PREEMPTED && thread->slice_left_ns != 0)
		fifo_prepend(cpu, thread);
	else
		fifo_append(cpu, thread);
}

void
erx_sched_pick(erx_sched_cpu_t *cpu, erx_sched_why_t why, uint64_t ran_ns,
    erx_sched_decision_t *result)
{
	erx_sched_decision_t decision = {0};
	erx_sched_thread_t *thread = cpu->running;
	uint32_t moves;

	if (thread != NULL)
		pick_outgoing(cpu, thread, why, ran_ns, &decision);
	/* An outgoing thread that left was this pick's first move. */
	moves = decision.nleaving;
	while (cpu->ready != 0) {
		thread = cpu->levels[highest_level(cpu)].head;
		if (may_run_here(cpu, thread)) {
			fifo_unlink(cpu, thread, thread->urgency);
			pick_dispatch(cpu, thread, &decision);
			break;
		}
		if (moves == ERX_PICK_MOVES) {
			decision.again = true;
			break;
		}
		moves++;
		fifo_unlink(cpu, thread, thread->urgency);
		decision_add_leaving(&decision, thread);
	}
	*result = decision;
}
