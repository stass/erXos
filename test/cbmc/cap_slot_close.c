/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * CBMC harness: the retirement bounds of a capability slot's life
 * (kernel/core/cap.c, cap_slot_write and cap_slot_close), over every
 * resting count and generation.
 *
 * The bounds come from the ABI and the contract, not from the core's own
 * constants. A slot's life is at most LIFE_OPENING_WRITES opening writes
 * (an install, or a reserve and a fill), each adding 2 to the count, and
 * a closing write whose odd store adds 1 more; so a slot may rest only at
 * an even count of at most REST_MAX, from which a whole life ends at the
 * terminal count. cap.c issues no value at the all-ones generation
 * GENERATION_UNISSUED. A resting count and a generation within those
 * bounds are the assumptions, and the harness proves the closing write
 * hands them on. From rest the slot makes zero to two opening writes,
 * then a clear, which closes at the next generation, or a release, which
 * keeps it. Checked:
 *
 * - no opening write reaches the terminal count, so nothing after a
 *   pass's checks fails for want of a count (K1);
 * - no count wraps, and every count a write publishes is above the last;
 * - the closing write frees the slot exactly when its generation and the
 *   count it leaves allow one more whole life, and then hands on the
 *   resting facts; otherwise the slot retires at the terminal count;
 * - generations retire before they wrap: a freed slot's generation is
 *   below the all-ones generation, so the value it names next fits and is
 *   new.
 *
 * The opening writes' loop runs at most LIFE_OPENING_WRITES times; the
 * roster's unwind bound covers it.
 */

#include "cbmc_harness.h"
#include "cap.c"

/* The writes that open a life: an install, or a reserve and a fill. */
#define LIFE_OPENING_WRITES	2
/* The highest count a slot may rest at: room for a whole life. */
#define REST_MAX	(ERX_CAP_SLOT_SEQ_TERMINAL - 2 * LIFE_OPENING_WRITES - 1)
/* The generation no value is issued at, the highest a value can hold. */
#define GENERATION_UNISSUED	((UINT64_C(1) << ERX_CAP_GENERATION_BITS) - 1)

static erx_cap_slot_t slot;

/* Every count the slot has published, so each is checked above the last. */
static uint64_t
published_after(uint64_t last)
{
	uint64_t now = cap_seq(&slot);

	__CPROVER_assert(now > last, "each write's count rises");
	return (now);
}

void
harness(void)
{
	uint64_t rest = nondet_u64();
	uint64_t generation = nondet_u64();
	uint32_t opening = nondet_u32();
	bool clear = nondet_bool();
	cap_fields_t live = {
		.object = nondet_u64(),
		.generation = generation,
		.rights = nondet_u32(),
		.type = nondet_u32(),
		.state = ERX_CAP_SLOT_STATE_LIVE,
	};
	uint64_t before_close, closed_at, last;
	bool freed;
	uint32_t i;

	__CPROVER_assume(rest % 2 == 0 && rest <= REST_MAX);
	__CPROVER_assume(generation < GENERATION_UNISSUED);
	__CPROVER_assume(opening <= LIFE_OPENING_WRITES);
	(void)erx_cap_slot_seq_store(&slot, rest);
	(void)erx_cap_slot_generation_store(&slot, generation);
	(void)erx_cap_slot_state_store(&slot, ERX_CAP_SLOT_STATE_FREE);

	last = rest;
	for (i = 0; i < LIFE_OPENING_WRITES; i++) {
		if (i >= opening)
			break;
		cap_slot_write(&slot, &live);
		last = published_after(last);
		__CPROVER_assert(last % 2 == 0 && last < ERX_CAP_SLOT_SEQ_TERMINAL,
		    "an opening write leaves room for the closing write");
	}

	closed_at = clear ? generation + 1 : generation;
	before_close = last;
	freed = cap_slot_close(&slot, closed_at);
	last = published_after(last);
	__CPROVER_assert(cap_generation(&slot) == closed_at,
	    "the closing write keeps the generation it was given");
	if (freed) {
		__CPROVER_assert(closed_at < GENERATION_UNISSUED,
		    "a freed slot's generation is one a value is issued at");
		__CPROVER_assert(last == before_close + 2 &&
		    last <= REST_MAX,
		    "a freed slot rests at a count with room for a life");
		__CPROVER_assert(cap_state(&slot) == ERX_CAP_SLOT_STATE_FREE,
		    "a freed slot is free");
	} else {
		/* Freeing would leave the count at before_close + 2. */
		__CPROVER_assert(closed_at >= GENERATION_UNISSUED ||
		    before_close > REST_MAX - 2,
		    "a slot retires only when no life is left");
		__CPROVER_assert(last == ERX_CAP_SLOT_SEQ_TERMINAL &&
		    cap_state(&slot) == ERX_CAP_SLOT_STATE_RETIRED,
		    "a retired slot holds the terminal count");
	}
}
