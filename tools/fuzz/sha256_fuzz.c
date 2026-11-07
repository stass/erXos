/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "sha2/sha256.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void fuzz_digest(const uint8_t *, size_t, size_t,
    uint8_t [ERX_SHA256_DIGEST_LENGTH]);
static void model_block(uint32_t [8], const uint8_t [64]);
static void model_sha256(const uint8_t *, size_t,
    uint8_t [ERX_SHA256_DIGEST_LENGTH]);

/*
 * The oracle: SHA-256 as FIPS 180-4 section 6.2 writes it, sharing no code
 * with the core. It pads by message index rather than through a buffered
 * tail, so a fault in the core's buffering or padding cannot repeat here.
 */
static const uint32_t model_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
	0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
	0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
	0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
	0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
	0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROTR(x, n)	((x) >> (n) | (x) << (32 - (n)))

/*
 * One block of the hash computation, steps 1 to 4 of section 6.2.2. v[0]
 * to v[7] are the working variables a to h; each round moves b to h down
 * one place (h = g, ..., b = a), then sets e = d + T1 and a = T1 + T2.
 */
static void
model_block(uint32_t h[8], const uint8_t block[64])
{
	uint32_t w[64], v[8], s0, s1, t1, t2;
	int t;

	for (t = 0; t < 16; t++)
		w[t] = (uint32_t)block[4 * t] << 24 | (uint32_t)block[4 * t + 1] << 16 |
		    (uint32_t)block[4 * t + 2] << 8 | (uint32_t)block[4 * t + 3];
	for (t = 16; t < 64; t++) {
		s0 = ROTR(w[t - 15], 7) ^ ROTR(w[t - 15], 18) ^ (w[t - 15] >> 3);
		s1 = ROTR(w[t - 2], 17) ^ ROTR(w[t - 2], 19) ^ (w[t - 2] >> 10);
		w[t] = s1 + w[t - 7] + s0 + w[t - 16];
	}
	memcpy(v, h, sizeof(v));
	for (t = 0; t < 64; t++) {
		t1 = v[7] + (ROTR(v[4], 6) ^ ROTR(v[4], 11) ^ ROTR(v[4], 25)) +
		    ((v[4] & v[5]) ^ (~v[4] & v[6])) + model_k[t] + w[t];
		t2 = (ROTR(v[0], 2) ^ ROTR(v[0], 13) ^ ROTR(v[0], 22)) +
		    ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
		memmove(v + 1, v, 7 * sizeof(v[0]));
		v[4] += t1;
		v[0] = t1 + t2;
	}
	for (t = 0; t < 8; t++)
		h[t] += v[t];
}

/*
 * The digest of length bytes: the padded message is the bytes, 0x80,
 * zeroes, and the length in bits as 64 big-endian bits ending a block.
 */
static void
model_sha256(const uint8_t *bytes, size_t length,
    uint8_t digest[ERX_SHA256_DIGEST_LENGTH])
{
	uint32_t h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	uint64_t bits = (uint64_t)length * 8;
	size_t blocks = (length + 1 + 8 + 63) / 64, at, b, i;
	uint8_t block[64];

	for (b = 0; b < blocks; b++) {
		for (i = 0; i < 64; i++) {
			at = b * 64 + i;
			block[i] = at < length ? bytes[at] :
			    (uint8_t)(at == length ? 0x80 : 0);
		}
		if (b == blocks - 1)
			for (i = 0; i < 8; i++)
				block[56 + i] = (uint8_t)(bits >> (56 - 8 * i));
		model_block(h, block);
	}
	for (i = 0; i < 8; i++) {
		digest[4 * i] = (uint8_t)(h[i] >> 24);
		digest[4 * i + 1] = (uint8_t)(h[i] >> 16);
		digest[4 * i + 2] = (uint8_t)(h[i] >> 8);
		digest[4 * i + 3] = (uint8_t)h[i];
	}
}

/*
 * The digest of length bytes fed in pieces of piece bytes and then of
 * every other size up to piece + 64 in turn, with an empty update between
 * pieces, so the buffered tail crosses every offset of a block. A piece
 * of 0 feeds everything at once. The context must be all zeroes once the
 * digest is out.
 */
static void
fuzz_digest(const uint8_t *bytes, size_t length, size_t piece,
    uint8_t digest[ERX_SHA256_DIGEST_LENGTH])
{
	static const erx_sha256_ctx_t erased;
	erx_sha256_ctx_t ctx;
	size_t offset, size, taken;

	erx_sha256_init(&ctx);
	if (piece == 0) {
		erx_sha256_update(&ctx, bytes, length);
	} else {
		for (offset = 0, size = piece; offset < length;
		    offset += taken, size = size % (piece + 64) + 1) {
			taken = size > length - offset ? length - offset : size;
			erx_sha256_update(&ctx, bytes + offset, taken);
			erx_sha256_update(&ctx, NULL, 0);
		}
	}
	erx_sha256_final(digest, &ctx);
	if (memcmp(&ctx, &erased, sizeof(ctx)) != 0)
		abort();
}

/*
 * The first byte chooses the piece size; the rest is the message. The
 * digest is the model's, and every way of cutting the message into pieces
 * gives it again.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t whole[ERX_SHA256_DIGEST_LENGTH], pieces[ERX_SHA256_DIGEST_LENGTH];
	uint8_t model[ERX_SHA256_DIGEST_LENGTH];

	if (size == 0)
		return (0);
	fuzz_digest(data + 1, size - 1, 0, whole);
	fuzz_digest(data + 1, size - 1, data[0], pieces);
	model_sha256(data + 1, size - 1, model);
	if (memcmp(whole, model, sizeof(whole)) != 0)
		abort();
	if (memcmp(whole, pieces, sizeof(whole)) != 0)
		abort();
	return (0);
}
