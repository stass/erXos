/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The native bench root's common part (guest.c) and what each benchmark's file (wake.c,
 * nullcall.c, sched.c, vm.c) gives it. tools/lib/erx/native_bench.rb links guest.c with the one file of
 * the benchmark a boot times, so a boot prints only that benchmark's BENCH lines.
 */

#ifndef ERX_NATIVE_BENCH_ROOT_H
#define ERX_NATIVE_BENCH_ROOT_H

#include <stddef.h>
#include <stdint.h>

#include "erx/pack.h"
#include "test/guest/bench/bench_clock.h"
#include "test/guest/bench/bench_hist.h"
#include "test/guest/bench/bench_line.h"

/*
 * The landing forms of the fast and periodic profiles (docs/design-bench.md, "Profiles"),
 * which tools/lib/erx/native_bench.rb passes from NativeBench::LANDING_PROFILES.
 */
#if !defined(ERX_BENCH_FAST_WARMUP) || !defined(ERX_BENCH_FAST_SAMPLES) || !defined(ERX_BENCH_PERIODIC_SAMPLES)
#error "the build passes the landing profiles' sizes"
#endif
#define FAST_WARMUP	ERX_BENCH_FAST_WARMUP
#define FAST_SAMPLES	ERX_BENCH_FAST_SAMPLES
#define PERIODIC_SAMPLES	ERX_BENCH_PERIODIC_SAMPLES
#define NS_PER_SECOND	UINT64_C(1000000000)
/* How long the root waits for another thread or task before the boot fails as stuck. */
#define PATIENCE_NS	(UINT64_C(30) * NS_PER_SECOND)
/* The root's threads besides its first, each with a stack of its own. */
#define BENCH_THREADS	2u

/* The benchmark's name, as its BENCH lines give it, and its cells: its file defines both. */
extern const char bench_benchmark[];
/*
 * Times the benchmark's cells on a machine of cpus CPUs, the root's first thread on CPU 0,
 * and prints a BENCH line for each and the CLOCK line, whose pair, on more than one CPU,
 * is CPU 0 and the last. pack is the boot image's archive, for a task's program.
 */
void	bench_cells(uint32_t cpus, const erx_pack_view_t *pack);

/* The scratch the cells summarize into, and the root's reads of the counter at its start. */
extern erx_bench_hist_t bench_hist;

void	bench_say(const char *text);
/* Ends the machine with text, a FAILED line: a setup failure, which prints no cell. */
_Noreturn void	bench_fail(const char *text);
/* A wait blocks between looks (docs/design-fiasco.md, "A wait blocks"). */
void	bench_wait_poll(void);
/* Starts a thread of the root of thread_class on cpu at entry(index), on stack index. */
void	bench_thread_start(uint32_t index, uint32_t cpu, uint32_t thread_class, void (*entry)(uint64_t));

erx_bench_cell_t	bench_cell_of(const char *operation, const char *placement);
/* The cell's histogram (bench_hist), extremes and largest from n samples; the status and the rest are the caller's. */
void	bench_summarize(erx_bench_cell_t *cell, const uint64_t *samples, size_t n, erx_bench_sample_t *top);
void	bench_print(const erx_bench_cell_t *cell);
void	bench_print_unsupported(erx_bench_cell_t cell, const char *reason);
/* The root's side, A, of one calibration between CPU 0 and the CPU whose thread runs bench_calibrate_b. */
erx_bench_offset_t	bench_calibrate_a(void);
void	bench_calibrate_b(void);
/* One calibration of CPU 0 against cpu, whose B is a new thread of the root at stack index, asleep for good after. */
erx_bench_offset_t	bench_calibrate_on(uint32_t index, uint32_t cpu);
void	bench_print_clock(const erx_bench_pair_t *pair, size_t npairs);

#endif /* ERX_NATIVE_BENCH_ROOT_H */
