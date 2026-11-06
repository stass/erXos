/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_crc32c against published values, against a bitwise model of the division, and against
 * itself over every way of cutting an input in two. Prints "erx_crc32c done" and exits 0 when
 * all hold; on a failure it prints the case and exits 1.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_crc32c.h"

/* The largest call of erx_bytes_nif.c. */
#define LARGEST_CALL	65536u

/* The definition, one bit at a time: no table, and no state between bytes but the register. */
static uint32_t
bitwise_crc32c(uint32_t crc, const uint8_t *data, size_t length)
{
	uint32_t state = ~crc;
	size_t i;
	int bit;

	for (i = 0; i < length; i++) {
		state ^= data[i];
		for (bit = 0; bit < 8; bit++)
			state = (state & 1u) != 0 ? (state >> 1) ^ 0x82F63B78u : state >> 1;
	}
	return (~state);
}

static void
expect(const char *what, uint32_t got, uint32_t want)
{
	if (got != want) {
		printf("%s: got %08x, want %08x\n", what, (unsigned)got, (unsigned)want);
		exit(1);
	}
}

/* RFC 3720, appendix B.4: the CRC-32C of four 32-byte inputs. */
static void
rfc_3720_vectors(void)
{
	uint8_t buffer[32];
	size_t i;

	memset(buffer, 0, 32);
	expect("32 zero bytes", erx_crc32c(0, buffer, 32), 0x8a9136aau);
	memset(buffer, 0xff, 32);
	expect("32 bytes of 0xff", erx_crc32c(0, buffer, 32), 0x62a8ab43u);
	for (i = 0; i < 32; i++)
		buffer[i] = (uint8_t)i;
	expect("ascending 0..31", erx_crc32c(0, buffer, 32), 0x46dd794eu);
	for (i = 0; i < 32; i++)
		buffer[i] = (uint8_t)(31 - i);
	expect("descending 31..0", erx_crc32c(0, buffer, 32), 0x113fdb5cu);
}

static void
well_known_values(void)
{
	static const uint8_t digits[9] = { '1', '2', '3', '4', '5', '6', '7', '8', '9' };

	expect("123456789", erx_crc32c(0, digits, sizeof(digits)), 0xe3069283u);
	expect("empty", erx_crc32c(0, NULL, 0), 0u);
	expect("empty continues", erx_crc32c(0xe3069283u, NULL, 0), 0xe3069283u);
	expect("one zero byte", erx_crc32c(0, (const uint8_t[]){ 0 }, 1), 0x527d5351u);
}

/* Every cut of an input into two pieces gives the one-shot value, the model's value included. */
static void
cuts_and_model(void)
{
	uint8_t data[300];
	uint32_t seed = 12345u;
	size_t i, cut;
	static const uint32_t starts[] = { 0u, 1u, 0x80000000u, 0xe3069283u, 0xffffffffu };
	uint32_t whole, pieces, start;
	size_t s;

	for (i = 0; i < sizeof(data); i++) {
		seed = seed * 1664525u + 1013904223u;
		data[i] = (uint8_t)(seed >> 24);
	}
	for (s = 0; s < sizeof(starts) / sizeof(starts[0]); s++) {
		start = starts[s];
		whole = erx_crc32c(start, data, sizeof(data));
		expect("model", whole, bitwise_crc32c(start, data, sizeof(data)));
		for (cut = 0; cut <= sizeof(data); cut++) {
			pieces = erx_crc32c(erx_crc32c(start, data, cut), data + cut, sizeof(data) - cut);
			if (pieces != whole) {
				printf("cut at %zu from %08x: got %08x, want %08x\n", cut, (unsigned)start,
				    (unsigned)pieces, (unsigned)whole);
				exit(1);
			}
		}
	}
}

/* The largest call the NIF accepts, from the largest and the smallest starting value. */
static void
largest_call(void)
{
	uint8_t *data = malloc(LARGEST_CALL);
	size_t i;

	if (data == NULL)
		exit(1);
	for (i = 0; i < LARGEST_CALL; i++)
		data[i] = (uint8_t)(i * 7u + (i >> 8));
	expect("largest, from 0", erx_crc32c(0, data, LARGEST_CALL), bitwise_crc32c(0, data, LARGEST_CALL));
	expect("largest, from all ones", erx_crc32c(0xffffffffu, data, LARGEST_CALL),
	    bitwise_crc32c(0xffffffffu, data, LARGEST_CALL));
	free(data);
}

int
main(void)
{
	rfc_3720_vectors();
	well_known_values();
	cuts_and_model();
	largest_call();
	printf("erx_crc32c done\n");
	return (0);
}
