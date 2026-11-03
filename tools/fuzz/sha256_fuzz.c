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
 * The first byte chooses the piece size; the rest is the message. Every
 * way of cutting a message into pieces gives the same digest.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t whole[ERX_SHA256_DIGEST_LENGTH], pieces[ERX_SHA256_DIGEST_LENGTH];

	if (size == 0)
		return (0);
	fuzz_digest(data + 1, size - 1, 0, whole);
	fuzz_digest(data + 1, size - 1, data[0], pieces);
	if (memcmp(whole, pieces, sizeof(whole)) != 0)
		abort();
	return (0);
}
