/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "erx_inet_csum.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define HEADER	13

/*
 * The definition, a byte at a time, sharing nothing with the core: a byte at an even position
 * is the high half of its word, and every addition carries end-around at once.
 */
static uint16_t
bytewise_sum(uint16_t sum, const uint8_t *data, size_t length)
{
	uint32_t total = sum;
	size_t i;

	for (i = 0; i < length; i++) {
		total += i % 2 == 0 ? (uint32_t)data[i] << 8 : data[i];
		total = (total & 0xffffu) + (total >> 16);
	}
	return ((uint16_t)total);
}

/*
 * The first two bytes are a starting sum, little-endian; the third chooses a cut; the fourth
 * and fifth choose an even offset and an even span; the next eight are the span's new bytes;
 * the rest is the input. The sum must equal the model's, also when summed as the two pieces
 * of the cut, and when the second piece is copied through erx_inet_copy_sum, which must store
 * its bytes unchanged; and updating the input's checksum field for the span's new bytes must give the
 * recomputed field, or 0x0000 where that is 0xffff.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const uint8_t *input, *replacement;
	uint8_t *changed, *copy;
	size_t length, cut, offset, span;
	uint16_t start, want, field, recomputed;

	if (size < HEADER)
		return (0);
	start = (uint16_t)(data[0] | data[1] << 8);
	replacement = data + 5;
	input = data + HEADER;
	length = size - HEADER;
	cut = data[2] % (length + 1);
	want = bytewise_sum(start, input, length);
	if (erx_inet_sum(start, input, length, 0) != want)
		abort();
	if (erx_inet_sum(erx_inet_sum(start, input, cut, 0), input + cut, length - cut, cut) != want)
		abort();
	copy = malloc(length + 1);
	if (copy == NULL)
		return (0);
	if (erx_inet_copy_sum(erx_inet_sum(start, input, cut, 0), copy + 1, input + cut, length - cut,
	    cut) != want || memcmp(copy + 1, input + cut, length - cut) != 0)
		abort();
	free(copy);
	if (length < 2)
		return (0);
	offset = 2 * (data[3] % (length / 2));
	span = 2 * (1 + data[4] % 4);
	if (span > (length - offset) / 2 * 2)
		span = (length - offset) / 2 * 2;
	changed = malloc(length);
	if (changed == NULL)
		return (0);
	bcopy(input, changed, length);
	bcopy(replacement, changed + offset, span);
	field = (uint16_t)~bytewise_sum(0, input, length);
	recomputed = (uint16_t)~bytewise_sum(0, changed, length);
	free(changed);
	if (erx_inet_csum_update(field, input + offset, replacement, span) != (recomputed == 0xffffu ? 0 : recomputed))
		abort();
	return (0);
}
