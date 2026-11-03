/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/rng.h"
#include "erx/explicit_bzero.h"

#include "chacha20/chacha.h"
#include "sha2/sha256.h"

/*
 * Block 0 of every key's stream yields the next key; a read's output
 * starts at block 1, so no output byte ever shares a block with a key.
 */
#define ERX_RNG_KEY_BLOCK	0
#define ERX_RNG_OUTPUT_BLOCK	1

/*
 * How deep erx_rng_burn_stack overwrites the stack below its caller's
 * frame: more than the deepest chain of frames any generator call makes
 * below its own, ChaCha20's or SHA-256's, at every optimization level the
 * stack proof builds (each under 600 bytes), and within the stack proof's
 * frame cap.
 */
#define ERX_RNG_BURN_BYTES	768

_Static_assert(ERX_RNG_KEY_LENGTH == ERX_CHACHA20_KEY_LENGTH,
    "the generator's key is a ChaCha20 key");
_Static_assert(ERX_RNG_DIGEST_LENGTH == ERX_SHA256_DIGEST_LENGTH,
    "a mix's digest is a SHA-256 digest");
_Static_assert(ERX_RNG_KEY_LENGTH == ERX_RNG_DIGEST_LENGTH,
    "a mixed digest covers the whole key");
_Static_assert(ERX_RNG_KEY_LENGTH <= ERX_CHACHA20_BLOCK_LENGTH,
    "the next key fits in block 0");
/* A read's blocks stay below the counter's limit, so no read is refused. */
_Static_assert(ERX_RNG_READ_MAX / ERX_CHACHA20_BLOCK_LENGTH + 1 <
    UINT32_MAX - ERX_RNG_OUTPUT_BLOCK, "a read fits in the counter");

static const uint8_t erx_rng_nonce[ERX_CHACHA20_NONCE_LENGTH];

static void erx_rng_burn_stack(void);
static bool erx_rng_next_key(const erx_rng_t *, uint8_t *);
static bool erx_rng_stream(const erx_rng_t *, uint32_t, uint8_t *, size_t);

/*
 * ChaCha20 and SHA-256 erase their buffers, but the compiler spills key,
 * key-stream and message words into their frames, which a caller cannot
 * name. This frame, called from the generator's own frame once those
 * calls have returned, lies where theirs lay, and is overwritten whole.
 * It stays out of line so that it has a frame of its own.
 */
static __attribute__((__noinline__)) void
erx_rng_burn_stack(void)
{
	volatile uint8_t burn[ERX_RNG_BURN_BYTES];

	for (size_t index = 0; index < sizeof(burn); index++)
		burn[index] = 0;
}

/*
 * Writes length bytes of the current key's stream from block counter
 * onwards to out. The memory primitives are the compiler's builtins: the
 * cores may leave only memcpy and memset to the kernel that links them.
 */
static bool
erx_rng_stream(const erx_rng_t *rng, uint32_t counter, uint8_t *out,
    size_t length)
{
	__builtin_memset(out, 0, length);
	return (erx_chacha20_xor(rng->key, counter, erx_rng_nonce, out, out,
	    length));
}

/* The first 32 bytes of block 0 of the current key's stream. */
static bool
erx_rng_next_key(const erx_rng_t *rng, uint8_t *next)
{
	return (erx_rng_stream(rng, ERX_RNG_KEY_BLOCK, next,
	    ERX_RNG_KEY_LENGTH));
}

void
erx_rng_clear(erx_rng_t *rng)
{
	erx_explicit_bzero(rng, sizeof(*rng));
}

void
erx_rng_digest(erx_rng_digest_t *digest, const void *bytes, size_t length)
{
	erx_sha256_ctx_t hash;

	erx_sha256_init(&hash);
	erx_sha256_update(&hash, bytes, length);
	erx_sha256_final(digest->bytes, &hash);
	erx_rng_burn_stack();
}

/*
 * The all-zero key, which every ready generator starts from and nobody
 * reads from, is spent on the first seed's digest.
 */
void
erx_rng_init(erx_rng_t *rng, erx_rng_digest_t *seed)
{
	bool mixed;

	erx_explicit_bzero(rng, sizeof(*rng));
	rng->ready = true;
	mixed = erx_rng_mix(rng, seed);
	rng->ready = mixed;
}

/*
 * The block-0 bound is a constant, so the stream is never refused; were it
 * to be, the generator would be retired rather than keyed with the bare
 * digest.
 */
bool
erx_rng_mix(erx_rng_t *rng, erx_rng_digest_t *digest)
{
	uint8_t next[ERX_RNG_KEY_LENGTH];
	bool keyed;

	keyed = rng->ready && erx_rng_next_key(rng, next);
	if (keyed) {
		for (size_t index = 0; index < sizeof(rng->key); index++)
			rng->key[index] = next[index] ^ digest->bytes[index];
	} else if (rng->ready) {
		erx_rng_clear(rng);
	}

	erx_explicit_bzero(next, sizeof(next));
	erx_explicit_bzero(digest, sizeof(*digest));
	erx_rng_burn_stack();
	return (keyed);
}

/*
 * The output and the next key come from blocks that the static assertions
 * keep within the counter, so neither stream is ever refused; were one to
 * be, the generator would be retired and out cleared, never returned as
 * output.
 */
bool
erx_rng_read(erx_rng_t *rng, uint8_t *out, size_t length)
{
	uint8_t next[ERX_RNG_KEY_LENGTH];
	bool served;

	if (!rng->ready || length > ERX_RNG_READ_MAX)
		return (false);

	served = erx_rng_next_key(rng, next) && (length == 0 ||
	    erx_rng_stream(rng, ERX_RNG_OUTPUT_BLOCK, out, length));
	if (served) {
		__builtin_memcpy(rng->key, next, sizeof(rng->key));
	} else {
		if (length != 0)
			erx_explicit_bzero(out, length);
		erx_rng_clear(rng);
	}

	erx_explicit_bzero(next, sizeof(next));
	erx_rng_burn_stack();
	return (served);
}
