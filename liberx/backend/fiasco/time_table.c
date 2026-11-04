/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "liberx/backend/fiasco/time_table.h"

#define TIME_NS_PER_SECOND	UINT64_C(1000000000)
#define TIME_NS_PER_US		UINT64_C(1000)
#define TIME_SHIFT_MAX		63u

/* Only a product: the root links no 128-bit division. */
__extension__ typedef unsigned __int128 time_wide_t;

/*
 * Long division of 10^9 * 2^shift by hz, one bit of shift at a time, stopping before
 * the rounding up could push the quotient past 64 bits. hz stays below 2^63 on any
 * counter, so the doubled remainder fits.
 */
erx_fiasco_time_scale_t
erx_fiasco_time_scale(uint64_t hz)
{
	erx_fiasco_time_scale_t scale = { .mult = 0, .shift = 0 };
	uint64_t remainder;

	if (hz == 0 || hz >> 63 != 0)
		return (scale);
	scale.mult = TIME_NS_PER_SECOND / hz;
	remainder = TIME_NS_PER_SECOND % hz;
	while (scale.shift < TIME_SHIFT_MAX && scale.mult >> 62 == 0) {
		remainder <<= 1;
		scale.mult <<= 1;
		if (remainder >= hz) {
			remainder -= hz;
			scale.mult |= 1;
		}
		scale.shift++;
	}
	if (remainder != 0)
		scale.mult++;
	return (scale);
}

uint64_t
erx_fiasco_time_ns(uint64_t counter, erx_fiasco_time_scale_t scale)
{
	return ((uint64_t)(((time_wide_t)counter * scale.mult) >> scale.shift));
}

uint64_t
erx_fiasco_time_wait_us(uint64_t now_ns, uint64_t deadline_ns, uint64_t max_us)
{
	uint64_t wait_us;

	if (now_ns >= deadline_ns)
		return (0);
	wait_us = (deadline_ns - now_ns - 1) / TIME_NS_PER_US + 1;
	return (wait_us < max_us ? wait_us : max_us);
}
