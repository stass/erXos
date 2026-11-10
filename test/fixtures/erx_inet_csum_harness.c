/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_inet_sum and erx_inet_csum_update against RFC 1071's and RFC 1624's worked examples, a
 * real IPv4 header, a model that adds one byte at a time, and themselves over every way of
 * cutting an input in two; erx_inet_copy_sum against erx_inet_sum and the model, at every
 * alignment of its source and destination. Prints "erx_inet_csum done" and exits 0 when all hold; on a failure
 * it prints the case and exits 1.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_inet_csum.h"

/* The largest call of erx_bytes's BIFs and NIFs (ERX_BYTES_CALL_MAX, erx_iodata.h). */
#define LARGEST_CALL	65536u

/*
 * The definition, a byte at a time: a byte at an even position is the high half of its word,
 * and every addition carries end-around at once.
 */
static uint16_t
bytewise_sum(uint16_t sum, const uint8_t *data, size_t length)
{
	uint32_t total = sum;
	size_t i;

	for (i = 0; i < length; i++) {
		total += i % 2 == 0 ? (uint32_t)data[i] << 8 : data[i];
		total = (total & 0xffffu) + (total >> 16);
	}
	return ((uint16_t)total);
}

static void
expect(const char *what, unsigned got, unsigned want)
{
	if (got != want) {
		printf("%s: got %04x, want %04x\n", what, got, want);
		exit(1);
	}
}

/* RFC 1071, section 3: the sum of 00 01 f2 03 f4 f5 f6 f7, whose fold is ddf2. */
static void
rfc_1071_example(void)
{
	static const uint8_t bytes[8] = { 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };

	expect("RFC 1071 example", erx_inet_sum(0, bytes, 8, 0), 0xddf2u);
	expect("RFC 1071 example, from its middle", erx_inet_sum(erx_inet_sum(0, bytes, 3, 0),
	    bytes + 3, 5, 3), 0xddf2u);
}

/*
 * An IPv4 header whose checksum field holds b861: the header with the field zeroed sums to the
 * field's complement, and the whole header sums to ffff.
 */
static void
ipv4_header(void)
{
	uint8_t header[20] = {
		0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xb8, 0x61,
		0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7,
	};

	expect("IPv4 header verifies", erx_inet_sum(0, header, 20, 0), 0xffffu);
	header[10] = header[11] = 0;
	expect("IPv4 header's checksum", (uint16_t)~erx_inet_sum(0, header, 20, 0), 0xb861u);
}

/*
 * RFC 1624, section 4: HC 0xdd2f, m 0x5555, m' 0x3285. Equation 3 gives 0x0000, where
 * equation 2 gives 0xffff.
 */
static void
rfc_1624_example(void)
{
	static const uint8_t before[2] = { 0x55, 0x55 }, after[2] = { 0x32, 0x85 };

	expect("RFC 1624 example", erx_inet_csum_update(0xdd2fu, before, after, 2), 0x0000u);
	expect("RFC 1624 example, nothing changed", erx_inet_csum_update(0xdd2fu, before, before, 2), 0xdd2fu);
	expect("no bytes", erx_inet_csum_update(0x1234u, NULL, NULL, 0), 0x1234u);
}

static void
edges(void)
{
	static const uint8_t ones[4] = { 0xff, 0xff, 0xff, 0xff }, zeros[3] = { 0, 0, 0 };

	expect("empty", erx_inet_sum(0, NULL, 0, 0), 0u);
	expect("empty continues", erx_inet_sum(0xabcdu, NULL, 0, 1), 0xabcdu);
	expect("zeros", erx_inet_sum(0, zeros, 3, 0), 0u);
	expect("ones", erx_inet_sum(0, ones, 4, 0), 0xffffu);
	expect("ones onto ffff", erx_inet_sum(0xffffu, ones, 4, 0), 0xffffu);
	expect("one odd byte", erx_inet_sum(0, ones, 1, 0), 0xff00u);
	expect("one odd byte at an odd offset", erx_inet_sum(0, ones, 1, 1), 0x00ffu);
}

static uint32_t
next_random(uint32_t *seed)
{
	*seed = *seed * 1103515245u + 12345u;
	return (*seed >> 8);
}

/*
 * Every cut of an input into two pieces gives the model's sum; an update of every even-aligned
 * word range verifies, and equals a recomputation but where the new data is all zero.
 */
static void
cuts_updates_and_model(void)
{
	uint8_t data[301], original[301], changed[301], replacement[8];
	uint32_t seed = 4321u;
	uint16_t want, field, updated, recomputed;
	size_t length, cut, offset, span, i;
	char what[96];

	for (i = 0; i < sizeof(data); i++)
		data[i] = (uint8_t)next_random(&seed);
	for (length = 0; length <= sizeof(data); length++) {
		want = bytewise_sum(0x0102u, data, length);
		for (cut = 0; cut <= length; cut++) {
			snprintf(what, sizeof(what), "length %zu cut at %zu", length, cut);
			expect(what, erx_inet_sum(erx_inet_sum(0x0102u, data, cut, 0), data + cut,
			    length - cut, cut), want);
		}
	}
	/* Every seventh replacement is zeros, and every eleventh original too, so all-zero data occurs. */
	for (i = 0; i < 2000; i++) {
		length = 2 + 2 * (next_random(&seed) % 40);
		offset = 2 * (next_random(&seed) % (length / 2));
		span = 2 * (1 + next_random(&seed) % 4);
		if (offset + span > length)
			span = length - offset;
		if (i % 11 == 0)
			memset(original, 0, length);
		else
			memcpy(original, data, length);
		for (cut = 0; cut < span; cut++)
			replacement[cut] = i % 7 == 0 ? 0 : (uint8_t)next_random(&seed);
		field = (uint16_t)~bytewise_sum(0, original, length);
		memcpy(changed, original, length);
		memcpy(changed + offset, replacement, span);
		updated = erx_inet_csum_update(field, original + offset, replacement, span);
		recomputed = (uint16_t)~bytewise_sum(0, changed, length);
		snprintf(what, sizeof(what), "update %zu: length %zu offset %zu span %zu", i, length, offset, span);
		expect(what, updated, recomputed == 0xffffu ? 0x0000u : recomputed);
	}
}

/*
 * Every length up to 300 bytes, from every alignment of the source to every alignment of the
 * destination, at an even and an odd offset: the copy stores exactly the source's bytes, touches
 * no byte around them, and returns erx_inet_sum's sum over them, which at offset 0 is also the
 * model's.
 */
static void
copy_sums(void)
{
	uint8_t src[320], dst[336];
	uint32_t seed = 977u;
	uint16_t got;
	size_t length, from, to, offset, i;
	char what[96];

	for (i = 0; i < sizeof(src); i++)
		src[i] = (uint8_t)next_random(&seed);
	for (length = 0; length <= 300; length++)
		for (from = 0; from < 8; from++)
			for (to = 0; to < 8; to++)
				for (offset = 0; offset < 2; offset++) {
					memset(dst, 0xa5, sizeof(dst));
					got = erx_inet_copy_sum(0x0102u, dst + 8 + to, src + from, length, offset);
					snprintf(what, sizeof(what), "copy of %zu from +%zu to +%zu at offset %zu",
					    length, from, to, offset);
					expect(what, got, erx_inet_sum(0x0102u, src + from, length, offset));
					if (offset == 0)
						expect(what, got, bytewise_sum(0x0102u, src + from, length));
					if (memcmp(dst + 8 + to, src + from, length) != 0) {
						printf("%s: the bytes differ\n", what);
						exit(1);
					}
					for (i = 0; i < sizeof(dst); i++)
						if ((i < 8 + to || i >= 8 + to + length) && dst[i] != 0xa5) {
							printf("%s: byte %zu outside the copy changed\n", what, i);
							exit(1);
						}
				}
	expect("an empty copy of nothing", erx_inet_copy_sum(0x1234u, NULL, NULL, 0, 0), 0x1234u);
}

/* The largest call copied, all ff, so its 64-bit total needs more than one fold. */
static void
largest_copy(void)
{
	uint8_t *data, *copy;

	data = malloc(LARGEST_CALL + 1);
	copy = malloc(LARGEST_CALL + 1);
	if (data == NULL || copy == NULL)
		exit(1);
	memset(data, 0xff, LARGEST_CALL + 1);
	expect("a copy of 64 KiB of ff", erx_inet_copy_sum(0, copy, data, LARGEST_CALL, 0), 0xffffu);
	expect("a copy of 64 KiB and one of ff, at an odd offset",
	    erx_inet_copy_sum(0, copy, data, LARGEST_CALL + 1, 1), 0x00ffu);
	free(copy);
	free(data);
}

/* Calls of the largest size the NIF admits, and one byte more, run clean under the sanitizers. */
static void
largest_call(void)
{
	uint8_t *data;

	data = malloc(LARGEST_CALL + 1);
	if (data == NULL)
		exit(1);
	memset(data, 0xff, LARGEST_CALL + 1);
	expect("64 KiB of ff", erx_inet_sum(0, data, LARGEST_CALL, 0), 0xffffu);
	expect("64 KiB and one of ff, at an odd offset", erx_inet_sum(0, data, LARGEST_CALL + 1, 1), 0x00ffu);
	free(data);
	largest_copy();
}

int
main(void)
{

	rfc_1071_example();
	ipv4_header();
	rfc_1624_example();
	edges();
	cuts_updates_and_model();
	copy_sums();
	largest_call();
	printf("erx_inet_csum done\n");
	return (0);
}
