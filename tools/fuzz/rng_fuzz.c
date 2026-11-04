/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/rng.h"

#include "blake3/blake3.h"
#include "chacha20/chacha.h"

/* A read's length spans the bound and beyond it. */
#define FUZZ_READ_SPAN	(ERX_RNG_READ_MAX + 64)
/* So does a digest's. */
#define FUZZ_DIGEST_SPAN	(ERX_RNG_DIGEST_INPUT_MAX + 64)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void fuzz_block_key(const uint8_t [ERX_RNG_KEY_LENGTH],
    uint8_t [ERX_RNG_KEY_LENGTH]);
static void fuzz_erased(const void *, size_t);
static void fuzz_mix(erx_rng_t *, const uint8_t *, size_t, bool);
static void fuzz_read(erx_rng_t *, size_t);

static const uint8_t fuzz_nonce[ERX_CHACHA20_NONCE_LENGTH];

/* The first 32 bytes of block 0 of key's stream. */
static void
fuzz_block_key(const uint8_t key[ERX_RNG_KEY_LENGTH],
    uint8_t next[ERX_RNG_KEY_LENGTH])
{
	memset(next, 0, ERX_RNG_KEY_LENGTH);
	if (!erx_chacha20_xor(key, 0, fuzz_nonce, next, next,
	    ERX_RNG_KEY_LENGTH))
		abort();
}

static void
fuzz_erased(const void *bytes, size_t length)
{
	for (size_t index = 0; index < length; index++)
		if (((const uint8_t *)bytes)[index] != 0)
			abort();
}

/*
 * A read from a generator that is not ready, or over the bound, is
 * refused and changes nothing. Any other returns the old key's stream from
 * block 1 and leaves block 0's first 32 bytes as the key, which the output
 * never contains.
 */
static void
fuzz_read(erx_rng_t *rng, size_t length)
{
	uint8_t old[ERX_RNG_KEY_LENGTH], next[ERX_RNG_KEY_LENGTH];
	uint8_t *out, *expected;
	bool ready;

	if ((out = malloc(length == 0 ? 1 : length)) == NULL ||
	    (expected = calloc(1, length == 0 ? 1 : length)) == NULL)
		abort();
	memset(out, 0xa5, length);
	memcpy(old, rng->key, sizeof(old));
	ready = rng->ready;
	if (!erx_rng_read(rng, length == 0 ? NULL : out, length)) {
		if ((ready && length <= ERX_RNG_READ_MAX) ||
		    memcmp(old, rng->key, sizeof(old)) != 0 ||
		    rng->ready != ready)
			abort();
		for (size_t index = 0; index < length; index++)
			if (out[index] != 0xa5)
				abort();
	} else {
		if (!ready || length > ERX_RNG_READ_MAX || !rng->ready ||
		    !erx_chacha20_xor(old, 1, fuzz_nonce, expected, expected,
		    length))
			abort();
		fuzz_block_key(old, next);
		if ((length != 0 && memcmp(out, expected, length) != 0) ||
		    memcmp(rng->key, next, sizeof(next)) != 0)
			abort();
		for (size_t index = 0; index + sizeof(next) <= length; index++)
			if (memcmp(out + index, next, sizeof(next)) == 0)
				abort();
	}
	free(expected);
	free(out);
}

/*
 * A mix, or an init when init is set, makes the key block 0's first 32
 * bytes, from the old key or from the zero key, XORed with the bytes'
 * digest, and erases the digest. A mix into a generator that is not ready
 * is refused and changes nothing. Bytes over the digest's bound are refused
 * before any of that: the refused digest is all zeroes and keys nothing, so a
 * mix changes nothing and an init leaves the generator all zeroes.
 */
static void
fuzz_mix(erx_rng_t *rng, const uint8_t *bytes, size_t length, bool init)
{
	static const uint8_t zero[ERX_RNG_KEY_LENGTH];
	erx_blake3_ctx_t ctx;
	erx_rng_digest_t digest;
	uint8_t expected[ERX_BLAKE3_OUT_LEN], next[ERX_RNG_KEY_LENGTH];
	uint8_t old[ERX_RNG_KEY_LENGTH];
	bool ready;

	memset(&digest, 0xa5, sizeof(digest));
	if (!erx_rng_digest(&digest, bytes, length)) {
		if (length <= ERX_RNG_DIGEST_INPUT_MAX)
			abort();
		fuzz_erased(&digest, sizeof(digest));
		memcpy(old, rng->key, sizeof(old));
		ready = rng->ready;
		if (init) {
			erx_rng_init(rng, &digest);
			fuzz_erased(rng, sizeof(*rng));
		} else if (erx_rng_mix(rng, &digest) || rng->ready != ready ||
		    memcmp(old, rng->key, sizeof(old)) != 0) {
			abort();
		}
		return;
	}
	if (length > ERX_RNG_DIGEST_INPUT_MAX)
		abort();
	erx_blake3_init(&ctx);
	erx_blake3_update(&ctx, bytes, length);
	erx_blake3_final(&ctx, expected);
	if (memcmp(digest.bytes, expected, sizeof(expected)) != 0)
		abort();

	memcpy(old, rng->key, sizeof(old));
	ready = rng->ready;
	fuzz_block_key(init ? zero : rng->key, next);
	if (init) {
		erx_rng_init(rng, &digest);
	} else if (erx_rng_mix(rng, &digest) != ready) {
		abort();
	}
	fuzz_erased(&digest, sizeof(digest));
	if (!init && !ready) {
		if (rng->ready || memcmp(old, rng->key, sizeof(old)) != 0)
			abort();
		return;
	}
	if (!rng->ready)
		abort();
	for (size_t index = 0; index < sizeof(next); index++)
		if (rng->key[index] != (next[index] ^ expected[index]))
			abort();
}

/*
 * The input is a program for one generator, which starts all zeroes and
 * not ready: each operation byte's low two bits choose a read (its length
 * the next two bytes, little-endian, modulo FUZZ_READ_SPAN), a mix or an
 * init (of as many of the following bytes as the next two bytes say,
 * little-endian, modulo FUZZ_DIGEST_SPAN), or a clear. Every outcome is
 * checked against the generator's rules,
 * recomputed from ChaCha20 and BLAKE3.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_rng_t rng;
	size_t cursor, length;
	unsigned int op;

	memset(&rng, 0, sizeof(rng));
	for (cursor = 0; cursor < size;) {
		switch (op = data[cursor++] & 3) {
		case 0:
			length = 0;
			if (cursor < size)
				length = data[cursor++];
			if (cursor < size)
				length |= (size_t)data[cursor++] << 8;
			fuzz_read(&rng, length % FUZZ_READ_SPAN);
			break;
		case 1:
		case 3:
			length = 0;
			if (cursor < size)
				length = data[cursor++];
			if (cursor < size)
				length |= (size_t)data[cursor++] << 8;
			length %= FUZZ_DIGEST_SPAN;
			length = length > size - cursor ? size - cursor : length;
			fuzz_mix(&rng, length == 0 ? NULL : data + cursor, length,
			    op == 3);
			cursor += length;
			break;
		default:
			erx_rng_clear(&rng);
			fuzz_erased(&rng, sizeof(rng));
			break;
		}
	}
	return (0);
}
