/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The time page's scale and the wait conversion, on the host. For the counters of
 * real machines the scale must give the exact floor of counter * 10^9 / hz, which is
 * what erx_fiasco_clock_ns computes; a deadline's wait must round up and never end
 * early, and must keep to the kernel's maximum. A timed down, against a model
 * semaphore, must never give up before its deadline and never leave an up posted
 * by its last attempt.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "liberx/backend/fiasco/time_table.h"

#define NS_PER_SECOND	UINT64_C(1000000000)
/* Five years, in seconds, within which each frequency below reads the exact floor. */
#define REACH_SECONDS	UINT64_C(157680000)
#define RANDOM_COUNTERS	2000000u
#define WAIT_MAX_US	UINT64_C(1000000)
#define NS_PER_US	UINT64_C(1000)
#define DOWN_START	UINT64_C(1000000)
/* Far more attempts than any down below needs: past them it spins forever. */
#define DOWN_CALLS_MAX	100000u

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

/*
 * Around each microsecond boundary: never short, at most a microsecond long, within the cap; and
 * nothing asked of the kernel for less than a microsecond, which the caller spins out.
 */
static bool
check_wait(uint64_t *checked)
{
	static const uint64_t starts[] = { 0, 1, 999, 1000, 1001, UINT64_C(1) << 40, UINT64_MAX - 5000 };

	for (size_t start = 0; start < sizeof(starts) / sizeof(starts[0]); start++) {
		for (uint64_t distance = 0; distance <= 5000; distance++) {
			const uint64_t now = starts[start], deadline = now + distance;
			const uint64_t wait = erx_fiasco_time_wait_us(now, deadline, WAIT_MAX_US);

			if ((distance < 1000) != (wait == 0) || (wait != 0 && (wait * 1000 < distance || wait * 1000 >= distance + 1000))) {
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

/*
 * A semaphore and its clock. Each read advances the clock step ns; one up is posted
 * at up (UINT64_MAX: never); a kernel wait of N us ends at the up or N us less early ns
 * later, since Fiasco may end a relative timeout up to a microsecond before it.
 */
typedef struct down_model {
	uint64_t	now;
	uint64_t	step;
	uint64_t	up;
	uint64_t	early;
	uint32_t	calls;
} down_model_t;

static void
down_model_count(down_model_t *model)
{
	if (++model->calls > DOWN_CALLS_MAX) {
		puts("time: a down spun forever");
		exit(1);
	}
}

static uint64_t
down_model_clock_ns(void *context)
{
	down_model_t *const model = context;

	down_model_count(model);
	model->now += model->step;
	return (model->now);
}

static bool
down_model_down(void *context, uint64_t timeout_us)
{
	down_model_t *const model = context;
	const uint64_t end = model->now + timeout_us * NS_PER_US - (timeout_us == 0 ? 0 : model->early);

	down_model_count(model);
	if (model->up <= end) {
		if (model->up > model->now)
			model->now = model->up;
		return (true);
	}
	model->now = end;
	return (false);
}

static bool
down_agrees(uint64_t distance, uint64_t up, uint64_t step, uint64_t early, uint64_t max_us)
{
	static const erx_fiasco_down_view_t view = { .clock_ns = down_model_clock_ns, .down = down_model_down };
	down_model_t model = { .now = DOWN_START, .step = step, .up = up, .early = early, .calls = 0 };
	const uint64_t deadline = DOWN_START + distance;
	const bool taken = erx_fiasco_time_down(&view, &model, deadline, max_us);

	if (!taken && model.now < deadline) {
		printf("time: a down %llu ns from its deadline gave up early\n", (unsigned long long)(deadline - model.now));
		return (false);
	}
	if (!taken && up <= model.now) {
		printf("time: a down with %llu ns to go missed an up posted at %lld ns\n", (unsigned long long)distance,
		    (long long)(int64_t)(up - DOWN_START));
		return (false);
	}
	return (true);
}

/*
 * Deadlines passed by the first clock read, under, at and over a microsecond away, each with an up before, during or
 * after it, times relative to the start of the down.
 */
static bool
check_down(uint64_t *checked)
{
	static const uint64_t distances[] = { 500, 0, 1, 999, 1000, 1001, 2500, 1000003 };
	static const uint64_t steps[] = { 1, 7, 400 }, earlies[] = { 0, 999 }, maxima[] = { WAIT_MAX_US, 1000 };

	for (size_t d = 0; d < sizeof(distances) / sizeof(distances[0]); d++) {
		const uint64_t distance = distances[d];
		const uint64_t ups[] = { DOWN_START - 1, DOWN_START, DOWN_START + 1, DOWN_START + distance / 2,
			DOWN_START + distance - (distance != 0), DOWN_START + distance, DOWN_START + distance + 1,
			DOWN_START + distance + 5000, UINT64_MAX };

		for (size_t u = 0; u < sizeof(ups) / sizeof(ups[0]); u++)
			for (size_t s = 0; s < sizeof(steps) / sizeof(steps[0]); s++)
				for (size_t e = 0; e < sizeof(earlies) / sizeof(earlies[0]); e++)
					for (size_t m = 0; m < sizeof(maxima) / sizeof(maxima[0]); m++) {
						if (!down_agrees(distance, ups[u], steps[s], earlies[e], maxima[m]))
							return (false);
						(*checked)++;
					}
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
	if (!check_edges() || !check_wait(&checked) || !check_down(&checked))
		return (1);
	printf("time: %llu cases\n", (unsigned long long)checked);
	return (0);
}
