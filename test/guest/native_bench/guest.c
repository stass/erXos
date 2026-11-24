/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The native bench guest (docs/design-bench.md, "The first five benchmarks"): the root of
 * a stand-in image that times one benchmark's native landing cells, which the benchmark's
 * own file gives (bench_root.h), prints one BENCH line per cell and one CLOCK line, then
 * ends the machine.
 *
 * Every boot names itself (docs/design-bench.md, "The bench image's boot set"): the first
 * erx.arg word of the command line is its boot name, and the root prints
 * "erx: bench: boot NAME" once it is up and after each BENCH and CLOCK line, and
 * "erx: bench: boot NAME done" or "... deadline" as its last line before the end. Every
 * end, a setup failure's too, is the machine's end with a reset, so a board downloads its
 * next boot. A thread of the root's own sleeps until the boot's deadline, the
 * ERX_BENCH_DEADLINE_S seconds the host builds it with, and ends a boot whose cells have
 * not finished by then.
 *
 * Every interval is ticks of erx_fiasco_counter. A setup failure ends the machine with a
 * FAILED line and prints no cell, which fails the host's run; a wrong result in a cell is
 * that cell's failed status.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/boot_args.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/root_layout.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "test/guest/native_bench/bench_root.h"

#define READ_PAIRS	10000u
#define ROUNDS		1000u
#define POLL_US		UINT64_C(100)
#define STACK_BYTES	16384u
#define LINE_BYTES	65536u
#define NAME_DIGITS	32u
/* The deadline thread's index, past every benchmark's own (bench_root.h). */
#define DEADLINE_THREAD	BENCH_THREADS

#ifndef ERX_BENCH_DEADLINE_S
#error "the host builds the root with its deadline (NativeBench.flags)"
#endif

void erx_fiasco_root_main(void);

erx_bench_hist_t bench_hist;

static _Alignas(16) uint8_t thread_stacks[BENCH_THREADS + 1][STACK_BYTES];
/* The boot's name, NUL-ended, once root_main has read it. */
static char boot_name[NAME_DIGITS + 1];
/* Set by the one caller that ends the boot: the done path, the deadline or a failure. */
static _Atomic uint32_t bench_ending;
/* When the deadline thread ends the boot, on erx_fiasco_clock_ns's clock. */
static uint64_t deadline_ns;
static erx_bench_token_t token;
static erx_bench_round_t rounds[ROUNDS];
static erx_bench_reads_t pairs[READ_PAIRS];
static char line[LINE_BYTES];

static size_t
length_of(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	return (length);
}

void
bench_say(const char *text)
{
	erx_fiasco_console_write(text, length_of(text));
}

/*
 * The one way a boot ends: the first caller prints its last line, text, and ends the
 * machine with a reset; any later caller sleeps, so the console never shows two ends.
 */
static _Noreturn void
end_with(const char *text, size_t length)
{
	if (atomic_exchange_explicit(&bench_ending, 1, memory_order_acq_rel) != 0)
		erx_fiasco_sleep_forever();
	erx_fiasco_console_write(text, length);
	erx_fiasco_end(ERX_FIASCO_END_ASKED_RESET, NULL);
}

_Noreturn void
bench_fail(const char *text)
{
	end_with(text, length_of(text));
}

/* "erx: bench: boot NAME", then " form" when form is given, as one console write. */
static size_t
naming_line(char *out, const char *form)
{
	static const char head[] = "erx: bench: boot ";
	size_t length = 0;

	for (size_t at = 0; at < sizeof(head) - 1; at++)
		out[length++] = head[at];
	for (size_t at = 0; at < NAME_DIGITS; at++)
		out[length++] = boot_name[at];
	if (form != NULL) {
		out[length++] = ' ';
		for (size_t at = 0; form[at] != '\0'; at++)
			out[length++] = form[at];
	}
	out[length++] = '\n';
	return (length);
}

/* The longest naming line: its head, the name, " deadline" and the line end. */
#define NAMING_BYTES	(sizeof("erx: bench: boot ") + NAME_DIGITS + sizeof(" deadline"))

static void
say_name(void)
{
	char text[NAMING_BYTES];

	erx_fiasco_console_write(text, naming_line(text, NULL));
}

/* The boot's end with its naming line's form, done or deadline, as its last line. */
static _Noreturn void
bench_end(const char *form)
{
	char text[NAMING_BYTES];

	end_with(text, naming_line(text, form));
}

static bool
name_digit(char c)
{
	return ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
}

/*
 * Takes the command line's first erx.arg word as the boot's name, if it is one: thirty-two
 * lowercase hexadecimal digits. A line the parser refuses names no boot.
 */
static bool
read_name(const erx_boot_handoff_view_t *handoff)
{
	erx_boot_args_t args;
	const char *word;
	size_t cursor = 0, length;

	if (!erx_boot_args_parse(handoff->bootargs, handoff->bootargs_len, &args) ||
	    !erx_boot_args_next_arg(handoff->bootargs, handoff->bootargs_len, &cursor, &word, &length) ||
	    length != NAME_DIGITS)
		return (false);
	for (size_t at = 0; at < NAME_DIGITS; at++) {
		if (!name_digit(word[at]))
			return (false);
		boot_name[at] = word[at];
	}
	boot_name[NAME_DIGITS] = '\0';
	return (true);
}

void
bench_wait_poll(void)
{
	erx_fiasco_test_ipc_sleep_us(POLL_US);
}

void
bench_thread_start(uint32_t index, uint32_t cpu, uint32_t thread_class, void (*entry)(uint64_t))
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;

	start.regs.sp = (uint64_t)(uintptr_t)(thread_stacks[index] + STACK_BYTES);
	start.regs.pc = (uint64_t)(uintptr_t)entry;
	start.regs.gpr[0] = index;
	/* erx_thread_create takes the new thread's starting registers from the caller's UTCB. */
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	if (erx_thread_create(0, 0, 0, thread_class, &thread) != ERX_OK ||
	    erx_thread_set_affinity(thread, UINT64_C(1) << cpu) != ERX_OK || erx_thread_start(thread) != ERX_OK)
		bench_fail("erx: bench: no thread FAILED\n");
}

/* The ERX_BENCH_LARGEST largest of n values, largest first, earlier first among equals. */
static size_t
largest_of(const uint64_t *samples, size_t n, erx_bench_sample_t *top)
{
	size_t kept = 0;

	for (size_t at = 0; at < n; at++) {
		size_t place = kept;

		while (place > 0 && top[place - 1].value < samples[at])
			place--;
		if (place >= ERX_BENCH_LARGEST)
			continue;
		for (size_t move = kept < ERX_BENCH_LARGEST ? kept : ERX_BENCH_LARGEST - 1; move > place; move--)
			top[move] = top[move - 1];
		top[place] = (erx_bench_sample_t){ .sequence = at, .value = samples[at] };
		if (kept < ERX_BENCH_LARGEST)
			kept++;
	}
	return (kept);
}

void
bench_summarize(erx_bench_cell_t *cell, const uint64_t *samples, size_t n, erx_bench_sample_t *top)
{
	for (size_t at = 0; at < ERX_BENCH_HIST_BUCKETS; at++)
		bench_hist.count[at] = 0;
	bench_hist.samples = 0;
	cell->min = UINT64_MAX;
	cell->max = 0;
	for (size_t at = 0; at < n; at++) {
		erx_bench_hist_add(&bench_hist, samples[at]);
		cell->min = samples[at] < cell->min ? samples[at] : cell->min;
		cell->max = samples[at] > cell->max ? samples[at] : cell->max;
	}
	cell->hist = &bench_hist;
	cell->largest = top;
	cell->nlargest = largest_of(samples, n, top);
}

static void
print_line(size_t length)
{
	if (length == 0 || length >= sizeof(line) - 1)
		bench_fail("erx: bench: a line did not fit FAILED\n");
	line[length] = '\n';
	erx_fiasco_console_write(line, length + 1);
	say_name();
}

void
bench_print(const erx_bench_cell_t *cell)
{
	print_line(erx_bench_line_cell(line, sizeof(line), cell));
#ifdef ERX_BENCH_SEED_HANG
	/* The hang seed: a cell that never finishes, which only the deadline thread ends. */
	for (;;)
		;
#endif
}

erx_bench_cell_t
bench_cell_of(const char *operation, const char *placement)
{
	return ((erx_bench_cell_t){ .benchmark = bench_benchmark, .operation = operation, .load = "idle",
	    .placement = placement, .clock = "counter", .batch = 1, .frequency_hz = erx_fiasco_counter_hz(),
	    .status = "measured" });
}

void
bench_print_unsupported(erx_bench_cell_t cell, const char *reason)
{
	erx_bench_sample_t top[ERX_BENCH_LARGEST];

	cell.status = "unsupported";
	cell.reason = reason;
	bench_summarize(&cell, NULL, 0, top);
	bench_print(&cell);
}

erx_bench_offset_t
bench_calibrate_a(void)
{
	erx_bench_rounds_a(&token, erx_fiasco_counter, rounds, ROUNDS);
	return (erx_bench_offset(rounds, ROUNDS, erx_bench_read_calibration(pairs, READ_PAIRS, &bench_hist).increment));
}

void
bench_calibrate_b(void)
{
	erx_bench_rounds_b(&token, erx_fiasco_counter, ROUNDS);
}

static void
calibrate_main(uint64_t index)
{
	(void)index;
	bench_calibrate_b();
	erx_fiasco_sleep_forever();
}

erx_bench_offset_t
bench_calibrate_on(uint32_t index, uint32_t cpu)
{
	bench_thread_start(index, cpu, ERX_THREAD_CLASS_WORKER, calibrate_main);
	return (bench_calibrate_a());
}

void
bench_print_clock(const erx_bench_pair_t *pair, size_t npairs)
{
	const uint64_t hz = erx_fiasco_counter_hz();
	const erx_bench_read_cal_t reads = erx_bench_read_calibration(pairs, READ_PAIRS, &bench_hist);
	const erx_bench_calibration_t clock = { .clock = "counter", .frequency_hz = hz, .increment = reads.increment,
	    .read_cost = reads.read_cost, .wait_rounding = (hz + 999999) / 1000000, .cycles_per_tick_milli = 0,
	    .pairs = pair, .npairs = npairs };

	print_line(erx_bench_line_clock(line, sizeof(line), &clock));
}

/*
 * Sleeps until the boot's deadline and ends the boot there. It is a thread of the root's
 * band, which every thread of the root runs at, so a cell that spins on its CPU shares
 * that CPU with it at the slice's end; it sleeps through the cells and never runs while
 * they do.
 */
static void
deadline_main(uint64_t index)
{
	(void)index;
	for (uint64_t now = erx_fiasco_clock_ns(); now < deadline_ns; now = erx_fiasco_clock_ns())
		erx_fiasco_test_ipc_sleep_us((deadline_ns - now) / 1000u + 1u);
	bench_end("deadline");
}

void
erx_fiasco_root_main(void)
{
	static erx_boot_handoff_view_t handoff;
	/* The boot archive, which a benchmark's test task loads its program from. */
	static erx_pack_view_t pack;
	const char *reason = erx_fiasco_root_open(&handoff, &pack);

	if (reason == NULL && !read_name(&handoff))
		bench_fail("erx: bench: no boot name\n");
	if (reason == NULL)
		reason = erx_fiasco_root_up((const void *)(uintptr_t)handoff.image.start, (size_t)handoff.image.size, 0,
		    NULL, ERX_FIASCO_ROOT_SLICE_US);
	if (reason != NULL) {
		bench_say("erx: bench: the root did not come up FAILED: ");
		bench_say(reason);
		bench_fail("\n");
	}
	say_name();
	erx_bench_read_pairs(erx_fiasco_counter, pairs, READ_PAIRS);
	deadline_ns = erx_fiasco_clock_ns() + (uint64_t)ERX_BENCH_DEADLINE_S * NS_PER_SECOND;
#ifndef ERX_BENCH_SEED_NO_DEADLINE
	bench_thread_start(DEADLINE_THREAD, 0, ERX_THREAD_CLASS_WORKER, deadline_main);
#endif
	bench_say("erx: bench: timing\n");
	bench_cells(erx_fiasco_test_cpu_count(), &pack);
	bench_end("done");
}
