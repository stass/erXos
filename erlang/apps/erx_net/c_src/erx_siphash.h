/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_SIPHASH_H
#define ERX_SIPHASH_H

#include <stddef.h>
#include <stdint.h>

#define ERX_SIPHASH_KEY_LENGTH	16

/*
 * SipHash-2-4 (Aumasson and Bernstein, "SipHash: a fast short-input PRF", 2012) with a 16-byte
 * key, giving the 64-bit value whose little-endian bytes are the paper's output. A hash in
 * progress: the state after the whole 8-byte words given so far, the bytes of a word not yet
 * complete, and the count of bytes given, of which only the low byte enters the hash, as the
 * paper defines. The state holds secrets derived from the key; whoever owns one erases it.
 */
typedef struct erx_siphash {
	uint64_t v[4];
	uint8_t pending[8];
	uint64_t length;
} erx_siphash_t;

/* The state of no bytes under key. */
void erx_siphash24_init(erx_siphash_t *state, const uint8_t key[ERX_SIPHASH_KEY_LENGTH]);

/* Gives length more bytes of data to state. data may be NULL when length is 0. */
void erx_siphash24_update(erx_siphash_t *state, const uint8_t *data, size_t length);

/* The hash of the bytes given to state, which is left as it was. */
uint64_t erx_siphash24_final(const erx_siphash_t *state);

/* Erases state, which holds secrets derived from its key. */
void erx_siphash24_erase(erx_siphash_t *state);

#endif
