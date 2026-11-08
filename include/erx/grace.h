/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_GRACE_H
#define ERX_GRACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/cdefs.h"

/*
 * The grace tracker (docs/design-kernel.md, "The reaper", **Stamps**): the
 * read-copy-update grace periods that every release of a page, put of a
 * destroyed object and free of a record waits for, as Fiasco's Rcu_glbl
 * keeps its batches.
 *
 * The tracker keeps two counts, the current period and the last completed
 * one. The current count is at most one above the completed one, and a
 * period is in progress exactly while it is. A period starts with the set
 * of active CPUs it must hear from and completes when each of them has
 * reported a quiescent point, at which it holds no pointer to anything
 * retired before the report.
 *
 * An item is retired once nothing can reach it any more, through
 * erx_grace_retire, which returns its stamp: the period that begins after
 * the retirement. The item is mature, and may be freed, once the completed
 * count has reached its stamp. A period already in progress may have heard
 * from a CPU before the retirement, so its completion proves nothing about
 * the item; the next period hears from every active CPU after it. So an
 * item matures after the rest of the period in progress and one whole
 * period, fewer than two grace periods.
 *
 * The counts never wrap: the current count advances only when a period
 * completes, at most once per pass of every CPU through a quiescent point,
 * so at one advance a nanosecond it reaches ERX_GRACE_COUNT_LAST after 584
 * years. A retire that would need a period beyond it traps rather than
 * wrap, an end no user-mode thread can bring about (K12), so stamps are
 * compared as plain integers. Host tests build the tracker with a small
 * ERX_GRACE_COUNT_LAST to reach that end.
 *
 * The tracker keeps the set of online CPUs, one bit per CPU as a cpuset
 * is, so CPUs are numbered below ERX_CPUSET_BITS and a larger number is
 * a kernel bug that traps; the scheduler reports each CPU's joining,
 * leaving and quiescent points. The record is opaque outside
 * the tracker: its definition is in kernel/core/grace_impl.h, which only
 * kernel/core/grace.c and its host tests include, so the counts are written
 * nowhere else. The tracker takes its own lock, a ticket lock at level 9 of
 * the kernel's order (K13), through erx_effect_grace_lock, around each
 * call that changes it, and only kernel/core/grace.c names that effect.
 */

#ifndef ERX_GRACE_COUNT_LAST
#define ERX_GRACE_COUNT_LAST	UINT64_MAX
#endif

typedef struct erx_grace erx_grace_t;
typedef struct erx_grace_counts erx_grace_counts_t;

/* A snapshot of the tracker, for tests and the inspector. */
struct erx_grace_counts {
	uint64_t	current;	/* the newest period started */
	uint64_t	completed;	/* the newest period completed */
	uint64_t	awaited;	/* CPUs the current period has not heard
					 * from; 0 when none is in progress */
	uint64_t	online;		/* CPUs the next period will await */
	bool		pending;	/* the period after the current one is
					 * requested */
};

/* The effects a host of the tracker provides: its lock. */
void	erx_effect_grace_lock(erx_grace_t *);
void	erx_effect_grace_unlock(erx_grace_t *);

/* Size and alignment of the record, for the kernel that holds it. */
size_t	erx_grace_record_size(void);
size_t	erx_grace_record_align(void);

/* No period started or completed, none in progress, and no CPU online. */
void	erx_grace_init(erx_grace_t *);

/*
 * A CPU comes online: the next period to start awaits it. The period in
 * progress does not, since the CPU took nothing retired before it joined.
 */
void	erx_grace_cpu_join(erx_grace_t *, uint32_t cpu);

/*
 * A CPU goes offline, at a quiescent point: it counts as its report for
 * the period in progress, and no later period awaits it, so a period never
 * waits for a CPU that will not report. When it was the last awaited, the
 * period completes, and a requested next period starts at once over the
 * CPUs still online, completing at once if none is. Returns true when a
 * period completed.
 */
bool	erx_grace_cpu_leave(erx_grace_t *, uint32_t cpu);

/*
 * Retires an item and returns its stamp, the current count plus one: when
 * no period is in progress it starts that period, awaiting every online
 * CPU, and otherwise requests it, so that the completion of the period in
 * progress starts it at once. The calling CPU is online; no CPU online, or
 * a stamp beyond ERX_GRACE_COUNT_LAST, is a kernel bug and traps.
 */
uint64_t erx_grace_retire(erx_grace_t *) ERX_WARN_UNUSED_RESULT;

/*
 * Reports that cpu has passed a quiescent point, at which it holds no
 * pointer to a retired item. A CPU the period in progress still awaits is
 * counted; any other report changes nothing. When the last awaited CPU
 * reports, the period completes, and a requested next period starts at
 * once over the online CPUs. Returns true when a period completed.
 */
bool	erx_grace_report(erx_grace_t *, uint32_t cpu);

/*
 * Whether an item with this stamp is mature: the completed count has
 * reached it. Read without the lock; the count only advances, so a stale
 * read only answers later.
 */
bool	erx_grace_mature(const erx_grace_t *, uint64_t stamp);

void	erx_grace_read(erx_grace_t *, erx_grace_counts_t *);

#endif /* ERX_GRACE_H */
