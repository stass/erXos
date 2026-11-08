/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_siphash24 against the 64 test vectors of the SipHash reference implementation
 * (vectors.h, the paper's appendix A vector among them), against itself over every way of
 * feeding an input in two pieces, and against a model that pads the whole message first and
 * then compresses it word by word. Prints "erx_siphash done" and exits 0 when all hold; on a
 * failure it prints the case and exits 1.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_siphash.h"

/* The largest call of erx_bytes_nif.c. */
#define LARGEST_CALL	65536u

/*
 * vectors_sip64 of the reference implementation: the hash under the key 00 01 .. 0f of the
 * message 00 01 .. n-1, for n of 0 to 63, as 64-bit values (the reference lists their
 * little-endian bytes). The paper's appendix A is n = 15, a129ca6149be45e5.
 */
static const uint64_t vectors[64] = {
	0x726fdb47dd0e0e31u, 0x74f839c593dc67fdu, 0x0d6c8009d9a94f5au, 0x85676696d7fb7e2du,
	0xcf2794e0277187b7u, 0x18765564cd99a68du, 0xcbc9466e58fee3ceu, 0xab0200f58b01d137u,
	0x93f5f5799a932462u, 0x9e0082df0ba9e4b0u, 0x7a5dbbc594ddb9f3u, 0xf4b32f46226bada7u,
	0x751e8fbc860ee5fbu, 0x14ea5627c0843d90u, 0xf723ca908e7af2eeu, 0xa129ca6149be45e5u,
	0x3f2acc7f57c29bdbu, 0x699ae9f52cbe4794u, 0x4bc1b3f0968dd39cu, 0xbb6dc91da77961bdu,
	0xbed65cf21aa2ee98u, 0xd0f2cbb02e3b67c7u, 0x93536795e3a33e88u, 0xa80c038ccd5ccec8u,
	0xb8ad50c6f649af94u, 0xbce192de8a85b8eau, 0x17d835b85bbb15f3u, 0x2f2e6163076bcfadu,
	0xde4daaaca71dc9a5u, 0xa6a2506687956571u, 0xad87a3535c49ef28u, 0x32d892fad841c342u,
	0x7127512f72f27cceu, 0xa7f32346f95978e3u, 0x12e0b01abb051238u, 0x15e034d40fa197aeu,
	0x314dffbe0815a3b4u, 0x027990f029623981u, 0xcadcd4e59ef40c4du, 0x9abfd8766a33735cu,
	0x0e3ea96b5304a7d0u, 0xad0c42d6fc585992u, 0x187306c89bc215a9u, 0xd4a60abcf3792b95u,
	0xf935451de4f21df2u, 0xa9538f0419755787u, 0xdb9acddff56ca510u, 0xd06c98cd5c0975ebu,
	0xe612a3cb9ecba951u, 0xc766e62cfcadaf96u, 0xee64435a9752fe72u, 0xa192d576b245165au,
	0x0a8787bf8ecb74b2u, 0x81b3e73d20b49b6fu, 0x7fa8220ba3b2eceau, 0x245731c13ca42499u,
	0xb78dbfaf3a8d83bdu, 0xea1ad565322a1a0bu, 0x60e61c23a3795013u, 0x6606d7e446282b93u,
	0x6ca4ecb15c5f91e1u, 0x9f626da15c9625f3u, 0xe51b38608ef25f57u, 0x958a324ceb064572u,
};

static uint64_t
rotl(uint64_t x, int b)
{
	return (x << b | x >> (64 - b));
}

static void
sipround(uint64_t *v0, uint64_t *v1, uint64_t *v2, uint64_t *v3)
{
	*v0 += *v1; *v1 = rotl(*v1, 13); *v1 ^= *v0; *v0 = rotl(*v0, 32);
	*v2 += *v3; *v3 = rotl(*v3, 16); *v3 ^= *v2;
	*v0 += *v3; *v3 = rotl(*v3, 21); *v3 ^= *v0;
	*v2 += *v1; *v1 = rotl(*v1, 17); *v1 ^= *v2; *v2 = rotl(*v2, 32);
}

/*
 * The model: the message padded at once to whole words, zeros and then the length's low byte
 * as the last byte, and every word compressed alike; words are assembled byte by byte.
 */
static uint64_t
padded_siphash24(const uint8_t key[16], const uint8_t *data, size_t length)
{
	uint64_t k0 = 0, k1 = 0, v0, v1, v2, v3, m;
	uint8_t *padded;
	size_t words = length / 8 + 1, w, i;

	for (i = 8; i-- > 0;) {
		k0 = k0 << 8 | key[i];
		k1 = k1 << 8 | key[8 + i];
	}
	padded = calloc(words, 8);
	if (padded == NULL)
		exit(1);
	if (length != 0)
		memcpy(padded, data, length);
	padded[words * 8 - 1] = (uint8_t)length;
	v0 = k0 ^ 0x736f6d6570736575u;
	v1 = k1 ^ 0x646f72616e646f6du;
	v2 = k0 ^ 0x6c7967656e657261u;
	v3 = k1 ^ 0x7465646279746573u;
	for (w = 0; w < words; w++) {
		for (m = 0, i = 8; i-- > 0;)
			m = m << 8 | padded[w * 8 + i];
		v3 ^= m;
		sipround(&v0, &v1, &v2, &v3);
		sipround(&v0, &v1, &v2, &v3);
		v0 ^= m;
	}
	v2 ^= 0xff;
	for (i = 0; i < 4; i++)
		sipround(&v0, &v1, &v2, &v3);
	free(padded);
	return (v0 ^ v1 ^ v2 ^ v3);
}

static uint64_t
one_shot(const uint8_t key[16], const uint8_t *data, size_t length)
{
	erx_siphash_t state;

	erx_siphash24_init(&state, key);
	erx_siphash24_update(&state, data, length);
	return (erx_siphash24_final(&state));
}

static void
expect(const char *what, uint64_t got, uint64_t want)
{
	if (got != want) {
		printf("%s: got %016llx, want %016llx\n", what, (unsigned long long)got,
		    (unsigned long long)want);
		exit(1);
	}
}

static void
reference_vectors(void)
{
	uint8_t key[16], message[64];
	char what[64];
	size_t i;

	for (i = 0; i < 16; i++)
		key[i] = (uint8_t)i;
	for (i = 0; i < 64; i++)
		message[i] = (uint8_t)i;
	for (i = 0; i < 64; i++) {
		snprintf(what, sizeof(what), "vector %zu", i);
		expect(what, one_shot(key, message, i), vectors[i]);
		snprintf(what, sizeof(what), "vector %zu by the model", i);
		expect(what, padded_siphash24(key, message, i), vectors[i]);
	}
	expect("no bytes, NULL", one_shot(key, NULL, 0), vectors[0]);
}

static uint32_t
next_random(uint32_t *seed)
{
	*seed = *seed * 1103515245u + 12345u;
	return (*seed >> 8);
}

/*
 * Every cut of an input into two updates gives the model's hash, and so does a state finished
 * twice or finished and then extended, since finishing leaves a state as it was.
 */
static void
cuts_and_model(void)
{
	uint8_t key[16], data[300];
	uint32_t seed = 777u;
	erx_siphash_t state;
	uint64_t want;
	size_t length, cut, i;
	char what[64];

	for (i = 0; i < 16; i++)
		key[i] = (uint8_t)next_random(&seed);
	for (i = 0; i < sizeof(data); i++)
		data[i] = (uint8_t)next_random(&seed);
	for (length = 0; length <= sizeof(data); length++) {
		want = padded_siphash24(key, data, length);
		for (cut = 0; cut <= length; cut++) {
			snprintf(what, sizeof(what), "length %zu cut at %zu", length, cut);
			erx_siphash24_init(&state, key);
			erx_siphash24_update(&state, data, cut);
			(void)erx_siphash24_final(&state);
			erx_siphash24_update(&state, data + cut, length - cut);
			expect(what, erx_siphash24_final(&state), want);
			expect(what, erx_siphash24_final(&state), want);
		}
	}
}

/* An input past 255 bytes enters only its length's low byte, and the largest call runs clean. */
static void
long_inputs(void)
{
	uint8_t key[16] = { 0 }, *data;

	data = calloc(LARGEST_CALL, 1);
	if (data == NULL)
		exit(1);
	expect("256 zeros", one_shot(key, data, 256), padded_siphash24(key, data, 256));
	expect("64 KiB of zeros", one_shot(key, data, LARGEST_CALL), padded_siphash24(key, data, LARGEST_CALL));
	free(data);
}

int
main(void)
{

	reference_vectors();
	cuts_and_model();
	long_inputs();
	printf("erx_siphash done\n");
	return (0);
}
