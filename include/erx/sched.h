/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_SCHED_H
#define ERX_SCHED_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The scheduler core for configuration C0: fixed-priority round robin over
 * threads (docs/design-scheduler.md). It decides three things and acts on
 * none of them:
 *
 * - what a grant from user mode may be: erx_grant_normalize checks it and
 *   applies every limit that depends on nothing but the grant;
 * - what a thread's limits are now: its CPUs are derived from the current
 *   grants on its group path at each decision; its urgency is resolved from
 *   them and stored at each of its own transitions and by erx_sched_refresh,
 *   which the caller makes for every thread a changed base or ceiling reaches
 *   before that change's call returns (S5);
 * - what each CPU runs next: erx_sched_pick, over that CPU's ready queues.
 *
 * Who may touch what. A group's grant and a thread's base and affinity are
 * written by any CPU and read at decisions on others, with one relaxed atomic
 * load per field per check, so a check sees each field from before a
 * replacement or after it, never torn. Calls that replace one group's grant
 * are serialized by the caller. Every record is published to other CPUs with
 * release ordering or stronger before any of them is given its address.
 *
 * Each CPU's queues belong to that CPU: its caller is the home CPU of every
 * thread it names, in erx_sched_wake, erx_sched_refresh, erx_sched_remove and
 * erx_sched_pick, with interrupts masked. This core decides on one CPU and
 * defines no protocol between CPUs: docs/design-scheduler.md, "Concurrency",
 * does, and no code calls erx_sched_pick across CPUs before that protocol's
 * model passes.
 *
 * The records are opaque outside the core: their definitions are in
 * kernel/sched/sched_impl.h, which only kernel/sched/sched.c and its host
 * tests include. So the group a thread is charged to is written once, by
 * erx_sched_thread_init (S6), and every grant in a record has passed
 * erx_grant_normalize.
 */

/* A grant is its wire layout (docs/design-abi.md, "Types, limits and references"). */
typedef erx_share_t erx_grant_t;

typedef struct erx_sched_group erx_sched_group_t;
typedef struct erx_sched_thread erx_sched_thread_t;
typedef struct erx_sched_cpu erx_sched_cpu_t;

/* The features configuration C0 lets a group enable: none. */
#define ERX_SCHED_C0_FLAGS	((erx_group_flags_t)0)

/* The most threads one pick moves away from its CPU. */
#define ERX_PICK_MOVES		8

/* The CPU of a thread that has none; no cpuset names it. */
#define ERX_SCHED_CPU_NONE	UINT32_C(64)

/* Why the running thread gives up its CPU. */
typedef enum erx_sched_why {
	ERX_PICK_BLOCKED,	/* it waits, parks or dies: it leaves the queues */
	ERX_PICK_SLICE_END,	/* it joins the tail with a fresh slice */
	ERX_PICK_YIELD,		/* it joins the tail, keeping the rest of its slice */
	ERX_PICK_PREEMPTED	/* it rejoins the head with the rest of its slice */
} erx_sched_why_t;

/*
 * What a pick leaves for the caller to do. run is the thread to switch to,
 * for slice_ns at the given urgency; NULL means the idle thread, and the
 * thread that gave up the CPU means no switch at all, as a yield with nothing
 * else ready at its level or above finds. again means the pick reached
 * ERX_PICK_MOVES before it found a thread: the idle thread takes pending
 * interrupts and the CPU picks again, so a pick's work never grows with the
 * number of ready threads. Each thread in leaving may no longer run on this CPU
 * and is on no queue: the caller places it with erx_sched_place and has it woken
 * there, after the switch.
 */
typedef struct erx_sched_decision {
	erx_sched_thread_t	*run;
	uint64_t		 slice_ns;
	erx_urgency_t		 urgency;
	bool			 again;
	uint32_t		 nleaving;
	erx_sched_thread_t	*leaving[ERX_PICK_MOVES];
} erx_sched_decision_t;

/* What a group's status area advises: its capacity and where its run starts. */
typedef struct erx_sched_capacity {
	uint32_t	mcpu;
	uint32_t	first;
} erx_sched_capacity_t;

/* Size and alignment of each record, for the kernel object that holds it. */
size_t	erx_sched_group_record_size(void);
size_t	erx_sched_group_record_align(void);
size_t	erx_sched_thread_record_size(void);
size_t	erx_sched_thread_record_align(void);
size_t	erx_sched_cpu_record_size(void);
size_t	erx_sched_cpu_record_align(void);

/*
 * Checks a grant whose every field a domain chose and writes it with the
 * limits that depend on nothing but the grant applied. raw is a private
 * copy the caller made once from the caller's UTCB, never the UTCB itself,
 * since this reads each field more than once. Period, slice and grace clamped
 * into their ranges, a finite quota capped at the period times the CPUs of
 * machine, more than any period can spend, so it fits a pool's int64_t, base
 * clamped to the ceiling, flags masked by the machine-wide cap. ERX_EINVAL for
 * an urgency above ERX_URGENCY_MAX, a flag erXos does not define, or non-zero
 * padding; nothing else in a grant is refused. result is written only on
 * success, and normalizing a normalized grant changes nothing.
 */
erx_status_t	erx_grant_normalize(const erx_grant_t *raw, uint64_t machine,
		    erx_group_flags_t cap, erx_grant_t *result);

/*
 * Creates the root group of a machine whose CPUs are machine, the mask the
 * kernel found at boot. Every effective cpuset lies within it, so no decision
 * names a CPU that does not exist. A fallback ends at the root, so a cpuset
 * that misses machine is ERX_EINVAL.
 */
erx_status_t	erx_sched_root_init(erx_sched_group_t *root, uint64_t machine,
		    const erx_grant_t *raw, erx_group_flags_t cap);

/* Creates a group under parent: ERX_EINVAL (grant), ERX_ELIMIT (depth). */
erx_status_t	erx_sched_group_init(erx_sched_group_t *group,
		    const erx_sched_group_t *parent, const erx_grant_t *raw,
		    erx_group_flags_t cap);

/*
 * Replaces a group's grant whole, or on ERX_EINVAL leaves it as it was. A
 * cpuset that misses the machine is ERX_EINVAL at the root, as at its
 * creation. A changed base or ceiling reaches a thread through
 * erx_sched_refresh, and every other limit at the thread's next decision.
 */
erx_status_t	erx_sched_group_configure(erx_sched_group_t *group,
		    const erx_grant_t *raw, erx_group_flags_t cap);

/*
 * The grant, for erx_group_info: each field normalized and loaded once, from
 * before a replacement or after it.
 */
void		erx_sched_group_grant(const erx_sched_group_t *group,
		    erx_grant_t *result);

/*
 * Limits derived from the grants on the group's path as they are now.
 * ceiling is the least ceiling on the path, and base the group's base
 * beneath it. cpuset is the root's within the machine, narrowed by each group
 * below it, a group whose intersection would be empty keeping its parent's;
 * it is never empty and names only CPUs the machine has.
 */
erx_urgency_t	erx_sched_group_ceiling(const erx_sched_group_t *group);
erx_urgency_t	erx_sched_group_base(const erx_sched_group_t *group);
uint64_t	erx_sched_group_cpuset(const erx_sched_group_t *group);
uint64_t	erx_sched_group_slice_ns(const erx_sched_group_t *group);

/*
 * The capacity to publish: as configured, clamped to the group's effective
 * cpuset and to its quota per period; the run's first position, modulo the
 * size of that cpuset.
 */
erx_sched_capacity_t erx_sched_group_capacity(const erx_sched_group_t *group);

/*
 * Creates a thread record in group, which it is charged to for life. The
 * thread takes its group's base until erx_sched_thread_set_urgency gives it
 * one, may run on every CPU of its group until erx_sched_thread_set_affinity
 * narrows it, and is on no queue until it is woken.
 */
void		erx_sched_thread_init(erx_sched_thread_t *thread,
		    const erx_sched_group_t *group);

/* The group the thread is charged to, as erx_sched_thread_init fixed it. */
const erx_sched_group_t *erx_sched_thread_group(const erx_sched_thread_t *thread);

/*
 * The CPU whose queues or running slot hold the thread now, or
 * ERX_SCHED_CPU_NONE for a sleeper. Readable anywhere, but only a hint unless
 * the caller has serialized the thread: it can change as soon as this returns.
 * This is not the thread's home CPU, and a poster of a refresh never skips a
 * thread on what this says.
 */
uint32_t	erx_sched_thread_on_cpu(const erx_sched_thread_t *thread);

/* Sets the thread's base: ERX_EINVAL above ERX_URGENCY_MAX. */
erx_status_t	erx_sched_thread_set_urgency(erx_sched_thread_t *thread,
		    erx_urgency_t urgency);
void		erx_sched_thread_set_affinity(erx_sched_thread_t *thread,
		    uint64_t mask);

/* The thread's urgency now: its base beneath the least ceiling on its path. */
erx_urgency_t	erx_sched_resolve(const erx_sched_thread_t *thread);

/*
 * The CPUs the thread may run on now: its affinity within its group's
 * effective cpuset, or the whole of that cpuset when they do not meet. Never
 * empty.
 */
uint64_t	erx_sched_thread_cpus(const erx_sched_thread_t *thread);

/*
 * The CPU a woken thread goes to, given the CPUs that idle: the one it last
 * ran on if allowed and idle, else the lowest-numbered allowed idle CPU,
 * else the one it last ran on if allowed, else the lowest-numbered allowed.
 * The idle search is ERX_GROUP_PLACE's: in C0 and C1 the caller passes no
 * idle CPU, so a thread stays where it last ran unless that CPU has left its
 * set.
 */
uint32_t	erx_sched_place(const erx_sched_thread_t *thread, uint64_t idle);

/* Creates the ready queues of CPU index: ERX_EINVAL if no cpuset names it. */
erx_status_t	erx_sched_cpu_init(erx_sched_cpu_t *cpu, uint32_t index);

/*
 * Makes a thread ready on this CPU, at the tail of its level. A thread already
 * ready or running joins no second time.
 * Returns true when the CPU must pick now: it runs nothing, or a less urgent
 * thread than the one woken, in which case the caller passes
 * ERX_PICK_PREEMPTED.
 */
bool		erx_sched_wake(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread);

/*
 * Resolves a thread again after its base or a ceiling on its path changed, on
 * its home CPU. A ready thread whose urgency changed moves to the tail of its
 * new level. Returns true when the CPU must pick now, in which case the caller
 * passes ERX_PICK_PREEMPTED: a ready thread now outranks what the CPU runs, or
 * the CPU runs nothing. Returns false, changing nothing, for a thread neither
 * ready nor running on this CPU: a sleeper resolves at its wake.
 */
bool		erx_sched_refresh(erx_sched_cpu_t *cpu, erx_sched_thread_t *thread);

/*
 * Takes a ready thread off this CPU's queues, for a kill or a stop. Returns
 * false, changing nothing, for a thread not ready on this CPU; a running
 * thread leaves through erx_sched_pick with ERX_PICK_BLOCKED.
 */
bool		erx_sched_remove(erx_sched_cpu_t *cpu,
		    erx_sched_thread_t *thread);

/*
 * The one scheduling decision of a CPU: the running thread, having run for
 * ran_ns since it was dispatched, gives up the CPU for the reason given and
 * the next thread is chosen. On a CPU that runs nothing, why and ran_ns mean
 * nothing. Takes the head of the highest non-empty level, whose level is its
 * urgency; one that may no longer run here leaves, ERX_PICK_MOVES in all. The
 * outgoing thread is resolved if it rejoins the queues.
 */
void		erx_sched_pick(erx_sched_cpu_t *cpu, erx_sched_why_t why,
		    uint64_t ran_ns, erx_sched_decision_t *result);

#endif /* ERX_SCHED_H */
