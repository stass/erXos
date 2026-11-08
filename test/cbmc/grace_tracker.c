/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: the grace tracker (kernel/core/grace.c), the promise
 * every deferred free rests on. A stamp from erx_grace_retire matures only
 * once every CPU that was online at the retirement has passed a quiescent
 * point after it, or gone offline.
 *
 * Bounds: the tracker starts in any state the record invariant allows, at
 * full 64-bit counts and over all 64 CPU bits, so one run covers every
 * reachable state rather than those a few steps from erx_grace_init. One
 * retirement is followed by GRACE_STEPS calls, each a join, leave, report
 * or further retirement of any CPU. The harness's loop is unwound
 * GRACE_STEPS + 1 times and settle's at most three: it completes one
 * period, starts the requested next one and completes that only when no
 * CPU is online, which leaves nothing requested.
 *
 * Assumptions: the callers keep the tracker's contract, as its traps
 * demand: a CPU below ERX_CPUSET_BITS, and a retirement with a CPU online
 * and room for the next count. The lock effects are stubs that check
 * their own pairing; one thread.
 *
 * Checked, after the retirement and after every later call: the record
 * invariant (the current count at most one ahead of the completed one, the
 * awaited CPUs online, nothing awaited or requested without a period in
 * progress); the stamp is the period after the one in progress; and the
 * stamp matures only when none of the CPUs it owes is still owed. A
 * ghost set, "owed", starts as the CPUs online at the retirement and loses
 * a CPU at its next report or its leave; it is never larger than what the
 * tracker must still hear, so the property is the tracker's promise.
 */

#include "cbmc_harness.h"
#include "grace.c"

#ifndef GRACE_STEPS
#define GRACE_STEPS	4
#endif

static erx_grace_t tracker;
static bool locked;

void
erx_effect_grace_lock(erx_grace_t *held)
{
	__CPROVER_assert(held == &tracker && !locked,
	    "the tracker's lock is taken once, on its own record");
	locked = true;
}

void
erx_effect_grace_unlock(erx_grace_t *held)
{
	__CPROVER_assert(held == &tracker && locked,
	    "the tracker's lock is released only when held");
	locked = false;
}

/* The record invariant every call keeps under the lock. */
static void
check_record(void)
{
	uint64_t completed = atomic_load_explicit(&tracker.completed,
	    memory_order_relaxed);

	__CPROVER_assert(tracker.current == completed ||
	    (completed != UINT64_MAX && tracker.current == completed + 1),
	    "the current count is the completed one or one ahead");
	__CPROVER_assert((tracker.awaited & ~tracker.online) == 0,
	    "only online CPUs are awaited");
	__CPROVER_assert(in_progress(&tracker) ||
	    (tracker.awaited == 0 && !tracker.pending),
	    "nothing is awaited or requested without a period in progress");
	__CPROVER_assert(!in_progress(&tracker) || tracker.awaited != 0,
	    "a period in progress awaits some CPU");
	__CPROVER_assert(!locked, "every call releases the tracker's lock");
}

static bool
may_retire(void)
{
	return (tracker.online != 0 && tracker.current != ERX_GRACE_COUNT_LAST);
}

void
harness(void)
{
	uint64_t completed = nondet_u64();
	uint64_t stamp, owed, before;
	uint32_t cpu, step, op;

	/* Any state the record invariant allows. */
	tracker.current = nondet_u64();
	atomic_init(&tracker.completed, completed);
	tracker.awaited = nondet_u64();
	tracker.online = nondet_u64();
	tracker.pending = nondet_bool();
	__CPROVER_assume(tracker.current == completed ||
	    (completed != UINT64_MAX && tracker.current == completed + 1));
	__CPROVER_assume((tracker.awaited & ~tracker.online) == 0);
	__CPROVER_assume(in_progress(&tracker) ||
	    (tracker.awaited == 0 && !tracker.pending));
	/* A period in progress awaits some CPU, or settle would have ended it. */
	__CPROVER_assume(!in_progress(&tracker) || tracker.awaited != 0);

	__CPROVER_assume(may_retire());
	before = tracker.current;
	stamp = erx_grace_retire(&tracker);
	owed = tracker.online;
	__CPROVER_assert(stamp == before + 1,
	    "a stamp names the period after the one in progress");
	__CPROVER_assert(!erx_grace_mature(&tracker, stamp),
	    "a stamp is not mature when it is issued");
	check_record();

	for (step = 0; step < GRACE_STEPS; step++) {
		cpu = nondet_u32();
		op = nondet_u32();
		__CPROVER_assume(cpu < ERX_CPUSET_BITS);
		switch (op) {
		case 0:
			erx_grace_cpu_join(&tracker, cpu);
			break;
		case 1:
			(void)erx_grace_cpu_leave(&tracker, cpu);
			owed &= ~(UINT64_C(1) << cpu);
			break;
		case 2:
			(void)erx_grace_report(&tracker, cpu);
			owed &= ~(UINT64_C(1) << cpu);
			break;
		default:
			__CPROVER_assume(may_retire());
			(void)erx_grace_retire(&tracker);
			break;
		}
		check_record();
		__CPROVER_assert(!erx_grace_mature(&tracker, stamp) || owed == 0,
		    "a stamp matures only after every CPU it owes has reported or left");
	}
}
