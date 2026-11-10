/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_INET_CSUM_H
#define ERX_INET_CSUM_H

#include <stddef.h>
#include <stdint.h>

/*
 * The Internet checksum of RFC 1071: the one's-complement sum of the covered bytes taken as
 * 16-bit big-endian words, a last odd byte padded with a zero byte on the right. A packet's
 * checksum field holds the complement of that sum, so the sum of a whole packet, field
 * included, is 0xffff when the field is right.
 *
 * A sum here is folded to 16 bits: 0..0xffff, with 0 only for bytes that are all zero.
 */

/*
 * The sum of the offset bytes before data, sum, continued over length bytes of data. Only
 * offset's parity matters: when it is odd, data's first byte is the low half of a word. So
 * the pieces of an input summed one after the other give the one-shot sum:
 * erx_inet_sum(erx_inet_sum(s, a, na, 0), b, nb, na) is erx_inet_sum(s, a b, na + nb, 0).
 * data may be NULL when length is 0.
 */
uint16_t erx_inet_sum(uint16_t sum, const uint8_t *data, size_t length, size_t offset);

/*
 * RFC 1624's incremental update, its equation 3: the checksum field that replaces checksum
 * when the length bytes before, at an even offset of the covered bytes, become the length bytes
 * after; length is even. When checksum was right, it is the field a full recomputation gives,
 * except that for length > 0 it is 0x0000 where that is 0xffff, the other zero of
 * one's-complement arithmetic, which a full recomputation gives only when every covered byte
 * is zero. A wrong checksum stays wrong by the same amount, as RFC 1624 intends. UDP, where a
 * field of 0 means no checksum, sends a computed 0 as 0xffff (RFC 768); that is its caller's
 * rule, applied to this result as to a full recomputation.
 */
uint16_t erx_inet_csum_update(uint16_t checksum, const uint8_t *before, const uint8_t *after,
    size_t length);

/*
 * Copies length bytes from src to dst and returns sum continued over the bytes stored, as
 * erx_inet_sum(sum, dst, length, offset) would return after the copy. Each word of src is
 * loaded into a local, and that value is both stored and added, so the sum is that of the
 * bytes dst holds even when src changes during the copy, as a device's buffer may. C does not
 * forbid a compiler to load src again for one of the two uses: that each word is read once
 * rests on code generation (TODO.md). src and dst need no alignment and must not overlap;
 * either may be NULL when length is 0.
 */
uint16_t erx_inet_copy_sum(uint16_t sum, uint8_t *dst, const uint8_t *src, size_t length,
    size_t offset);

#endif
