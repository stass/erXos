/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * CRC-32C in portable C, a byte as two table steps of four bits. The 16-entry table is a
 * constant expression of the polynomial, so there is no table to type in or to initialize at
 * run time, and the code has no state for threads to share. It builds for the host, where its
 * unit tests and fuzz target run, and into ERTS.
 */

#include "erx_crc32c.h"

#define POLYNOMIAL	0x82F63B78u

/* One bit of the division: shift right, and subtract the polynomial if a 1 was shifted out. */
#define STEP(value)	(((value) >> 1) ^ (POLYNOMIAL & (0u - ((value) & 1u))))
#define STEP4(value)	STEP(STEP(STEP(STEP(value))))

#define ENTRY(index)	STEP4((uint32_t)(index))

/* nibble_table[n] is the remainder of the four bits n, low bit first. */
static const uint32_t nibble_table[16] = {
	ENTRY(0), ENTRY(1), ENTRY(2), ENTRY(3), ENTRY(4), ENTRY(5), ENTRY(6), ENTRY(7),
	ENTRY(8), ENTRY(9), ENTRY(10), ENTRY(11), ENTRY(12), ENTRY(13), ENTRY(14), ENTRY(15),
};

uint32_t
erx_crc32c(uint32_t crc, const uint8_t *data, size_t length)
{
	uint32_t state = ~crc;
	size_t i;

	for (i = 0; i < length; i++) {
		state ^= data[i];
		state = (state >> 4) ^ nibble_table[state & 0xfu];
		state = (state >> 4) ^ nibble_table[state & 0xfu];
	}
	return (~state);
}
