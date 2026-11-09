/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * SipHash-2-4 in portable C, written from the paper's definition: two rounds per 8-byte word
 * and four to finish. Words are read as little-endian bytes, so the value is the same on every
 * host. erXos's ERTS links it statically, erx_net's portable library outside erXos links it
 * too, and its unit tests and fuzz target build it for the host.
 */

#include "erx_siphash.h"

#include <stdint.h>
#include <strings.h>

#define ROTL(x, b)	(((x) << (b)) | ((x) >> (64 - (b))))

/*
 * Zeroes length bytes at buf even when nothing reads them afterwards, as BSD's explicit_bzero
 * does: each store goes through a volatile lvalue, which the compiler must perform, where a
 * plain bzero of a dead buffer may be removed. erx_net carries its own, since it builds
 * outside erXos's tree and not every host's C library has explicit_bzero.
 */
static void
erase(void *buf, size_t length)
{
	volatile uint8_t *bytes = buf;

	for (size_t index = 0; index < length; index++)
		bytes[index] = 0;
}

/* The eight bytes at p as a little-endian word. */
static uint64_t
load64(const uint8_t *p)
{

	return ((uint64_t)p[0] | (uint64_t)p[1] << 8 | (uint64_t)p[2] << 16 | (uint64_t)p[3] << 24 |
	    (uint64_t)p[4] << 32 | (uint64_t)p[5] << 40 | (uint64_t)p[6] << 48 | (uint64_t)p[7] << 56);
}

/* The paper's SipRound, count times. */
static void
rounds(uint64_t v[4], int count)
{

	while (count-- > 0) {
		v[0] += v[1]; v[1] = ROTL(v[1], 13); v[1] ^= v[0]; v[0] = ROTL(v[0], 32);
		v[2] += v[3]; v[3] = ROTL(v[3], 16); v[3] ^= v[2];
		v[0] += v[3]; v[3] = ROTL(v[3], 21); v[3] ^= v[0];
		v[2] += v[1]; v[1] = ROTL(v[1], 17); v[1] ^= v[2]; v[2] = ROTL(v[2], 32);
	}
}

/* One message word: two compression rounds. */
static void
compress(uint64_t v[4], uint64_t m)
{

	v[3] ^= m;
	rounds(v, 2);
	v[0] ^= m;
}

void
erx_siphash24_init(erx_siphash_t *state, const uint8_t key[ERX_SIPHASH_KEY_LENGTH])
{
	uint64_t k0 = load64(key), k1 = load64(key + 8);

	state->v[0] = k0 ^ 0x736f6d6570736575u;
	state->v[1] = k1 ^ 0x646f72616e646f6du;
	state->v[2] = k0 ^ 0x6c7967656e657261u;
	state->v[3] = k1 ^ 0x7465646279746573u;
	bzero(state->pending, sizeof(state->pending));
	state->length = 0;
	erase(&k0, sizeof(k0));
	erase(&k1, sizeof(k1));
}

/*
 * Bytes fill the pending word first; each word completed is compressed, and the bytes after
 * the last whole word wait in pending. state->length counts modulo 2^64, and only its low byte
 * is used.
 */
void
erx_siphash24_update(erx_siphash_t *state, const uint8_t *data, size_t length)
{
	size_t pending_length = (size_t)(state->length % 8), fill_length;

	if (length == 0)
		return;

	state->length += length;
	if (pending_length != 0) {
		fill_length = 8 - pending_length < length ? 8 - pending_length : length;
		bcopy(data, state->pending + pending_length, fill_length);
		data += fill_length;
		length -= fill_length;
		if (pending_length + fill_length < 8)
			return;
		compress(state->v, load64(state->pending));
	}
	for (; length >= 8; data += 8, length -= 8)
		compress(state->v, load64(data));
	if (length != 0)
		bcopy(data, state->pending, length);
}

/*
 * The last word is the pending bytes, zero above them, with the length's low byte on top;
 * then 0xff into v2 and four finishing rounds. The work is on a copy, which is erased.
 */
uint64_t
erx_siphash24_final(const erx_siphash_t *state)
{
	uint64_t v[4], last, hash;
	size_t pending_length = (size_t)(state->length % 8), i;

	bcopy(state->v, v, sizeof(v));
	last = (state->length & 0xffu) << 56;
	for (i = 0; i < pending_length; i++)
		last |= (uint64_t)state->pending[i] << (8 * i);
	compress(v, last);
	v[2] ^= 0xffu;
	rounds(v, 4);
	hash = v[0] ^ v[1] ^ v[2] ^ v[3];
	erase(v, sizeof(v));
	return (hash);
}

void
erx_siphash24_erase(erx_siphash_t *state)
{

	erase(state, sizeof(*state));
}
