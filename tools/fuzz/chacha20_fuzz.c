/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "chacha20/chacha.h"

#define FUZZ_HEADER	(ERX_CHACHA20_KEY_LENGTH + ERX_CHACHA20_NONCE_LENGTH + 4)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint8_t *fuzz_copy(const uint8_t *, size_t);
static bool fuzz_fits(uint32_t, size_t);

/* An exact-size copy, so the sanitizer sees any access past the end. */
static uint8_t *
fuzz_copy(const uint8_t *bytes, size_t length)
{
	uint8_t *copy;

	if ((copy = malloc(length == 0 ? 1 : length)) == NULL)
		abort();
	if (length != 0)
		memcpy(copy, bytes, length);
	return (copy);
}

/* An independent reading of the bound: the stream's last block is 2^32-1. */
static bool
fuzz_fits(uint32_t counter, size_t length)
{
	uint64_t last;

	if (length == 0)
		return (true);
	last = (uint64_t)counter + (length - 1) / ERX_CHACHA20_BLOCK_LENGTH;
	return (last <= UINT32_MAX);
}

/*
 * The input is a key, a nonce, a little-endian counter and the data. The
 * call is refused exactly when the stream passes the counter's last block,
 * and then writes nothing; an accepted stream decrypts back to the data,
 * runs the same in place, and runs the same split at a block boundary.
 * The same data is tried again at the counter's last blocks.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const uint8_t *key, *nonce, *message;
	uint8_t *out, *back, *inplace, *split;
	uint32_t counters[2];
	size_t length, head;

	if (size < FUZZ_HEADER)
		return (0);
	key = data;
	nonce = data + ERX_CHACHA20_KEY_LENGTH;
	counters[0] = (uint32_t)data[44] | (uint32_t)data[45] << 8 |
	    (uint32_t)data[46] << 16 | (uint32_t)data[47] << 24;
	counters[1] = UINT32_MAX - (data[44] & 3);
	message = data + FUZZ_HEADER;
	length = size - FUZZ_HEADER;

	for (size_t round = 0; round < 2; round++) {
		uint32_t counter = counters[round];

		out = fuzz_copy(message, length);
		memset(out, 0xa5, length);
		if (erx_chacha20_xor(key, counter, nonce, message, out,
		    length) != fuzz_fits(counter, length))
			abort();
		if (!fuzz_fits(counter, length)) {
			for (size_t index = 0; index < length; index++)
				if (out[index] != 0xa5)
					abort();
			free(out);
			continue;
		}

		back = fuzz_copy(out, length);
		inplace = fuzz_copy(message, length);
		split = fuzz_copy(message, length);
		head = length / ERX_CHACHA20_BLOCK_LENGTH / 2 *
		    ERX_CHACHA20_BLOCK_LENGTH;
		if (!erx_chacha20_xor(key, counter, nonce, out, back, length) ||
		    !erx_chacha20_xor(key, counter, nonce, inplace, inplace,
		    length) ||
		    !erx_chacha20_xor(key, counter, nonce, split, split, head) ||
		    !erx_chacha20_xor(key, counter +
		    (uint32_t)(head / ERX_CHACHA20_BLOCK_LENGTH), nonce,
		    split + head, split + head, length - head))
			abort();
		if ((length != 0 && memcmp(back, message, length) != 0) ||
		    (length != 0 && memcmp(inplace, out, length) != 0) ||
		    (length != 0 && memcmp(split, out, length) != 0))
			abort();
		free(split);
		free(inplace);
		free(back);
		free(out);
	}
	return (0);
}
