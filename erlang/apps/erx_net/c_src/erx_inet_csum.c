/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The Internet checksum of RFC 1071 and RFC 1624's incremental update, in portable C. Words
 * are added into 64 bits and folded once at the end, which RFC 1071's "deferred carries"
 * allows: a 64-bit total holds 2^48 words before it can overflow, far beyond any input.
 * erXos's ERTS links it statically, erx_net's portable library outside erXos links it too, and
 * its unit tests and fuzz target build it for the host.
 */

#include <string.h>

#include "erx_inet_csum.h"

/*
 * erx_inet_copy_sum adds eight-byte words as the host loads them, and a sum of words in the
 * host's byte order is the byte swap of the big-endian sum on a little-endian host (RFC 1071,
 * section 2(B)).
 */
#if !defined(__BYTE_ORDER__) || \
    (__BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__ && __BYTE_ORDER__ != __ORDER_BIG_ENDIAN__)
#error "erx_inet_csum.c needs the compiler's __BYTE_ORDER__"
#endif

/* total as a 16-bit one's-complement sum: the end-around carry, until nothing is carried. */
static uint16_t
fold(uint64_t total)
{

	while (total > 0xffffu)
		total = (total & 0xffffu) + (total >> 16);
	return ((uint16_t)total);
}

/* The sum of the bytes of data taken as big-endian words from its first byte, unfolded. */
static uint64_t
add_words(const uint8_t *data, size_t length)
{
	uint64_t total = 0;
	size_t i;

	for (i = 0; i + 1 < length; i += 2)
		total += (uint64_t)data[i] << 8 | data[i + 1];
	if (i < length)
		total += (uint64_t)data[i] << 8;
	return (total);
}

/* piece's bytes swapped: its sum as seen from an offset of the other parity. */
static uint16_t
swap(uint16_t piece)
{

	return ((uint16_t)(piece << 8 | piece >> 8));
}

/*
 * A piece that starts at an odd offset has each byte in the other half of its word, and
 * RFC 1071's byte-order independence makes its sum the byte swap of the sum taken from its
 * first byte.
 */
uint16_t
erx_inet_sum(uint16_t sum, const uint8_t *data, size_t length, size_t offset)
{
	uint16_t piece;

	piece = fold(add_words(data, length));
	if (offset % 2 != 0)
		piece = swap(piece);
	return (fold((uint64_t)sum + piece));
}

/*
 * HC' = ~(~HC + ~m + m'): the words before come out as their complements, the words after go
 * in. Each word before is complemented on its own, so every addend is in 0..0xffff.
 */
uint16_t
erx_inet_csum_update(uint16_t checksum, const uint8_t *before, const uint8_t *after, size_t length)
{
	uint64_t total = (uint16_t)~checksum;
	size_t i;

	for (i = 0; i + 1 < length; i += 2) {
		total += 0xffffu ^ ((uint64_t)before[i] << 8 | before[i + 1]);
		total += (uint64_t)after[i] << 8 | after[i + 1];
	}
	return ((uint16_t)~fold(total));
}

/*
 * Eight bytes at a time: each word is loaded into a register, stored from it and added from
 * it, with the 64-bit addition's carry wrapped around, which the fold to 16 bits allows since
 * 2^64 is 1 modulo 0xffff. The words start at even offsets of the piece, so their sum in the
 * host's byte order needs one swap on a little-endian host. The last bytes, fewer than eight,
 * go a byte at a time, each loaded once as well.
 */
uint16_t
erx_inet_copy_sum(uint16_t sum, uint8_t *dst, const uint8_t *src, size_t length, size_t offset)
{
	uint64_t total = 0, tail = 0, word;
	uint16_t piece;
	uint8_t byte;
	size_t i;

	for (i = 0; length - i >= sizeof(word); i += sizeof(word)) {
		memcpy(&word, src + i, sizeof(word));
		memcpy(dst + i, &word, sizeof(word));
		total += word;
		total += total < word;
	}
	piece = fold(total);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	piece = swap(piece);
#endif
	for (; i < length; i++) {
		byte = src[i];
		dst[i] = byte;
		tail += i % 2 == 0 ? (uint64_t)byte << 8 : byte;
	}
	piece = fold(piece + tail);
	if (offset % 2 != 0)
		piece = swap(piece);
	return (fold((uint64_t)sum + piece));
}
