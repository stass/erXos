/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx_crc32c.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* The definition of the division, one bit at a time: the oracle, sharing nothing with the table. */
static uint32_t
bitwise_crc32c(uint32_t crc, const uint8_t *data, size_t length)
{
	uint32_t state = ~crc;
	size_t i;
	int bit;

	for (i = 0; i < length; i++) {
		state ^= data[i];
		for (bit = 0; bit < 8; bit++)
			state = (state & 1u) != 0 ? (state >> 1) ^ 0x82F63B78u : state >> 1;
	}
	return (~state);
}

/*
 * The first four bytes are a starting value, little-endian, and the fifth chooses a cut; the
 * rest is the input. The value must equal the model's, and checking the two pieces of the cut
 * one after the other must give it again.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const uint8_t *input;
	size_t length, cut;
	uint32_t start, want;

	if (size < 5)
		return (0);
	start = (uint32_t)data[0] | (uint32_t)data[1] << 8 | (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
	input = data + 5;
	length = size - 5;
	cut = data[4] % (length + 1);
	want = bitwise_crc32c(start, input, length);
	if (erx_crc32c(start, input, length) != want)
		abort();
	if (erx_crc32c(erx_crc32c(start, input, cut), input + cut, length - cut) != want)
		abort();
	return (0);
}
