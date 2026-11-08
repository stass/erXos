/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The grace tracker (docs/design-kernel.md, "The reaper", **Stamps**).
 * Each public call that changes the tracker takes its lock through the
 * effect and makes one decision over the record: retire, which stamps an
 * item and requests the period after the current one; report and leave,
 * which count a CPU's quiescent point and complete a period when it was
 * the last one awaited; and join. Completing a period, and starting the
 * requested next one, is the one step report and leave share.
 *
 * The completed count is the only field read without the lock, by
 * erx_grace_mature: it is stored with release order after the period's
 * last report, so a reader that sees the new count also sees everything
 * the CPUs did before they reported.
 */

#include "erx/abi.h"

#include "grace_impl.h"

_Static_assert(ERX_CPUSET_BITS <= 64,
    "a CPU's bit is a shift of a 64-bit word");
_Static_assert(ERX_GRACE_COUNT_LAST >= 2,
    "a tracker needs room for a period in progress and one requested");

/* Whether a period is in progress: the current count is one ahead. */
static bool
in_progress(const erx_grace_t *tracker)
{
	return (tracker->current !=
	    atomic_load_explicit(&tracker->completed, memory_order_relaxed));
}

/* The bit of a CPU; a CPU no cpuset can name is a kernel bug. */
static uint64_t
cpu_bit(uint32_t cpu)
{
	if (cpu >= ERX_CPUSET_BITS)
		__builtin_trap();
	return (UINT64_C(1) << cpu);
}

/*
 * Completes the period in progress once it awaits no CPU, and starts a
 * requested next one over the online CPUs, which completes at once in
 * turn when none is online: no CPU can hold anything then. Returns true
 * when a period completed.
 */
static bool
settle(erx_grace_t *tracker)
{
	bool completed;

	completed = false;
	while (in_progress(tracker) && tracker->awaited == 0) {
		atomic_store_explicit(&tracker->completed, tracker->current,
		    memory_order_release);
		completed = true;
		if (!tracker->pending)
			break;
		tracker->current++;
		tracker->awaited = tracker->online;
		tracker->pending = false;
	}
	return (completed);
}

size_t
erx_grace_record_size(void)
{
	return (sizeof(erx_grace_t));
}

size_t
erx_grace_record_align(void)
{
	return (_Alignof(erx_grace_t));
}

void
erx_grace_init(erx_grace_t *tracker)
{
	tracker->current = 0;
	atomic_init(&tracker->completed, 0);
	tracker->awaited = 0;
	tracker->online = 0;
	tracker->pending = false;
}

void
erx_grace_cpu_join(erx_grace_t *tracker, uint32_t cpu)
{
	uint64_t bit;

	bit = cpu_bit(cpu);
	erx_effect_grace_lock(tracker);
	tracker->online |= bit;
	erx_effect_grace_unlock(tracker);
}

bool
erx_grace_cpu_leave(erx_grace_t *tracker, uint32_t cpu)
{
	uint64_t bit;
	bool completed;

	bit = cpu_bit(cpu);
	erx_effect_grace_lock(tracker);
	tracker->online &= ~bit;
	tracker->awaited &= ~bit;
	completed = settle(tracker);
	erx_effect_grace_unlock(tracker);
	return (completed);
}

/*
 * The stamp names the period after the current one, which begins after
 * this retirement: started here when none is in progress, or requested
 * from the one in progress, which may have heard from a CPU before the
 * retirement. Both cases need room for current + 1.
 */
uint64_t
erx_grace_retire(erx_grace_t *tracker)
{
	uint64_t stamp;

	erx_effect_grace_lock(tracker);
	if (tracker->online == 0 || tracker->current == ERX_GRACE_COUNT_LAST)
		__builtin_trap();
	stamp = tracker->current + 1;
	if (in_progress(tracker)) {
		tracker->pending = true;
	} else {
		tracker->current = stamp;
		tracker->awaited = tracker->online;
	}
	erx_effect_grace_unlock(tracker);
	return (stamp);
}

bool
erx_grace_report(erx_grace_t *tracker, uint32_t cpu)
{
	uint64_t bit;
	bool completed;

	bit = cpu_bit(cpu);
	completed = false;
	erx_effect_grace_lock(tracker);
	if (in_progress(tracker) && (tracker->awaited & bit) != 0) {
		tracker->awaited &= ~bit;
		completed = settle(tracker);
	}
	erx_effect_grace_unlock(tracker);
	return (completed);
}

bool
erx_grace_mature(const erx_grace_t *tracker, uint64_t stamp)
{
	return (atomic_load_explicit(&tracker->completed,
	    memory_order_acquire) >= stamp);
}

void
erx_grace_read(erx_grace_t *tracker, erx_grace_counts_t *counts)
{
	erx_effect_grace_lock(tracker);
	*counts = (erx_grace_counts_t){
		.current = tracker->current,
		.completed = atomic_load_explicit(&tracker->completed,
		    memory_order_relaxed),
		.awaited = tracker->awaited,
		.online = tracker->online,
		.pending = tracker->pending,
	};
	erx_effect_grace_unlock(tracker);
}
