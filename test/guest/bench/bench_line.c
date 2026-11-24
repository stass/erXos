/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "bench_line.h"

/*
 * The line being written. Once a write does not fit, full is set and nothing more is.
 * first is set while the innermost open object or array has no member yet.
 */
typedef struct {
	char *buf;
	size_t size;
	size_t len;
	bool full;
	bool first;
} text_t;

static void
put(text_t *t, const char *s)
{
	for (; *s != '\0' && !t->full; s++) {
		if (t->len + 1 >= t->size)
			t->full = true;
		else
			t->buf[t->len++] = *s;
	}
}

static void
put_u64(text_t *t, uint64_t v)
{
	char digits[21];
	size_t i = sizeof(digits);

	digits[--i] = '\0';
	do {
		digits[--i] = (char)('0' + v % 10);
		v /= 10;
	} while (v != 0);
	put(t, &digits[i]);
}

static void
put_i64(text_t *t, int64_t v)
{
	if (v < 0) {
		put(t, "-");
		/* Negate in unsigned arithmetic: INT64_MIN has no positive int64_t. */
		put_u64(t, (uint64_t)0 - (uint64_t)v);
	} else
		put_u64(t, (uint64_t)v);
}

/* v thousandths as a decimal with three fraction digits: 27778 is 27.778. */
static void
put_milli(text_t *t, uint64_t v)
{
	char fraction[] = "000";

	put_u64(t, v / 1000);
	for (unsigned i = 0, rest = (unsigned)(v % 1000); i < 3; i++, rest /= 10)
		fraction[2 - i] = (char)('0' + rest % 10);
	put(t, ".");
	put(t, fraction);
}

/* A member's separator: a comma before every member of an object or array but its first. */
static void
member(text_t *t)
{
	if (!t->first)
		put(t, ",");
	t->first = false;
}

/* "name": as the next member of the open object. */
static void
key(text_t *t, const char *name)
{
	member(t);
	put(t, "\"");
	put(t, name);
	put(t, "\":");
}

/* Opens an object or array (open is "{" or "["), named where name is not NULL. */
static void
open_value(text_t *t, const char *name, const char *open)
{
	if (name != NULL)
		key(t, name);
	else
		member(t);
	put(t, open);
	t->first = true;
}

static void
close_value(text_t *t, const char *close)
{
	put(t, close);
	t->first = false;
}

static void
string(text_t *t, const char *name, const char *value)
{
	key(t, name);
	put(t, "\"");
	put(t, value);
	put(t, "\"");
}

static void
number(text_t *t, const char *name, uint64_t value)
{
	key(t, name);
	put_u64(t, value);
}

/* [a, b] as the next member of the open array. */
static void
pair(text_t *t, uint64_t a, uint64_t b)
{
	open_value(t, NULL, "[");
	member(t);
	put_u64(t, a);
	member(t);
	put_u64(t, b);
	close_value(t, "]");
}

/* Every non-empty bucket as [low, last, count], ascending. */
static void
histogram(text_t *t, const char *name, const erx_bench_hist_t *hist)
{
	uint64_t low, last;

	open_value(t, name, "[");
	for (unsigned i = 0; i < ERX_BENCH_HIST_BUCKETS; i++) {
		if (hist->count[i] == 0)
			continue;
		erx_bench_hist_bounds(i, &low, &last);
		open_value(t, NULL, "[");
		member(t);
		put_u64(t, low);
		member(t);
		put_u64(t, last);
		member(t);
		put_u64(t, hist->count[i]);
		close_value(t, "]");
	}
	close_value(t, "]");
}

static void
interval(text_t *t, const char *name, erx_bench_offset_t offset)
{
	if (offset.empty) {
		key(t, name);
		put(t, "null");
		return;
	}
	open_value(t, name, "[");
	member(t);
	put_i64(t, offset.low);
	member(t);
	put_i64(t, offset.high);
	close_value(t, "]");
}

/* Starts the line: its kind, a space and the open top-level object. */
static text_t
start(char *buf, size_t size, const char *kind)
{
	text_t t = { buf, size, 0, size == 0, true };

	put(&t, kind);
	put(&t, " ");
	open_value(&t, NULL, "{");
	return (t);
}

/* Closes the line; a line that did not fit leaves buf an empty string. */
static size_t
finish(text_t *t)
{
	close_value(t, "}");
	if (t->full) {
		if (t->size != 0)
			t->buf[0] = '\0';
		return (0);
	}
	t->buf[t->len] = '\0';
	return (t->len);
}

size_t
erx_bench_line_cell(char *buf, size_t size, const erx_bench_cell_t *cell)
{
	text_t t = start(buf, size, "BENCH");

	string(&t, "benchmark", cell->benchmark);
	string(&t, "operation", cell->operation);
	open_value(&t, "conditions", "{");
	string(&t, "load", cell->load);
	string(&t, "placement", cell->placement);
	open_value(&t, "parameters", "{");
	for (size_t i = 0; i < cell->nparams; i++) {
		if (cell->params[i].text != NULL)
			string(&t, cell->params[i].name, cell->params[i].text);
		else
			number(&t, cell->params[i].name, cell->params[i].count);
	}
	close_value(&t, "}");
	string(&t, "clock", cell->clock);
	number(&t, "batch", cell->batch);
	close_value(&t, "}");
	number(&t, "frequency_hz", cell->frequency_hz);
	string(&t, "status", cell->status);
	if (cell->reason != NULL)
		string(&t, "reason", cell->reason);
	number(&t, "samples", cell->hist->samples);
	histogram(&t, "histogram", cell->hist);
	if (cell->hist->samples != 0) {
		number(&t, "min", cell->min);
		number(&t, "max", cell->max);
	}
	open_value(&t, "largest", "[");
	for (size_t i = 0; i < cell->nlargest && i < ERX_BENCH_LARGEST; i++)
		pair(&t, cell->largest[i].sequence, cell->largest[i].value);
	close_value(&t, "]");
	open_value(&t, "counts", "{");
	number(&t, "lost", cell->lost);
	number(&t, "early", cell->early);
	number(&t, "missed", cell->missed);
	close_value(&t, "}");
	if (cell->raw != NULL) {
		open_value(&t, "raw", "[");
		for (size_t i = 0; i < cell->nraw; i++) {
			member(&t);
			put_u64(&t, cell->raw[i]);
		}
		close_value(&t, "]");
	}
	if (cell->has_uncertainty)
		number(&t, "uncertainty", cell->uncertainty);
	if (cell->periodic != NULL) {
		open_value(&t, "phases", "[");
		for (unsigned p = 0; p < ERX_BENCH_PHASES; p++)
			pair(&t, cell->periodic->phase_min[p], cell->periodic->phase_returns[p]);
		close_value(&t, "]");
		histogram(&t, "excess", &cell->periodic->excess);
	}
	return (finish(&t));
}

size_t
erx_bench_line_clock(char *buf, size_t size, const erx_bench_calibration_t *clock)
{
	text_t t = start(buf, size, "CLOCK");

	string(&t, "clock", clock->clock);
	number(&t, "frequency_hz", clock->frequency_hz);
	number(&t, "increment", clock->increment);
	number(&t, "read_cost", clock->read_cost);
	number(&t, "wait_rounding", clock->wait_rounding);
	if (clock->cycles_per_tick_milli == 0 || clock->cycles_per_tick_milli > 1000 * 1000)
		string(&t, "cycles_per_tick", "unknown");
	else {
		key(&t, "cycles_per_tick");
		put_milli(&t, clock->cycles_per_tick_milli);
	}
	open_value(&t, "pairs", "[");
	for (size_t i = 0; i < clock->npairs; i++) {
		open_value(&t, NULL, "{");
		open_value(&t, "cpus", "[");
		member(&t);
		put_u64(&t, clock->pairs[i].cpus[0]);
		member(&t);
		put_u64(&t, clock->pairs[i].cpus[1]);
		close_value(&t, "]");
		interval(&t, "before", clock->pairs[i].before);
		interval(&t, "after", clock->pairs[i].after);
		close_value(&t, "}");
	}
	close_value(&t, "]");
	return (finish(&t));
}

size_t
erx_bench_line_window(char *buf, size_t size, uint32_t window, uint32_t thread, const erx_bench_window_t *kept)
{
	text_t t = start(buf, size, "WINDOW");

	number(&t, "window", window);
	number(&t, "thread", thread);
	number(&t, "iterations", kept->iterations);
	number(&t, "longest", kept->longest);
	number(&t, "lost", kept->lost);
	number(&t, "waited", kept->waited);
	return (finish(&t));
}
