/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The one way to the generator's bytes, on every backend (liberx/backend/api.h).
 * erx_entropy_read leaves its bytes in the caller's UTCB mr, where the next call that
 * writes mr, or anything that reads this thread's UTCB, would find them. Taking them
 * means three steps in one place: read, move each word into the caller's buffer, and
 * zero the word in mr. The read is declared only in its private header,
 * liberx/backend/core/entropy_read.h, which this file includes and the entropy-take
 * chokepoint (tools/lib/erx/chokepoint_rules/entropy.rb) keeps from every other caller
 * but the function-API set that tests the read, so no caller can do the first step and
 * forget the last.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "erx/explicit_bzero.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/entropy_read.h"

_Static_assert(ERX_ENTROPY_BYTES_MAX <= ERX_MSG_WORDS * sizeof(uint64_t), "a read fits in mr");

/*
 * Each mr word holds the read's next eight bytes from its low byte up, so byte at of
 * the read is byte at % 8 of word at / 8, whatever the host's byte order. Each word is
 * zeroed in mr as soon as it is loaded, and the one local copy is erased before the
 * return; the refused length is checked here as well as by the read, so a backend that
 * accepted a longer read could not make this run past mr.
 */
int
erx_entropy_take(void *out, uint32_t len)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint8_t *const bytes = out;
	uint64_t word = 0;
	int status;

	if (len > ERX_ENTROPY_BYTES_MAX)
		return (ERX_EINVAL);
	status = erx_entropy_read(len);
	if (status != ERX_OK)
		return (status);
	for (uint32_t at = 0; at < len; at++) {
		if (at % sizeof(uint64_t) == 0) {
			(void)erx_utcb_mr_load(utcb, at / sizeof(uint64_t), &word);
			(void)erx_utcb_mr_store(utcb, at / sizeof(uint64_t), 0);
		}
		bytes[at] = (uint8_t)(word >> (8 * (at % sizeof(uint64_t))));
	}
	erx_explicit_bzero(&word, sizeof(word));
	return (ERX_OK);
}
