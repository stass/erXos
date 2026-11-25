/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/core/clock_inverse.h"

/*
 * The least count with count * scaler >= us * 2^bits is that quotient rounded
 * up. us * 2^bits takes up to 96 bits, so it is divided in two parts, us =
 * whole * scaler + part: whole * 2^bits is exact, and part * 2^bits is divided
 * rounded up; part * 2^bits + scaler - 1 stays below 2^64, since part < scaler
 * < 2^32 and bits <= 32. The
 * two add up to the quotient rounded up because whole * 2^bits is a whole
 * number.
 */
uint64_t
erx_clock_first_count(uint64_t us, uint32_t scaler, uint32_t shift)
{
	const uint32_t bits = 32 - shift;
	const uint64_t whole = us / scaler, part = us % scaler;
	const uint64_t part_counts = ((part << bits) + scaler - 1) / scaler;

	if (whole > (UINT64_MAX - part_counts) >> bits)
		return (UINT64_MAX);
	return ((whole << bits) + part_counts);
}
