/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H
#define ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H

/*
 * erx_group_configure and erx_group_info over a caller's UTCB, the same on both backends
 * (docs/design-stopgap.md, "Interrupts and readiness"). Of a grant only the CPU set is
 * kept; the report's usage says it is not measured, and its counts are the status page's.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

#define ERX_GROUP_GRANT_WORDS	(sizeof(erx_share_t) / sizeof(uint64_t))
#define ERX_GROUP_REPORT_WORDS	(sizeof(erx_group_report_t) / sizeof(uint64_t))

typedef union erx_group_grant_words {
	erx_share_t	grant;
	uint64_t	words[ERX_GROUP_GRANT_WORDS];
} erx_group_grant_words_t;

typedef union erx_group_report_words {
	erx_group_report_t report;
	uint64_t	words[ERX_GROUP_REPORT_WORDS];
} erx_group_report_words_t;

_Static_assert(sizeof(erx_group_grant_words_t) == sizeof(erx_share_t), "a grant is whole message registers");
_Static_assert(sizeof(erx_group_report_words_t) == sizeof(erx_group_report_t), "a report is whole message registers");

/* What a caller of erx_group_configure puts in its UTCB. */
static inline void
erx_group_grant_store(erx_utcb_t *utcb, const erx_share_t *grant)
{
	const erx_group_grant_words_t copy = { .grant = *grant };

	for (size_t word = 0; word < ERX_GROUP_GRANT_WORDS; word++)
		atomic_store_explicit(&utcb->mr[word], copy.words[word], memory_order_relaxed);
}

/* What a caller of erx_group_info takes from its UTCB. */
static inline erx_group_report_t
erx_group_report_load(const erx_utcb_t *utcb)
{
	erx_group_report_words_t copy;

	for (size_t word = 0; word < ERX_GROUP_REPORT_WORDS; word++)
		copy.words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	return (copy.report);
}

/* Replaces the kept CPU set with the grant's in the UTCB. An empty one is ERX_EINVAL and changes nothing. */
static inline int
erx_backend_group_configure(const erx_utcb_t *utcb, _Atomic uint64_t *cpuset)
{
	erx_group_grant_words_t copy;

	for (size_t word = 0; word < ERX_GROUP_GRANT_WORDS; word++)
		copy.words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	if (copy.grant.cpuset == 0)
		return (ERX_EINVAL);
	atomic_store_explicit(cpuset, copy.grant.cpuset, memory_order_relaxed);
	return (ERX_OK);
}

/* A CPU set no one configured reports as zero capacity: nothing is known of it. */
static inline void
erx_backend_group_report(erx_utcb_t *utcb, const erx_group_stat_t *status, const _Atomic uint64_t *cpuset)
{
	const uint64_t kept = atomic_load_explicit(cpuset, memory_order_relaxed);
	const erx_group_report_words_t copy = { .report = { .cpuset = kept,
	    .capacity_mcpu = (uint32_t)__builtin_popcountll(kept) * UINT32_C(1000),
	    .parked = atomic_load_explicit(&status->parked, memory_order_relaxed),
	    .ready = atomic_load_explicit(&status->ready, memory_order_relaxed) } };

	for (size_t word = 0; word < ERX_GROUP_REPORT_WORDS; word++)
		atomic_store_explicit(&utcb->mr[word], copy.words[word], memory_order_relaxed);
}

#endif /* ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H */
