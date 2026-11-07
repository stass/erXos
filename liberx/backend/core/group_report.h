/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H
#define ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H

/*
 * erx_group_configure and erx_group_info over a caller's UTCB, the same on both backends
 * (docs/design-stopgap.md, "Interrupts and readiness"). Of a grant only the CPU set is
 * kept. The report, an erx_info_group, marks reported only what the backend has with its
 * full meaning (docs/design-stopgap.md, "Reporting kernel objects"): the kept set once one
 * is configured, and the status page's counts; never capacity_mcpu or used_ns.
 *
 * It also holds the reporters' console line, apart from erx_group_info's report: the
 * executors a status page holds, and erx_group_report_line, the "parked N of M" line both
 * backends write under erx.group_report=1 and ERX_HOSTED_GROUP_REPORT.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

#define ERX_GROUP_GRANT_WORDS	(sizeof(erx_share_t) / sizeof(uint64_t))
#define ERX_INFO_GROUP_WORDS	(sizeof(erx_info_group_t) / sizeof(uint64_t))

typedef union erx_group_grant_words {
	erx_share_t	grant;
	uint64_t	words[ERX_GROUP_GRANT_WORDS];
} erx_group_grant_words_t;

typedef union erx_info_group_words {
	erx_info_group_t report;
	uint64_t	words[ERX_INFO_GROUP_WORDS];
} erx_info_group_words_t;

_Static_assert(sizeof(erx_group_grant_words_t) == sizeof(erx_share_t), "a grant is whole message registers");
_Static_assert(sizeof(erx_info_group_words_t) == sizeof(erx_info_group_t), "a report is whole message registers");

/* What a caller of erx_group_configure puts in its UTCB. */
static inline void
erx_group_grant_store(erx_utcb_t *utcb, const erx_share_t *grant)
{
	const erx_group_grant_words_t copy = { .grant = *grant };

	for (size_t word = 0; word < ERX_GROUP_GRANT_WORDS; word++)
		atomic_store_explicit(&utcb->mr[word], copy.words[word], memory_order_relaxed);
}

/* What a caller of erx_group_info takes from its UTCB. */
static inline erx_info_group_t
erx_info_group_load(const erx_utcb_t *utcb)
{
	erx_info_group_words_t copy;

	for (size_t word = 0; word < ERX_INFO_GROUP_WORDS; word++)
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

/* How many of the status page's slots hold an executor, parked or not: what a count of parked ones is out of. */
static inline uint32_t
erx_group_status_executors(const erx_group_stat_t *status)
{
	uint32_t executors = 0;

	for (uint32_t slot = 0; slot < ERX_GROUP_EXECUTORS_MAX; slot++) {
		if (atomic_load_explicit(&status->exec[slot].state, memory_order_relaxed) != ERX_EXEC_STATE_NONE)
			executors++;
	}
	return (executors);
}

/* The largest count, UINT32_MAX, in decimal digits. */
#define ERX_GROUP_REPORT_DIGITS_MAX	10u
/*
 * The bytes a report line needs after a head, its NUL included: the head, "parked ", the
 * parked count, " of ", the executor count and the newline. The head must be a string
 * literal, which the pasting below enforces: a pointer's size would give a buffer too small.
 */
#define ERX_GROUP_REPORT_LINE_SIZE(head) \
	(sizeof("" head "") - 1 + sizeof("parked  of \n") - 1 + 2 * ERX_GROUP_REPORT_DIGITS_MAX + 1)

/* Writes value's decimal digits to the start of digits, most significant first, and returns how many. */
static inline size_t
erx_group_report_decimal(char digits[static ERX_GROUP_REPORT_DIGITS_MAX], uint32_t value)
{
	char reversed[ERX_GROUP_REPORT_DIGITS_MAX];
	size_t count = 0;

	do {
		reversed[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	for (size_t index = 0; index < count; index++)
		digits[index] = reversed[count - 1 - index];
	return (count);
}

static inline size_t
erx_group_report_length(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}

/*
 * The group report's line, "<head>parked <parked> of <executors>\n", NUL-terminated in
 * line's size bytes; it returns the line's length without the NUL. A line that does not
 * fit writes only an empty string, when size allows one, and returns 0. The reporters on
 * both backends write it each time a count changes (docs/design-stopgap.md, "The command
 * line"); the head is theirs and the rest fixed words and digits, so it needs no escape.
 */
static inline size_t
erx_group_report_line(char *line, size_t size, const char *head, uint32_t parked, uint32_t executors)
{
	char parked_digits[ERX_GROUP_REPORT_DIGITS_MAX];
	char executors_digits[ERX_GROUP_REPORT_DIGITS_MAX];
	const size_t head_length = erx_group_report_length(head);
	const size_t parked_length = erx_group_report_decimal(parked_digits, parked);
	const size_t executors_length = erx_group_report_decimal(executors_digits, executors);
	const struct {
		const char *text;
		size_t length;
	} pieces[] = {
		{ head, head_length },
		{ "parked ", sizeof("parked ") - 1 },
		{ parked_digits, parked_length },
		{ " of ", sizeof(" of ") - 1 },
		{ executors_digits, executors_length },
		{ "\n", 1 },
	};
	const size_t count = sizeof(pieces) / sizeof(pieces[0]);
	size_t length = 0;
	size_t used = 0;

	for (size_t piece = 0; piece < count; piece++) {
		if (__builtin_add_overflow(length, pieces[piece].length, &length))
			length = SIZE_MAX;
	}
	if (length >= size) {
		if (size > 0)
			line[0] = '\0';
		return (0);
	}
	for (size_t piece = 0; piece < count; piece++) {
		for (size_t index = 0; index < pieces[piece].length; index++)
			line[used++] = pieces[piece].text[index];
	}
	line[used] = '\0';
	return (used);
}

/* A CPU set no one configured is zero and not reported: nothing is known of it. */
static inline void
erx_backend_group_report(erx_utcb_t *utcb, const erx_group_stat_t *status, const _Atomic uint64_t *cpuset)
{
	const uint64_t kept = atomic_load_explicit(cpuset, memory_order_relaxed);
	const uint32_t reported = (kept != 0 ? ERX_INFO_GROUP_REPORTED_CPUSET : 0) |
	    ERX_INFO_GROUP_REPORTED_PARKED | ERX_INFO_GROUP_REPORTED_READY;
	const erx_info_group_words_t copy = { .report = { .cpuset = kept,
	    .parked = atomic_load_explicit(&status->parked, memory_order_relaxed),
	    .ready = atomic_load_explicit(&status->ready, memory_order_relaxed), .reported = reported } };

	for (size_t word = 0; word < ERX_INFO_GROUP_WORDS; word++)
		atomic_store_explicit(&utcb->mr[word], copy.words[word], memory_order_relaxed);
}

#endif /* ERX_LIBERX_BACKEND_CORE_GROUP_REPORT_H */
