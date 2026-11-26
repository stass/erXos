/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The generic timer's virtual counter, which Fiasco leaves readable in user
 * mode, converted to nanoseconds by the core the kernel's trace rings share
 * (erx/core/clock_ns.h).
 *
 * erx_fiasco_counter is the one read of the counter in an erXos program, and
 * the read sits between two ISBs. A read of the counter is not ordered by
 * loads, barriers on memory or acquire semantics: without the first ISB the
 * CPU may take it before a load that came earlier, and without the second it
 * may take it after a load that comes later. The pipe reader depends on both
 * (docs/design-pipes.md, PI6): a writer's stamp must not be taken before the
 * load that told it its earlier write finished, and a reader's mark must not
 * be taken after the copy of wpos that follows it. The memory clobber keeps
 * the compiler from moving those loads across the read. noinline keeps the
 * read in this function, where the build's check of every linked program
 * (CounterReads, tools/lib/erx/counter_reads.rb) looks for it.
 */

#include <stdint.h>

#include "erx/arch/aarch64/sysreg.h"
#include "erx/core/clock_ns.h"
#include "liberx/backend/fiasco/log.h"

uint64_t
erx_fiasco_counter_hz(void)
{
	uint64_t frequency;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
	return (frequency);
}

__attribute__((__noinline__)) uint64_t
erx_fiasco_counter(void)
{
	uint64_t ticks;

	__asm__ volatile("isb\n\tmrs %0, cntvct_el0\n\tisb" : "=r"(ticks) : : "memory");
	return (ticks);
}

/*
 * The CPU's cycle counter, which Fiasco turns on and opens to user mode where its
 * build sets CONFIG_PERF_CNT_USER. The benchmarks' cycle probe reads it
 * (docs/design-bench.md, "The cycle counter"); where user mode may not read it, the
 * read faults and ends the caller.
 */
uint64_t
erx_fiasco_cycles(void)
{
	return (erx_sysreg_pmccntr_el0_read());
}

uint64_t
erx_fiasco_clock_ns(void)
{
	const uint64_t frequency = erx_fiasco_counter_hz();

	return (erx_clock_ticks_ns(erx_fiasco_counter(), frequency));
}
