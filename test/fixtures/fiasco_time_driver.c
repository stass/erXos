/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The time page's scale and the wait conversion, on the host. For the counters of
 * real machines the scale must give the exact floor of counter * 10^9 / hz, which is
 * what erx_fiasco_clock_ns computes; a deadline's wait must round up and never end
 * early, and must keep to the kernel's maximum.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "liberx/backend/fiasco/time_table.h"

#define NS_PER_SECOND	UINT64_C(1000000000)
/* Five years, in seconds, within which each frequency below reads the exact floor. */
#define REACH_SECONDS	UINT64_C(157680000)
#define RANDOM_COUNTERS	2000000u
#define WAIT_MAX_US	UINT64_C(1000000)

__extension__ typedef unsigned __int128 wide_t;

/* TCG's and HVF's, a Raspberry Pi's, and frequencies that divide 10^9 and do not. */
static const uint64_t frequencies[] = { 62500000, 24000000, 54000000, 19200000, 1000000000, 1000000, 100000000,
	25000000, 33000000, 2000000000 };

static uint64_t
next_random(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static bool
agrees(uint64_t counter, uint64_t hz, erx_fiasco_time_scale_t scale)
{
	const uint64_t exact = (uint64_t)((wide_t)counter * NS_PER_SECOND / hz);

	if (erx_fiasco_time_ns(counter, scale) == exact)
		return (true);
	printf("time: hz %llu counter %llu gives %llu, exactly %llu\n", (unsigned long long)hz,
	    (unsigned long long)counter, (unsigned long long)erx_fiasco_time_ns(counter, scale), (unsigned long long)exact);
	return (false);
}

static bool
check_scale(uint64_t hz, uint64_t *state, uint64_t *checked)
{
	const erx_fiasco_time_scale_t scale = erx_fiasco_time_scale(hz);
	const uint64_t reach = REACH_SECONDS * hz;

	if (scale.shift > 63) {
		puts("time: a shift past 63");
		return (false);
	}
	for (uint64_t counter = 0; counter < 4096; counter++)
		if (!agrees(counter, hz, scale))
			return (false);
	/* Each whole second and its neighbours, where a rounding shows first. */
	for (uint64_t second = 1; second < 100000; second++) {
		const uint64_t counter = second * hz;

		if (!agrees(counter - 1, hz, scale) || !agrees(counter, hz, scale) || !agrees(counter + 1, hz, scale))
			return (false);
	}
	for (uint32_t round = 0; round < RANDOM_COUNTERS; round++)
		if (!agrees(next_random(state) % reach, hz, scale))
			return (false);
	*checked += 4096 + 3 * 99999 + RANDOM_COUNTERS;
	return (true);
}

static bool
check_edges(void)
{
	const erx_fiasco_time_scale_t none = erx_fiasco_time_scale(0);

	if (erx_fiasco_time_ns(UINT64_MAX, none) != 0) {
		puts("time: a frequency of zero did not read as time zero");
		return (false);
	}
	/* The largest counter's product stays in 128 bits at any frequency's scale. */
	for (size_t index = 0; index < sizeof(frequencies) / sizeof(frequencies[0]); index++) {
		const erx_fiasco_time_scale_t scale = erx_fiasco_time_scale(frequencies[index]);

		if (scale.mult == 0) {
			puts("time: a scale of zero");
			return (false);
		}
		(void)erx_fiasco_time_ns(UINT64_MAX, scale);
	}
	return (true);
}

/* Around each microsecond boundary: never short, at most a microsecond long, within the cap. */
static bool
check_wait(uint64_t *checked)
{
	static const uint64_t starts[] = { 0, 1, 999, 1000, 1001, UINT64_C(1) << 40, UINT64_MAX - 5000 };

	for (size_t start = 0; start < sizeof(starts) / sizeof(starts[0]); start++) {
		for (uint64_t distance = 0; distance <= 5000; distance++) {
			const uint64_t now = starts[start], deadline = now + distance;
			const uint64_t wait = erx_fiasco_time_wait_us(now, deadline, WAIT_MAX_US);

			if ((distance == 0) != (wait == 0) || wait * 1000 < distance || wait * 1000 >= distance + 1000 + (distance == 0)) {
				printf("time: a wait of %llu ns asked for %llu us\n", (unsigned long long)distance,
				    (unsigned long long)wait);
				return (false);
			}
			(*checked)++;
		}
	}
	if (erx_fiasco_time_wait_us(5, 4, WAIT_MAX_US) != 0 || erx_fiasco_time_wait_us(0, UINT64_MAX, WAIT_MAX_US) != WAIT_MAX_US) {
		puts("time: a passed deadline or a long wait is wrong");
		return (false);
	}
	return (true);
}

int
main(void)
{
	uint64_t state = UINT64_C(0x9e3779b97f4a7c15), checked = 0;

	for (size_t index = 0; index < sizeof(frequencies) / sizeof(frequencies[0]); index++)
		if (!check_scale(frequencies[index], &state, &checked))
			return (1);
	if (!check_edges() || !check_wait(&checked))
		return (1);
	printf("time: %llu cases\n", (unsigned long long)checked);
	return (0);
}
