/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_RNG_H
#define ERX_CORE_RNG_H

/*
 * The kernel's entropy generator: one ChaCha20 key (RFC 8439), used with
 * the zero nonce. A header of include/erx/core/ is the seam between the
 * C17 cores and the stopgap's C++ glue: it compiles as C17 and as C++ and
 * includes only the freestanding standard headers.
 *
 * Every read and every mix spends the current key exactly once and
 * leaves a new one, so no key makes two key streams:
 *
 * * erx_rng_read(rng, out, length), for length up to ERX_RNG_READ_MAX,
 *   writes the key stream's bytes from block 1 onwards to out, and the
 *   first 32 bytes of block 0, which it never returns, become the new
 *   key (fast key erasure). Whoever later learns the generator's state
 *   learns nothing of what it produced before.
 * * erx_rng_mix(rng, digest) makes the new key the first 32 bytes of
 *   block 0 XORed with the BLAKE3 digest of the mixed bytes. Whoever does
 *   not know the key cannot choose or weaken the next one, whatever bytes
 *   they mix in, and mixing in bytes an observer cannot guess recovers
 *   from a key the observer knew.
 *
 * Mixing takes a digest, not the bytes: erx_rng_digest hashes at most
 * ERX_RNG_DIGEST_INPUT_MAX bytes and touches no generator, so the caller
 * hashes outside whatever serializes the generator, which then holds for one
 * ChaCha20 block, not for a hash whose length a domain chose. A digest is spent
 * by the call that takes it, which erases it. The bound is one BLAKE3 chunk,
 * which has no chaining values to keep, so the hash's state sits on the call's
 * own stack and the caller supplies no memory; a source longer than the bound
 * mixes in parts, each with its own digest. The bytes are the caller's, and so
 * is erasing them.
 *
 * A generator is ready only from erx_rng_init, which keys it with its
 * first seed's digest, until erx_rng_clear retires it. A retired or never
 * initialized generator (all zero bytes) refuses reads and mixes, so no
 * output ever comes from a key nobody seeded.
 *
 * The functions read and write only the state, the digest and the
 * buffers passed to them and their own stack. They erase the key streams and
 * digests they work with and overwrite the stack their callees used
 * before they return; they do not erase the registers a callee may change,
 * which a return to user mode restores or clears. The caller decides where the state lives,
 * serializes the operations on it, never copies it (a copy would make the
 * same stream twice) and passes buffers that do not overlap it. Their
 * time depends only on the lengths, never on the key or the bytes.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ERX_RNG_KEY_LENGTH	32
#define ERX_RNG_DIGEST_LENGTH	32
/* The longest read one request may make; a longer one is refused. */
#define ERX_RNG_READ_MAX	256
/* The most bytes one digest takes, one BLAKE3 chunk; more are refused. */
#define ERX_RNG_DIGEST_INPUT_MAX	1024

typedef struct erx_rng erx_rng_t;
typedef struct erx_rng_digest erx_rng_digest_t;

struct erx_rng {
	uint8_t		key[ERX_RNG_KEY_LENGTH];
	bool		ready;
};

/*
 * The BLAKE3 digest of bytes to mix, which the generator's calls take. Only a
 * hash that was not refused sets hashed, and spending the digest clears it, so
 * a refused or spent digest keys nothing.
 */
struct erx_rng_digest {
	uint8_t		bytes[ERX_RNG_DIGEST_LENGTH];
	bool		hashed;
};

void	erx_rng_clear(erx_rng_t *);
/*
 * Length bytes, none and possibly NULL when length is 0, into the digest.
 * Returns false, with the digest all zeroes and not hashed, when length is
 * over ERX_RNG_DIGEST_INPUT_MAX.
 */
bool	erx_rng_digest(erx_rng_digest_t *, const void *, size_t)
	    __attribute__((__warn_unused_result__));
/* A digest that was not hashed leaves the generator all zeroes, not ready. */
void	erx_rng_init(erx_rng_t *, erx_rng_digest_t *);
/*
 * Returns false, spending the digest all the same, unless rng is ready and the
 * digest was hashed; the state is then untouched.
 */
bool	erx_rng_mix(erx_rng_t *, erx_rng_digest_t *)
	    __attribute__((__warn_unused_result__));
/*
 * Returns false, with out and the state untouched, unless rng is ready and
 * length is at most ERX_RNG_READ_MAX; with length 0, out may be NULL and
 * only the key moves.
 */
bool	erx_rng_read(erx_rng_t *, uint8_t *, size_t)
	    __attribute__((__warn_unused_result__));

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_RNG_H */
