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
 * Mixing takes a digest, not the bytes: erx_rng_digest hashes bytes of any
 * length and touches no generator, so the caller hashes outside whatever
 * serializes the generator, which then holds for one ChaCha20 block, not
 * for a hash whose length a domain chose. A digest is spent by the call
 * that takes it, which erases it. The hash's working state, ERX_RNG_HASH_BYTES
 * bytes aligned to ERX_RNG_HASH_ALIGN, is too large for a kernel stack, so the
 * caller supplies it, in memory charged to its own caller and out of user
 * mode's reach (a page, as the boot image's hash does), overlapping neither
 * the digest nor the bytes; its contents are of no interest before the call
 * and all zeroes after it. The bytes are the caller's, and so is erasing them.
 *
 * A generator is ready only from erx_rng_init, which keys it with its
 * first seed's digest, until erx_rng_clear retires it. A retired or never
 * initialized generator (all zero bytes) refuses reads and mixes, so no
 * output ever comes from a key nobody seeded.
 *
 * The functions read and write only the state, the digest, the hash and
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
/* The memory erx_rng_digest's hash needs; rng.c holds these to the hasher's. */
#define ERX_RNG_HASH_BYTES	1912
#define ERX_RNG_HASH_ALIGN	8

typedef struct erx_rng erx_rng_t;
typedef struct erx_rng_digest erx_rng_digest_t;
/* Private to the generator: only its size and alignment are stated. */
typedef struct erx_rng_hash erx_rng_hash_t;

struct erx_rng {
	uint8_t		key[ERX_RNG_KEY_LENGTH];
	bool		ready;
};

/* The BLAKE3 digest of bytes to mix, which the generator's calls take. */
struct erx_rng_digest {
	uint8_t		bytes[ERX_RNG_DIGEST_LENGTH];
};

void	erx_rng_clear(erx_rng_t *);
/* Length bytes, none and possibly NULL when length is 0, into the digest. */
void	erx_rng_digest(erx_rng_digest_t *, erx_rng_hash_t *, const void *, size_t);
void	erx_rng_init(erx_rng_t *, erx_rng_digest_t *);
/* Returns false, spending the digest all the same, unless rng is ready. */
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
