/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The C side of the differential test of test/host/erx_net_bytes_test.rb: reads cases from
 * standard input, one a line, and prints each answer in decimal on a line of its own, for the
 * test to compare with test/erlang/erx_bytes_cases.erl's answers from the Erlang models. A
 * case is words of hex, "-" for no bytes:
 *   sum START PIECE...           erx_inet_sum over the pieces in order, as the NIF sums iodata
 *   update CHECKSUM BEFORE AFTER erx_inet_csum_update
 *   sip KEY PIECE...             SipHash-2-4 of the pieces in order
 * A malformed line ends the run with status 2.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx_inet_csum.h"
#include "erx_siphash.h"

static _Noreturn void
malformed(const char *what)
{
	fprintf(stderr, "malformed case: %s\n", what);
	exit(2);
}

static int
nibble(char c)
{
	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	malformed("hex digit");
}

/* Decodes the hex word in place, returning its byte count; "-" is no bytes. */
static size_t
unhex(char *word)
{
	size_t length = strlen(word), i;

	if (strcmp(word, "-") == 0)
		return (0);
	if (length % 2 != 0)
		malformed("odd hex");
	for (i = 0; i < length / 2; i++)
		word[i] = (char)(nibble(word[2 * i]) << 4 | nibble(word[2 * i + 1]));
	return (length / 2);
}

static unsigned long
number(char *word)
{
	if (word == NULL)
		malformed("missing number");
	return (strtoul(word, NULL, 16));
}

int
main(void)
{
	char *line = NULL, *kind, *word, *before, *after;
	size_t capacity = 0, length, total, after_length;
	erx_siphash_t state;
	uint16_t sum;

	while (getline(&line, &capacity, stdin) > 0) {
		line[strcspn(line, "\n")] = '\0';
		kind = strtok(line, " ");
		if (kind == NULL)
			malformed("empty line");
		if (strcmp(kind, "sum") == 0) {
			sum = (uint16_t)number(strtok(NULL, " "));
			for (total = 0; (word = strtok(NULL, " ")) != NULL; total += length) {
				length = unhex(word);
				sum = erx_inet_sum(sum, (const uint8_t *)word, length, total);
			}
			printf("%u\n", (unsigned)sum);
		} else if (strcmp(kind, "update") == 0) {
			sum = (uint16_t)number(strtok(NULL, " "));
			before = strtok(NULL, " ");
			after = strtok(NULL, " ");
			if (before == NULL || after == NULL)
				malformed("update needs two words");
			length = unhex(before);
			after_length = unhex(after);
			if (length != after_length)
				malformed("update words differ in length");
			printf("%u\n", (unsigned)erx_inet_csum_update(sum, (const uint8_t *)before,
			    (const uint8_t *)after, length));
		} else if (strcmp(kind, "sip") == 0) {
			word = strtok(NULL, " ");
			if (word == NULL || unhex(word) != ERX_SIPHASH_KEY_LENGTH)
				malformed("key");
			erx_siphash24_init(&state, (const uint8_t *)word);
			while ((word = strtok(NULL, " ")) != NULL) {
				length = unhex(word);
				erx_siphash24_update(&state, (const uint8_t *)word, length);
			}
			printf("%llu\n", (unsigned long long)erx_siphash24_final(&state));
		} else {
			malformed(kind);
		}
	}
	free(line);
	return (0);
}
