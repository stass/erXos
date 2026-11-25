/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The one-shot timer's compare value on Fiasco, on the host. Fiasco's clock reads
 * (count * scaler) >> (32 - shift) microseconds, with the scaler and shift that
 * Scaler_shift::init (fiasco/kernel/src/lib/libk/scaler_shift.cpp) derives for a
 * counter's frequency, rounded down; the model below is that arithmetic. For each
 * frequency, erx_clock_first_count must give the first count at which the clock reads
 * a wakeup, exactly: the clock reads the wakeup there and not one count before, and the
 * count is the exact 128-bit quotient, or the largest count where that does not fit.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "erx/core/clock_inverse.h"

#define US_PER_SECOND	UINT64_C(1000000)
#define RANDOM_WAKEUPS	2000000u
#define SPAN_WAKEUPS	10000u

__extension__ typedef unsigned __int128 wide_t;

typedef struct model_scale {
	uint32_t	scaler;
	uint32_t	shift;
} model_scale_t;

/* TCG's and HVF's, a Raspberry Pi's, and frequencies that divide 10^6 and do not. */
static const uint32_t frequencies[] = { 62500000, 24000000, 54000000, 19200000, 1000000000, 1000000, 100000000,
	25000000, 33000000, 32768, 4000000000u };

/* Scaler_shift::init(from_freq, to_freq), as Fiasco computes it. */
static model_scale_t
model_init(uint32_t from_freq, uint32_t to_freq)
{
	model_scale_t scale = { .scaler = 0, .shift = 0 };

	while (scale.shift < 31 && to_freq / (UINT32_C(1) << scale.shift) >= from_freq)
		scale.shift++;
	scale.scaler = (uint32_t)(((uint64_t)to_freq << (32 - scale.shift)) / from_freq);
	return (scale);
}

/*
 * Scaler_shift::transform on AArch64, the product shifted down, here in full: Fiasco keeps its low
 * 64 bits, which differ only past 2^64 microseconds.
 */
static wide_t
model_clock(uint64_t count, model_scale_t scale)
{
	return (((wide_t)count * scale.scaler) >> (32 - scale.shift));
}

static uint64_t
next_random(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static bool
first_count_agrees(uint64_t wakeup, uint32_t hz, model_scale_t scale)
{
	const wide_t exact = (((wide_t)wakeup << (32 - scale.shift)) + scale.scaler - 1) / scale.scaler;
	const uint64_t count = erx_clock_first_count(wakeup, scale.scaler, scale.shift);

	if (exact > UINT64_MAX) {
		if (count == UINT64_MAX)
			return (true);
		printf("clock: hz %u wakeup %llu past the counter gives %llu\n", hz, (unsigned long long)wakeup,
		    (unsigned long long)count);
		return (false);
	}
	if (count != (uint64_t)exact) {
		printf("clock: hz %u wakeup %llu gives %llu, exactly %llu\n", hz, (unsigned long long)wakeup,
		    (unsigned long long)count, (unsigned long long)exact);
		return (false);
	}
	/* What the timer interrupt finds: the clock at the compare value, and one count before. */
	if (model_clock(count, scale) < wakeup || (count != 0 && model_clock(count - 1, scale) >= wakeup)) {
		printf("clock: hz %u wakeup %llu at count %llu reads %llu\n", hz, (unsigned long long)wakeup,
		    (unsigned long long)count, (unsigned long long)(uint64_t)model_clock(count, scale));
		return (false);
	}
	return (true);
}

static bool
check_frequency(uint32_t hz, uint64_t *state, uint64_t *checked)
{
	const model_scale_t scale = model_init(hz, 1000000);
	static const uint64_t far[] = { UINT64_C(1) << 32, UINT64_C(1) << 40, UINT64_C(1) << 52, UINT64_C(1) << 58,
		UINT64_MAX / 4000, UINT64_MAX - 1, UINT64_MAX };

	for (uint64_t wakeup = 0; wakeup < 100000; wakeup++)
		if (!first_count_agrees(wakeup, hz, scale))
			return (false);
	/* After an hour, a day and 24 days of uptime, where Fiasco's clock lags the counter most. */
	for (uint64_t at = US_PER_SECOND * 3600; at <= US_PER_SECOND * 3600 * 24 * 24; at *= 24)
		for (uint64_t wakeup = at; wakeup < at + SPAN_WAKEUPS; wakeup++)
			if (!first_count_agrees(wakeup, hz, scale))
				return (false);
	for (size_t index = 0; index < sizeof(far) / sizeof(far[0]); index++)
		if (!first_count_agrees(far[index], hz, scale))
			return (false);
	for (uint32_t round = 0; round < RANDOM_WAKEUPS; round++)
		if (!first_count_agrees(next_random(state) >> (round % 64), hz, scale))
			return (false);
	*checked += 100000 + 3 * SPAN_WAKEUPS + sizeof(far) / sizeof(far[0]) + RANDOM_WAKEUPS;
	return (true);
}

int
main(void)
{
	uint64_t state = UINT64_C(0x9e3779b97f4a7c15), checked = 0;

	for (size_t index = 0; index < sizeof(frequencies) / sizeof(frequencies[0]); index++)
		if (!check_frequency(frequencies[index], &state, &checked))
			return (1);
	printf("clock: %llu cases\n", (unsigned long long)checked);
	return (0);
}
