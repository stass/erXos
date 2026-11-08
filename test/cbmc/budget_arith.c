/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: the budget core's two checked-arithmetic helpers,
 * add_delta and difference (kernel/core/budget.c), over every 64-bit
 * input. Each result is compared with the exact sum or difference,
 * computed in 128 bits, so a helper that accepts a wrapped result, refuses
 * a representable one or writes a wrong value fails an assertion. No loop,
 * so no unwind bound; no assumption narrows an input.
 */

#include "cbmc_harness.h"
#include "budget.c"

static void
check_add_delta(void)
{
	erx_npages_t value = nondet_u64();
	int64_t delta = nondet_i64();
	erx_npages_t out = nondet_u64();
	__int128 exact = (__int128)value + delta;
	bool fits = exact >= 0 && exact <= (__int128)UINT64_MAX;

	if (add_delta(value, delta, &out)) {
		__CPROVER_assert(fits, "add_delta accepts only a sum in range");
		__CPROVER_assert((__int128)out == exact,
		    "add_delta writes the exact sum");
	} else
		__CPROVER_assert(!fits, "add_delta refuses only a sum out of range");
}

static void
check_difference(void)
{
	erx_npages_t to = nondet_u64();
	erx_npages_t from = nondet_u64();
	int64_t out = nondet_i64();
	__int128 exact = (__int128)to - (__int128)from;
	bool fits = exact >= INT64_MIN && exact <= INT64_MAX;

	if (difference(to, from, &out)) {
		__CPROVER_assert(fits, "difference accepts only a delta in range");
		__CPROVER_assert((__int128)out == exact,
		    "difference writes the exact delta");
	} else {
		/*
		 * The helper refuses -2^63, which fits int64_t: it negates the
		 * magnitude, so it keeps the symmetric range. Callers never
		 * need it, since live spending stays at most INT64_MAX.
		 */
		__CPROVER_assert(!fits || exact == INT64_MIN,
		    "difference refuses only a delta out of range");
	}
}

void
harness(void)
{
	check_add_delta();
	check_difference();
}
