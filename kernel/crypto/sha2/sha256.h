/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Modified by erXos: erXos names for the interface (erx_sha256_ctx_t,
 * erx_sha256_init, erx_sha256_update, erx_sha256_final and the ERX_
 * lengths); freestanding C17 includes only; libmd's symbol renames, the
 * hex-string, file and descriptor helpers and the C++ guards removed.
 */
/*-
 * Copyright 2005 Colin Percival
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#ifndef ERX_CRYPTO_SHA256_H
#define ERX_CRYPTO_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define ERX_SHA256_BLOCK_LENGTH		64
#define ERX_SHA256_DIGEST_LENGTH	32

/*
 * SHA-256 (FIPS 180-4) over a stream of bytes: erx_sha256_init starts a
 * digest, erx_sha256_update adds bytes in pieces of any size, and
 * erx_sha256_final writes the 32-byte digest and erases the context, so
 * a context holds nothing of its input once the digest is out. A
 * message is shorter than 2^61 bytes, the limit of the 64-bit bit count.
 * The computation reads its input byte by byte, so neither the input nor
 * the digest needs any alignment, and its time depends only on the
 * lengths, never on the bytes.
 */
typedef struct erx_sha256_ctx {
	uint32_t state[8];
	uint64_t count;
	uint8_t buf[ERX_SHA256_BLOCK_LENGTH];
} erx_sha256_ctx_t;

void	erx_sha256_init(erx_sha256_ctx_t *);
void	erx_sha256_update(erx_sha256_ctx_t *, const void *, size_t);
void	erx_sha256_final(uint8_t [static ERX_SHA256_DIGEST_LENGTH],
    erx_sha256_ctx_t *);

#endif /* !ERX_CRYPTO_SHA256_H */
