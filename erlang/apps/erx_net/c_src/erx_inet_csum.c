/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The Internet checksum of RFC 1071 and RFC 1624's incremental update, in portable C. Words
 * are added into 64 bits and folded once at the end, which RFC 1071's "deferred carries"
 * allows. erXos's ERTS links it statically, erx_net's portable library outside erXos links it
 * too, and its unit tests and fuzz target build it for the host.
 */

#include <string.h>

#include "erx_inet_csum.h"

/*
 * The sums add eight-byte words as the host loads them, and a sum of words in the host's byte
 * order is the byte swap of the big-endian sum on a little-endian host (RFC 1071, section
 * 2(B)).
 */
#if !defined(__BYTE_ORDER__) || \
    (__BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__ && __BYTE_ORDER__ != __ORDER_BIG_ENDIAN__)
#error "erx_inet_csum.c needs the compiler's __BYTE_ORDER__"
#endif

/*
 * value, just loaded, becomes a register whose contents the compiler cannot know, so every use
 * after this reads that register and none loads the source again. C allows a compiler to load
 * a plain object a second time for a second use; a copy from memory a device can write needs
 * the value it stores to be the value it adds. The empty assembly, a GNU C extension that
 * clang and GCC take, emits no instruction. A device writing the source during the copy is
 * still a data race in ISO C's terms; what this guarantees is only that the bytes stored are
 * the bytes summed. The sum without a copy shares the loop and so the statement, which costs
 * it no measurable time on the development host. No test can see a second load, so review
 * keeps every load of the loop behind it.
 */
#define LOADED_ONCE(value)	__asm__("" : "+r"(value))

/* total as a 16-bit one's-complement sum: the end-around carry, until nothing is carried. */
static uint16_t
fold(uint64_t total)
{

	while (total > 0xffffu)
		total = (total & 0xffffu) + (total >> 16);
	return ((uint16_t)total);
}

/* piece's bytes swapped: its sum as seen from an offset of the other parity. */
static uint16_t
swap(uint16_t piece)
{

	return ((uint16_t)(piece << 8 | piece >> 8));
}

/* total + word, with the 64-bit addition's carry wrapped around into its low bit. */
static inline uint64_t
add_carried(uint64_t total, uint64_t word)
{

	total += word;
	return (total + (total < word));
}

/*
 * Copies the length bytes of src to dst, or only reads them when dst is NULL, and returns their
 * folded sum taken as big-endian words from src's first byte, each byte loaded once and the
 * value loaded both stored and added. Eight bytes at a time, with each 64-bit addition's carry wrapped around,
 * which the fold to 16 bits allows since 2^64 is 1 modulo 0xffff. Two words a step go into
 * two totals, so neither addition waits for the other's carry. The words start at even
 * offsets, so their sum in the host's byte order needs one swap on a little-endian host, made
 * before the last bytes, fewer than eight, are added a byte at a time, each already weighted
 * as the high or low half of its big-endian word.
 */
static inline uint16_t
copy_and_sum(uint8_t *dst, const uint8_t *src, size_t length)
{
	uint64_t total = 0, second = 0, tail = 0, word, next;
	uint16_t piece;
	uint8_t byte;
	size_t i;

	for (i = 0; length - i >= 2 * sizeof(word); i += 2 * sizeof(word)) {
		memcpy(&word, src + i, sizeof(word));
		memcpy(&next, src + i + sizeof(word), sizeof(next));
		LOADED_ONCE(word);
		LOADED_ONCE(next);
		if (dst != NULL) {
			memcpy(dst + i, &word, sizeof(word));
			memcpy(dst + i + sizeof(word), &next, sizeof(next));
		}
		total = add_carried(total, word);
		second = add_carried(second, next);
	}
	if (length - i >= sizeof(word)) {
		memcpy(&word, src + i, sizeof(word));
		LOADED_ONCE(word);
		if (dst != NULL)
			memcpy(dst + i, &word, sizeof(word));
		total = add_carried(total, word);
		i += sizeof(word);
	}
	piece = fold(add_carried(total, second));
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	piece = swap(piece);
#endif
	for (; i < length; i++) {
		byte = src[i];
		LOADED_ONCE(byte);
		if (dst != NULL)
			dst[i] = byte;
		tail += i % 2 == 0 ? (uint64_t)byte << 8 : byte;
	}
	return (fold(piece + tail));
}

/*
 * sum plus piece, a piece's sum taken from its first byte, where the piece starts offset bytes
 * into the whole. A piece that starts at an odd offset has each byte in the other half of its
 * word, and RFC 1071's byte-order independence makes its sum the byte swap of the sum taken
 * from its first byte.
 */
static uint16_t
add_at(uint16_t sum, uint16_t piece, size_t offset)
{

	if (offset % 2 != 0)
		piece = swap(piece);
	return (fold((uint64_t)sum + piece));
}

uint16_t
erx_inet_sum(uint16_t sum, const uint8_t *data, size_t length, size_t offset)
{

	return (add_at(sum, copy_and_sum(NULL, data, length), offset));
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

uint16_t
erx_inet_copy_sum(uint16_t sum, uint8_t *dst, const uint8_t *src, size_t length, size_t offset)
{

	return (add_at(sum, copy_and_sum(dst, src, length), offset));
}
