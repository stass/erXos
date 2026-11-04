/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The generic timer's virtual counter, which Fiasco leaves readable in user
 * mode. A frequency of zero, which no conforming hardware reports, reads as
 * time zero rather than as a division by zero.
 */

#include <stdint.h>

#include "liberx/backend/fiasco/log.h"

#define ERX_NS_PER_SECOND	UINT64_C(1000000000)

uint64_t
erx_fiasco_counter_hz(void)
{
	uint64_t frequency;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frequency));
	return (frequency);
}

uint64_t
erx_fiasco_counter(void)
{
	uint64_t ticks;

	__asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(ticks));
	return (ticks);
}

uint64_t
erx_fiasco_clock_ns(void)
{
	const uint64_t frequency = erx_fiasco_counter_hz();
	const uint64_t ticks = erx_fiasco_counter();

	if (frequency == 0)
		return (0);
	return (ticks / frequency * ERX_NS_PER_SECOND +
	    ticks % frequency * ERX_NS_PER_SECOND / frequency);
}
