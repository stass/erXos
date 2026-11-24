/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs test/host/bench_periodic_test.rb's cases against test/guest/bench's histogram and
 * periodic cores, printing "NAME ok" or "NAME bad" for each, in a fixed order.
 */

#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "bench_clock.h"
#include "bench_hist.h"
#include "bench_line.h"
#include "bench_periodic.h"
#include "bench_window.h"

#define	RUN_MAX	512

static erx_bench_stamp_t stamps[RUN_MAX];
static erx_bench_periodic_t result;

/* A sample over twenty octaves lands in a bucket that holds it and is at most 1/64 wide. */
static bool
hist_case(void)
{
	uint64_t low, last, value;

	for (unsigned octave = 0; octave < 20; octave++) {
		for (uint64_t step = 0; step < 7; step++) {
			value = (UINT64_C(1) << octave) + ((UINT64_C(1) << octave) - 1) * step / 6;
			erx_bench_hist_bounds(erx_bench_hist_index(value), &low, &last);
			if (value < low || value > last)
				return (false);
			if (value >= ERX_BENCH_HIST_SUB && (last - low + 1) * ERX_BENCH_HIST_SUB > low)
				return (false);
		}
	}
	return (true);
}

/*
 * Parks of count deadlines of period from first under a timer: each returns at its
 * deadline rounded up to a multiple of tick (1 for none), plus cost, plus extra at the
 * park of index late_k. Returns the number of stamps.
 */
static size_t
simulate(uint64_t first, uint64_t period, uint32_t count, uint64_t tick, uint64_t cost,
    uint32_t late_k, uint64_t extra)
{
	uint64_t deadline, returned;
	uint32_t k;
	size_t n;

	n = 0;
	for (k = 0; k < count && n < RUN_MAX; k = erx_bench_periodic_next(first, period, k, returned)) {
		deadline = erx_bench_periodic_deadline(first, period, k);
		returned = (deadline + tick - 1) / tick * tick + cost + (k == late_k ? extra : 0);
		stamps[n++] = (erx_bench_stamp_t){ .k = k, .returned = returned };
	}
	erx_bench_periodic_classify(first, period, stamps, n, &result);
	return (n);
}

/* A 5 ms stall at a 100 us period is at least four missed periods and 5 ms late. */
static bool
stall_case(void)
{
	simulate(1000, 100, 200, 1, 1, 20, 5000);
	return (result.missed >= 4 && result.max_late >= 5000 && result.early == 0);
}

/* A return 10 ticks before its deadline is early; one at its deadline is not. */
static bool
early_case(void)
{
	const uint64_t first = 1000, period = 160;

	stamps[0] = (erx_bench_stamp_t){ 0, erx_bench_periodic_deadline(first, period, 0) - 10 };
	stamps[1] = (erx_bench_stamp_t){ 1, erx_bench_periodic_deadline(first, period, 1) };
	stamps[2] = (erx_bench_stamp_t){ 2, erx_bench_periodic_deadline(first, period, 2) + 3 };
	erx_bench_periodic_classify(first, period, stamps, 3, &result);
	return (result.early == 1 && result.returns == 3 && result.missed == 0);
}

/* 160 deadlines put ten in each of the sixteen phases of a period. */
static bool
sweep_case(void)
{
	const uint64_t first = 5, period = 1600;
	uint32_t seen[ERX_BENCH_PHASES] = { 0 };
	uint64_t offset;

	for (uint32_t k = 0; k < 160; k++) {
		offset = erx_bench_periodic_deadline(first, period, k) - first - (uint64_t)k * period;
		if (offset % (period / ERX_BENCH_PHASES) != 0 || offset >= period)
			return (false);
		seen[offset / (period / ERX_BENCH_PHASES)]++;
	}
	for (unsigned phase = 0; phase < ERX_BENCH_PHASES; phase++)
		if (seen[phase] != 10)
			return (false);
	return (true);
}

/*
 * A timer that fires only on ticks of one period: each phase's minimum lateness differs
 * by most of a tick across the phases, and each return's excess above its phase's minimum
 * is reported, a 7-tick jitter among them.
 */
static bool
tick_case(void)
{
	const uint64_t tick = 1600;
	uint64_t least, most;
	size_t n;

	n = simulate(16037, tick, 160, tick, 5, 50, 7);
	least = UINT64_MAX;
	most = 0;
	for (unsigned phase = 0; phase < ERX_BENCH_PHASES; phase++) {
		if (result.phase_returns[phase] == 0)
			return (false);
		least = result.phase_min[phase] < least ? result.phase_min[phase] : least;
		most = result.phase_min[phase] > most ? result.phase_min[phase] : most;
	}
	return (most - least >= tick * 14 / 16 && result.excess.samples == n &&
	    result.excess.count[erx_bench_hist_index(7)] == 1 && result.excess.count[0] == n - 1);
}

/*
 * Rounds with B's counter offset by true_offset from A's and every transfer taking
 * transfer ticks, A's first stamp at start.
 */
static erx_bench_offset_t
calibrate(int64_t true_offset, uint64_t transfer, uint64_t start)
{
	static erx_bench_round_t rounds[1000];

	for (size_t i = 0; i < sizeof(rounds) / sizeof(rounds[0]); i++) {
		uint64_t a = start + i * 1000;

		rounds[i] = (erx_bench_round_t){ .a = a,
		    .b = (uint64_t)((int64_t)(a + transfer) + true_offset), .c = a + 2 * transfer };
	}
	return (erx_bench_offset(rounds, sizeof(rounds) / sizeof(rounds[0]), 1));
}

/* A 50-tick offset inside 100-tick transfers, widened by one tick: [-51, 151]. */
static bool
offset_case(void)
{
	erx_bench_offset_t offset = calibrate(50, 100, 1000000);

	return (!offset.empty && offset.low == -51 && offset.high == 151 &&
	    erx_bench_offset_half_width(offset) == 101);
}

static bool
reason_is(const char *reason, const char *ending)
{
	size_t length = reason == NULL ? 0 : strlen(reason), tail = strlen(ending);

	return (length >= tail && strcmp(reason + length - tail, ending) == 0);
}

/* Half-width 101: a median of 1,010 ticks is accepted, 1,009 unsupported. */
static bool
cell_case(void)
{
	erx_bench_offset_t offset = calibrate(50, 100, 1000000);

	return (erx_bench_cell_unsupported(true, offset, offset, 1010) == NULL &&
	    reason_is(erx_bench_cell_unsupported(true, offset, offset, 1009), "not bounded closely enough") &&
	    erx_bench_cell_unsupported(false, offset, offset, 1) == NULL);
}

static const erx_bench_round_t before_rounds_none[1];

/*
 * An offset that moves by 300 ticks between the calibrations, or a calibration whose stamps
 * contradict each other, leaves the cells unsupported with the reason.
 */
static bool
drift_case(void)
{
	erx_bench_offset_t before = calibrate(50, 100, 1000000);
	erx_bench_offset_t after = calibrate(350, 100, 5000000);

	erx_bench_offset_t moved = calibrate(200, 100, 5000000);

	/* A 150-tick move that still overlaps is bounded by the hull, half-width 176. */
	erx_bench_offset_t none = erx_bench_offset(before_rounds_none, 0, 1);

	return (!after.empty &&
	    reason_is(erx_bench_cell_unsupported(true, before, after, UINT64_MAX / 16), "moved during the run") &&
	    reason_is(erx_bench_cell_unsupported(true, before, moved, 1759), "not bounded closely enough") &&
	    erx_bench_cell_unsupported(true, before, moved, 1760) == NULL && none.empty &&
	    reason_is(erx_bench_cell_unsupported(true, none, after, UINT64_MAX / 16), "contradicted each other"));
}

/* The sixteen largest of n values, or all of them, largest first; returns how many. */
static size_t
largest_of(const uint64_t *values, size_t n, erx_bench_sample_t *out)
{
	static bool taken[64];
	size_t found = 0;

	if (n > sizeof(taken) / sizeof(taken[0]))
		return (0);
	for (size_t i = 0; i < n; i++)
		taken[i] = false;
	for (; found < ERX_BENCH_LARGEST && found < n; found++) {
		size_t best = n;

		for (size_t i = 0; i < n; i++)
			if (!taken[i] && (best == n || values[i] > values[best]))
				best = i;
		taken[best] = true;
		out[found] = (erx_bench_sample_t){ best, values[best] };
	}
	return (found);
}

/* A counter that moves 7 ticks between pairs and 1, 3 and 3 within them, in turn. */
static uint64_t
fake_counter(void)
{
	static const uint64_t steps[] = { 7, 1, 7, 3, 7, 3 };
	static uint64_t now, k;

	now += steps[k++ % 6];
	return (now);
}

/* 9,999 pairs of the fake counter: the smallest increment is 1 and the median read 3. */
static bool
reads_case(void)
{
	static erx_bench_reads_t pairs[9999];
	static erx_bench_hist_t deltas;
	erx_bench_read_cal_t cal;
	size_t n = sizeof(pairs) / sizeof(pairs[0]);

	erx_bench_read_pairs(fake_counter, pairs, n);
	cal = erx_bench_read_calibration(pairs, n, &deltas);
	if (cal.increment != 1 || cal.read_cost != 3 || deltas.samples != n)
		return (false);
	/* No pair that moved: no increment to report. */
	pairs[0] = (erx_bench_reads_t){ 5, 5 };
	return (erx_bench_read_calibration(pairs, 1, &deltas).increment == 0);
}

/* The median is the upper end of the bucket holding the sample of rank ceil(n / 2). */
static bool
median_case(void)
{
	static erx_bench_hist_t hist;
	uint64_t low, last;

	if (erx_bench_hist_median(&hist) != 0)
		return (false);
	for (uint64_t v = 1; v <= 5; v++)
		erx_bench_hist_add(&hist, v);
	if (erx_bench_hist_median(&hist) != 3)
		return (false);
	erx_bench_hist_add(&hist, 1000);
	erx_bench_hist_add(&hist, 1000);
	erx_bench_hist_add(&hist, 1000);
	erx_bench_hist_add(&hist, 1000);
	erx_bench_hist_bounds(erx_bench_hist_index(1000), &low, &last);
	/* Nine samples: rank 5 is the last of 1..5. */
	return (erx_bench_hist_median(&hist) == 5 && low <= 1000 && last >= 1000);
}

/* B's counter is this far ahead of A's in the rounds case, in nanoseconds. */
#define ROUNDS_OFFSET	INT64_C(1000000)
#define ROUNDS	1000

static uint64_t
host_now(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec);
}

static uint64_t
host_ahead(void)
{
	return (host_now() + (uint64_t)ROUNDS_OFFSET);
}

static erx_bench_token_t rounds_token;

static void *
rounds_b(void *unused)
{
	(void)unused;
	erx_bench_rounds_b(&rounds_token, host_ahead, ROUNDS);
	return (NULL);
}

/*
 * Two host threads pass the token, B's clock ROUNDS_OFFSET ahead of A's: two
 * calibrations over the one token each give an interval that holds the offset.
 */
static bool
rounds_case(void)
{
	static erx_bench_round_t rounds[ROUNDS];
	bool held = true;

	for (int pass = 0; pass < 2; pass++) {
		pthread_t b;

		if (pthread_create(&b, NULL, rounds_b, NULL) != 0)
			return (false);
		erx_bench_rounds_a(&rounds_token, host_now, rounds, ROUNDS);
		pthread_join(b, NULL);

		erx_bench_offset_t offset = erx_bench_offset(rounds, ROUNDS, 1);

		held = held && !offset.empty && offset.low <= ROUNDS_OFFSET &&
		    ROUNDS_OFFSET <= offset.high;
	}
	return (held);
}

/*
 * Prints a fast cell, a periodic cell and a two-CPU calibration as the guests print them,
 * for the host's validator to read (test/host/bench_guest_lines_test.rb).
 */
static void
print_lines(void)
{
	static erx_bench_hist_t fast;
	static erx_bench_stamp_t stamps[32];
	static erx_bench_periodic_t periodic;
	static char line[64 << 10];
	static uint64_t values[40];
	erx_bench_sample_t largest[ERX_BENCH_LARGEST];
	const erx_bench_param_t params[] = { { "threads", NULL, 2 }, { "mode", "spin", 0 } };
	erx_bench_pair_t pairs[] = {
		{ { 0, 1 }, { -40, 12, false }, { -35, 15, false } },
		{ { 0, 2 }, { 0, 0, true }, { INT64_MIN, INT64_MAX, false } },
	};

	for (uint64_t i = 0; i < 40; i++) {
		values[i] = i == 7 ? 1199 : i == 3 ? 1100 : 1000 + i;
		erx_bench_hist_add(&fast, values[i]);
	}
	erx_bench_cell_t cell = { .benchmark = "wake", .operation = "wake-same-cpu", .load = "idle",
		.placement = "same-cpu", .params = params, .nparams = 2, .clock = "counter", .batch = 1,
		.frequency_hz = 24000000, .status = "measured", .hist = &fast, .min = 1000, .max = 1199,
		.largest = largest, .nlargest = largest_of(values, 40, largest) };
	if (erx_bench_line_cell(line, sizeof(line), &cell) != 0)
		printf("%s\n", line);

	for (uint32_t k = 0; k < 32; k++) {
		values[k] = 5 + k % 3;
		stamps[k] = (erx_bench_stamp_t){ k, erx_bench_periodic_deadline(1000, 1000, k) + values[k] };
	}
	erx_bench_periodic_classify(1000, 1000, stamps, 32, &periodic);
	cell = (erx_bench_cell_t){ .benchmark = "wake", .operation = "park-deadline", .load = "idle",
		.placement = "service-cpu", .clock = "counter", .batch = 1, .frequency_hz = 24000000,
		.status = "partial", .reason = "cut short", .hist = &periodic.late, .min = 5, .max = 7,
		.largest = largest, .nlargest = largest_of(values, 32, largest), .periodic = &periodic };
	if (erx_bench_line_cell(line, sizeof(line), &cell) != 0)
		printf("%s\n", line);

	static erx_bench_hist_t costly;
	for (uint64_t i = 0; i < 20; i++) {
		values[i] = 5000 + i * 7 % 13;
		erx_bench_hist_add(&costly, values[i]);
	}
	cell = (erx_bench_cell_t){ .benchmark = "wake", .operation = "trigger-take", .load = "idle",
		.placement = "same-cpu", .clock = "counter", .batch = 1, .frequency_hz = 24000000,
		.status = "measured", .hist = &costly, .min = 5000, .max = 5012, .largest = largest,
		.nlargest = largest_of(values, 20, largest), .raw = values, .nraw = 20 };
	if (erx_bench_line_cell(line, sizeof(line), &cell) != 0)
		printf("%s\n", line);

	erx_bench_calibration_t clock = { .clock = "counter", .frequency_hz = 24000000, .increment = 1,
		.read_cost = 2, .wait_rounding = 24, .cycles_per_tick_milli = 27778, .pairs = pairs, .npairs = 2 };
	if (erx_bench_line_clock(line, sizeof(line), &clock) != 0)
		printf("%s\n", line);
	/*
	 * A line fits a buffer one byte longer than itself, for its NUL; one byte shorter and
	 * nothing is written, the buffer left an empty string.
	 */
	size_t length = erx_bench_line_clock(line, sizeof(line), &clock);
	bool fits = erx_bench_line_clock(line, length + 1, &clock) == length;
	bool cut = erx_bench_line_clock(line, length, &clock) == 0 && line[0] == '\0';
	printf("boundary %s\n", length != 0 && fits && cut ? "ok" : "bad");

	/* The longest WINDOW line a spinner writes: its last window and thread, every count at its most. */
	const erx_bench_window_t most = { UINT64_MAX, UINT64_MAX, UINT64_MAX, UINT64_MAX };

	if (erx_bench_line_window(line, sizeof(line), 9, 7, &most) != 0)
		printf("%s\n", line);
}

/*
 * A lost turn is a gap longer than half the slice: a gap of exactly half is a pass, one tick
 * more a lost turn whose ticks the window's waited holds; a window no read fell in is one
 * gap of its length and no pass, and so is a read past its end whose gap began before it.
 */
static bool
window_case(void)
{
	const uint64_t half = erx_bench_window_lost_after(UINT64_C(24000000), 1000);
	erx_bench_window_t kept = { 0, 0, 0, 0 };
	erx_bench_window_t empty, starved = { 0, 0, 0, 0 };

	erx_bench_window_read(&kept, 1000, 100000, 1000, 1003, half);
	erx_bench_window_read(&kept, 1000, 100000, 1003, 1003 + half, half);
	erx_bench_window_read(&kept, 1000, 100000, 1003 + half, 1004 + 2 * half, half);
	erx_bench_window_read(&kept, 1000, 100000, 1004 + 2 * half, 1009 + 2 * half, half);
	erx_bench_window_read(&starved, 1000, 2000, 999, 2500, half);
	empty = erx_bench_window_empty(UINT64_C(24000000), half);
	return (half == 12000 && kept.iterations == 4 && kept.longest == half + 1 && kept.lost == 1 &&
	    kept.waited == half + 1 && empty.iterations == 0 && empty.longest == UINT64_C(24000000) &&
	    empty.lost == 1 && empty.waited == UINT64_C(24000000) && starved.iterations == 0 && starved.longest == 1501);
}

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "lines") == 0) {
		print_lines();
		return (0);
	}
	static const struct {
		const char *name;
		bool (*run)(void);
	} cases[] = {
		{ "hist", hist_case }, { "stall", stall_case }, { "early", early_case },
		{ "sweep", sweep_case }, { "tick", tick_case }, { "offset", offset_case },
		{ "cell", cell_case }, { "drift", drift_case }, { "reads", reads_case },
		{ "median", median_case }, { "rounds", rounds_case }, { "window", window_case },
	};

	for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
		printf("%s %s\n", cases[i].name, cases[i].run() ? "ok" : "bad");
	return (0);
}
