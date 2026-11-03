/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs the imported BLAKE3 over the requests in a text file, one per
 * line, and prints one answer line per request, so the host test can
 * judge it against the official vectors and b3sum.
 *
 *   hash HEX PIECES  (the message in hexadecimal, "-" for the empty one;
 *                     PIECES the lengths of the updates that feed it,
 *                     comma-separated, "-" for one update of it all)
 *     -> hash DIGEST ERASED   (ERASED is 1 when final left every byte of
 *                              the context zero)
 *   size             -> size BYTES   (sizeof(erx_blake3_ctx_t))
 */

/* getline, strtok_r and ssize_t under -std=c17. */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"

static void
fail(const char *what)
{

	fprintf(stderr, "blake3_driver: %s\n", what);
	exit(2);
}

static int
nibble(char c)
{

	if (c >= '0' && c <= '9')
		return (c - '0');
	if (c >= 'a' && c <= 'f')
		return (c - 'a' + 10);
	fail("bad hex digit");
	return (-1);
}

/* Decodes text, which is "-" or an even run of hex digits, into a fresh buffer. */
static uint8_t *
unhex(const char *text, size_t *length)
{
	size_t digits;
	uint8_t *bytes;

	if (strcmp(text, "-") == 0) {
		*length = 0;
		return (NULL);
	}
	digits = strlen(text);
	if (digits % 2 != 0)
		fail("odd hex length");
	*length = digits / 2;
	bytes = malloc(*length);
	if (bytes == NULL)
		fail("out of memory");
	for (size_t index = 0; index < *length; index++)
		bytes[index] = (uint8_t)(nibble(text[2 * index]) << 4 |
		    nibble(text[2 * index + 1]));
	return (bytes);
}

/*
 * Feeds message to ctx in the pieces listed, then whatever the list
 * leaves over in one last update. Every piece must fit what remains.
 */
static void
feed(erx_blake3_ctx_t *ctx, const uint8_t *message, size_t length,
    char *pieces)
{
	size_t offset = 0;
	char *cursor = pieces;

	if (strcmp(pieces, "-") != 0) {
		while (*cursor != '\0') {
			char *end;
			unsigned long long piece;

			errno = 0;
			piece = strtoull(cursor, &end, 10);
			if (errno != 0 || end == cursor ||
			    (*end != ',' && *end != '\0'))
				fail("bad piece list");
			if (piece > length - offset)
				fail("piece past the message");
			erx_blake3_update(ctx, message == NULL ? NULL :
			    message + offset, (size_t)piece);
			offset += (size_t)piece;
			cursor = *end == ',' ? end + 1 : end;
		}
	}
	erx_blake3_update(ctx, message == NULL ? NULL : message + offset,
	    length - offset);
}

static void
hash(char *text, char *pieces)
{
	erx_blake3_ctx_t ctx;
	uint8_t digest[ERX_BLAKE3_OUT_LEN];
	const uint8_t *view;
	uint8_t *message;
	size_t length;
	int erased = 1;

	message = unhex(text, &length);
	erx_blake3_init(&ctx);
	feed(&ctx, message, length, pieces);
	erx_blake3_final(&ctx, digest);
	view = (const uint8_t *)&ctx;
	for (size_t index = 0; index < sizeof(ctx); index++)
		if (view[index] != 0)
			erased = 0;
	printf("hash ");
	for (size_t index = 0; index < sizeof(digest); index++)
		printf("%02x", digest[index]);
	printf(" %d\n", erased);
	free(message);
}

int
main(int argc, char **argv)
{
	FILE *input;
	char *line = NULL;
	size_t capacity = 0;
	ssize_t got;

	if (argc != 2)
		fail("usage: blake3_driver REQUESTS");
	input = fopen(argv[1], "r");
	if (input == NULL)
		fail("cannot open the requests");
	while ((got = getline(&line, &capacity, input)) > 0) {
		char *verb, *text, *pieces, *rest;

		if (line[got - 1] == '\n')
			line[got - 1] = '\0';
		verb = strtok_r(line, " ", &rest);
		if (verb != NULL && strcmp(verb, "size") == 0) {
			printf("size %zu\n", sizeof(erx_blake3_ctx_t));
			continue;
		}
		if (verb == NULL || strcmp(verb, "hash") != 0)
			fail("unknown request");
		text = strtok_r(NULL, " ", &rest);
		pieces = strtok_r(NULL, " ", &rest);
		if (text == NULL || pieces == NULL ||
		    strtok_r(NULL, " ", &rest) != NULL)
			fail("bad hash request");
		hash(text, pieces);
	}
	free(line);
	fclose(input);
	return (0);
}
