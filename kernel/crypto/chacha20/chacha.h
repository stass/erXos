/*
 * SPDX-License-Identifier: BSD-2-Clause AND LicenseRef-DJB-public-domain
 * Modified by erXos: one stateless RFC 8439 entry point,
 * erx_chacha20_xor, in place of the context-based key, nonce and stream
 * calls; freestanding C17 includes only; the 128-bit key, the 128-bit
 * counter and the embedding variants removed.
 */
/* $OpenBSD: chacha.h,v 1.4 2016/08/27 04:04:56 guenther Exp $ */

/*
chacha-merged.c version 20080118
D. J. Bernstein
Public domain.
*/

#ifndef ERX_CRYPTO_CHACHA_H
#define ERX_CRYPTO_CHACHA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/cdefs.h"

#define ERX_CHACHA20_KEY_LENGTH		32
#define ERX_CHACHA20_NONCE_LENGTH	12
#define ERX_CHACHA20_BLOCK_LENGTH	64

/*
 * ChaCha20 as RFC 8439 defines it: a 256-bit key, a 32-bit block counter
 * and a 96-bit nonce. erx_chacha20_xor XORs length bytes of in with the
 * key stream that starts at block counter, and writes them to out; with
 * in all zeroes, out is the key stream itself. in and out are either the
 * same buffer or do not overlap; with length 0 either may be NULL.
 *
 * The counter is 32 bits and never wraps: a stream that would need a
 * block past 2^32 - 1 is refused whole, false with nothing written, so
 * no key and nonce ever produce the same block twice. The context the
 * computation keeps is erased before the call returns. The computation
 * reads bytes one at a time, so no buffer needs any alignment, and its
 * time depends only on length, never on the key, nonce or data.
 */
bool	erx_chacha20_xor(const uint8_t [static ERX_CHACHA20_KEY_LENGTH],
	    uint32_t, const uint8_t [static ERX_CHACHA20_NONCE_LENGTH],
	    const uint8_t *, uint8_t *, size_t) ERX_WARN_UNUSED_RESULT;

#endif	/* ERX_CRYPTO_CHACHA_H */
