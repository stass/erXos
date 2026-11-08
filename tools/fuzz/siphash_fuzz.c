/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <strings.h>

#include "erx_siphash.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define HEADER	(ERX_SIPHASH_KEY_LENGTH + 1)

static uint64_t
rotl(uint64_t x, int b)
{
	return (x << b | x >> (64 - b));
}

static void
sipround(uint64_t v[4])
{
	v[0] += v[1]; v[1] = rotl(v[1], 13); v[1] ^= v[0]; v[0] = rotl(v[0], 32);
	v[2] += v[3]; v[3] = rotl(v[3], 16); v[3] ^= v[2];
	v[0] += v[3]; v[3] = rotl(v[3], 21); v[3] ^= v[0];
	v[2] += v[1]; v[1] = rotl(v[1], 17); v[1] ^= v[2]; v[2] = rotl(v[2], 32);
}

/* The little-endian word of the eight bytes at p, assembled byte by byte. */
static uint64_t
word(const uint8_t *p)
{
	uint64_t m = 0;
	int i;

	for (i = 8; i-- > 0;)
		m = m << 8 | p[i];
	return (m);
}

/*
 * The oracle, sharing nothing with the core but the paper: the message padded at once to whole
 * words, zeros and then the length's low byte as the last byte, and every word compressed
 * alike. 0 when the padded copy cannot be made, else 1 with the hash in hash.
 */
static int
padded_siphash24(const uint8_t key[16], const uint8_t *data, size_t length, uint64_t *hash)
{
	uint64_t k0 = word(key), k1 = word(key + 8), v[4], m;
	size_t words = length / 8 + 1, w;
	uint8_t *padded;
	int i;

	padded = calloc(words, 8);
	if (padded == NULL)
		return (0);
	if (length != 0)
		bcopy(data, padded, length);
	padded[words * 8 - 1] = (uint8_t)length;
	v[0] = k0 ^ 0x736f6d6570736575u;
	v[1] = k1 ^ 0x646f72616e646f6du;
	v[2] = k0 ^ 0x6c7967656e657261u;
	v[3] = k1 ^ 0x7465646279746573u;
	for (w = 0; w < words; w++) {
		m = word(padded + w * 8);
		v[3] ^= m;
		sipround(v);
		sipround(v);
		v[0] ^= m;
	}
	v[2] ^= 0xff;
	for (i = 0; i < 4; i++)
		sipround(v);
	free(padded);
	*hash = v[0] ^ v[1] ^ v[2] ^ v[3];
	return (1);
}

/*
 * The first sixteen bytes are a key and the seventeenth chooses a cut; the rest is the input.
 * The hash must equal the oracle's, given in one update or as the two pieces of the cut, and
 * a state finished between the pieces must still give it.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	const uint8_t *input;
	erx_siphash_t state;
	size_t length, cut;
	uint64_t want;

	if (size < HEADER)
		return (0);
	input = data + HEADER;
	length = size - HEADER;
	cut = data[ERX_SIPHASH_KEY_LENGTH] % (length + 1);
	if (!padded_siphash24(data, input, length, &want))
		return (0);
	erx_siphash24_init(&state, data);
	erx_siphash24_update(&state, input, length);
	if (erx_siphash24_final(&state) != want)
		abort();
	erx_siphash24_init(&state, data);
	erx_siphash24_update(&state, input, cut);
	(void)erx_siphash24_final(&state);
	erx_siphash24_update(&state, input + cut, length - cut);
	if (erx_siphash24_final(&state) != want)
		abort();
	return (0);
}
