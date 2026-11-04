/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_SCHED_IMPL_H
#define ERX_SCHED_IMPL_H

/*
 * The scheduler core's records. Only kernel/sched/sched.c and the core's
 * host tests include this file, which the sched-records-private chokepoint
 * enforces, so every write of a grant, a group pointer or a queue link is in
 * sched.c.
 */

#include <stdatomic.h>

#include "erx/sched.h"

#define SCHED_LEVELS		(ERX_URGENCY_MAX + 1)
/* A thread's base when it has none of its own; no urgency can name it. */
#define SCHED_BASE_OF_GROUP	UINT8_MAX

struct erx_sched_group {
	const erx_sched_group_t	*parent;	/* NULL for the root; fixed */
	uint64_t		 machine;	/* the root's alone: the machine's CPUs,
						 * which bound its cpuset; fixed */
	uint32_t		 depth;		/* 0 for the root; fixed; below
						 * ERX_GROUP_DEPTH_MAX, which
						 * bounds every walk of a path */
	/* The grant as normalized; the root's cpuset always meets machine. */
	_Atomic uint64_t	 quota_ns;
	_Atomic uint64_t	 period_ns;
	_Atomic uint64_t	 cpuset;
	_Atomic uint32_t	 capacity_mcpu;
	_Atomic uint32_t	 capacity_first;
	_Atomic uint32_t	 slice_us;
	_Atomic uint32_t	 grace_us;
	_Atomic uint8_t		 base;
	_Atomic uint8_t		 ceiling;
	_Atomic uint16_t	 flags;
};

/*
 * Where a thread is: its state and its CPU's index in one word, so the two
 * cannot disagree. Atomic so that erx_sched_thread_home can read it anywhere.
 */
typedef enum sched_thread_state {
	SCHED_THREAD_OFF,	/* on no queue and no CPU; the word is zero */
	SCHED_THREAD_READY,	/* on a level of that CPU's queues */
	SCHED_THREAD_RUNNING	/* that CPU's running thread */
} sched_thread_state_t;

#define SCHED_WHERE_STATE_BITS	2
#define SCHED_WHERE_OFF		UINT32_C(0)

static inline uint32_t
sched_where(sched_thread_state_t state, uint32_t cpu)
{
	return ((uint32_t)state | cpu << SCHED_WHERE_STATE_BITS);
}

static inline sched_thread_state_t
sched_where_state(uint32_t where)
{
	return ((sched_thread_state_t)(where &
	    ((UINT32_C(1) << SCHED_WHERE_STATE_BITS) - 1)));
}

struct erx_sched_thread {
	const erx_sched_group_t	*group;		/* fixed at creation (S6) */
	_Atomic uint64_t	 affinity;
	_Atomic uint32_t	 where;		/* sched_where(); see below */
	_Atomic uint32_t	 last_cpu;	/* ERX_SCHED_CPU_NONE before it first runs */
	_Atomic uint8_t		 base;		/* SCHED_BASE_OF_GROUP until set */
	/* The rest is serialized by the caller: see include/erx/sched.h. */
	erx_sched_thread_t	*next;		/* its level's FIFO, while ready */
	erx_sched_thread_t	*prev;
	uint64_t		 slice_left_ns;	/* 0: a fresh slice at its dispatch */
	uint8_t			 urgency;	/* while ready, its FIFO's level; while ready or
						 * running, written only as its own resolve
						 * (S5) */
};

typedef struct sched_fifo {
	erx_sched_thread_t	*head;
	erx_sched_thread_t	*tail;
} sched_fifo_t;

struct erx_sched_cpu {
	sched_fifo_t		 levels[SCHED_LEVELS];
	uint64_t		 ready;		/* bit n: levels[n] is not empty */
	erx_sched_thread_t	*running;	/* NULL while it idles */
	uint32_t		 index;
};

#endif /* ERX_SCHED_IMPL_H */
