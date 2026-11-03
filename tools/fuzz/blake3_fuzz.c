/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * libFuzzer entry for the imported BLAKE3. The first input byte chooses
 * how the rest, the message, is cut into updates; the digest of the cut
 * message must equal the digest of one update of it all, and final must
 * leave each context erased. Under ASan and UBSan every update and every
 * final also has its memory accesses and arithmetic checked.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

/* Aborts unless final left all of ctx zero. */
static void
require_erased(const erx_blake3_ctx_t *ctx)
{
	const uint8_t *bytes = (const uint8_t *)ctx;

	for (size_t index = 0; index < sizeof(*ctx); index++)
		if (bytes[index] != 0)
			abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_blake3_ctx_t whole, cut;
	uint8_t expected[ERX_BLAKE3_OUT_LEN], got[ERX_BLAKE3_OUT_LEN];
	const uint8_t *message;
	size_t length, offset = 0;
	uint32_t state;

	if (size == 0)
		return (0);
	/* The cut's seed; the pieces then run from 0 to 2111 bytes. */
	state = data[0];
	message = data + 1;
	length = size - 1;

	erx_blake3_init(&whole);
	erx_blake3_update(&whole, message, length);
	erx_blake3_final(&whole, expected);
	require_erased(&whole);

	erx_blake3_init(&cut);
	while (offset < length) {
		size_t piece;

		state = state * 1103515245u + 12345u;
		piece = (size_t)(state >> 16) % 2112;
		if (piece > length - offset)
			piece = length - offset;
		erx_blake3_update(&cut, message + offset, piece);
		offset += piece;
	}
	erx_blake3_update(&cut, NULL, 0);
	erx_blake3_final(&cut, got);
	require_erased(&cut);
	if (memcmp(expected, got, sizeof(got)) != 0)
		abort();
	return (0);
}
