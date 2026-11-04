/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/rng.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/entropy.h"
#include "liberx/backend/fiasco/log.h"

/*
 * The counter is all this generator starts from: Fiasco gives the root no device tree
 * and neither accelerator has the random-number instruction, so anyone who can guess the
 * boot's timing can guess every byte. The line below says so, whatever a caller does.
 */
#define ENTROPY_QUALITY_LINE	"erx: entropy: quality: low, from the counter alone\n"

static erx_rng_t generator;

void
erx_fiasco_entropy_init(void)
{
	const uint64_t counter = erx_fiasco_counter();
	erx_rng_digest_t digest;

	if (erx_rng_digest(&digest, &counter, sizeof(counter)))
		erx_rng_init(&generator, &digest);
	erx_fiasco_console_write(ENTROPY_QUALITY_LINE, sizeof(ENTROPY_QUALITY_LINE) - 1);
}

int
erx_fiasco_entropy_read_body(uint64_t *first, uint64_t *second)
{
	uint64_t words[2];

	if (!erx_rng_read(&generator, (uint8_t *)words, sizeof(words)))
		return (ERX_ENOTSUP);
	*first = words[0];
	*second = words[1];
	return (ERX_OK);
}

int
erx_fiasco_entropy_add_body(const erx_fiasco_entropy_add_request_t *request)
{
	const uint64_t words[] = { request->word0, request->word1, request->word2, request->word3 };
	erx_rng_digest_t digest;

	if (request->len > sizeof(words))
		return (ERX_EINVAL);
	if (!erx_rng_digest(&digest, words, (size_t)request->len) || !erx_rng_mix(&generator, &digest))
		return (ERX_ENOTSUP);
	return (ERX_OK);
}
