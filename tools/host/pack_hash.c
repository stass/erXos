/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * pack-hash FILE RUNS: the BLAKE3 hash of byte runs of FILE. RUNS holds one
 * "OFFSET LENGTH\n" line per run, in decimal; the output is one lowercase
 * hexadecimal digest per line, in the same order. The packer runs it as a
 * subprocess for the boot image's file and index hashes, since Ruby has no
 * BLAKE3; it knows nothing of the format. The runs come in a file rather
 * than as arguments, so an archive's 65,536 entries stay below the
 * command-line limit. Every run must lie inside FILE, and every line is
 * checked before any digest is printed.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "blake3/blake3.h"
#include "input.h"

static bool erx_decimal(const uint8_t *, size_t, uint64_t *);
static bool erx_run_parse(const uint8_t *, size_t, uint64_t *, uint64_t *);

/* A decimal number without sign or leading zeros, no wider than 64 bits. */
static bool
erx_decimal(const uint8_t *text, size_t length, uint64_t *value)
{
	uint64_t result;

	if (length == 0 || (text[0] == '0' && length != 1))
		return (false);
	result = 0;
	for (size_t index = 0; index < length; index++) {
		if (text[index] < '0' || text[index] > '9' ||
		    __builtin_mul_overflow(result, (uint64_t)10, &result) ||
		    __builtin_add_overflow(result, (uint64_t)(text[index] - '0'),
		    &result))
			return (false);
	}
	*value = result;
	return (true);
}

/* "OFFSET LENGTH", one space between, the line's newline already cut. */
static bool
erx_run_parse(const uint8_t *line, size_t length, uint64_t *offset,
    uint64_t *count)
{
	size_t space;

	for (space = 0; space < length && line[space] != ' '; space++)
		;
	return (space < length &&
	    erx_decimal(line, space, offset) &&
	    erx_decimal(line + space + 1, length - space - 1, count));
}

int
main(int argc, char **argv)
{
	erx_blake3_ctx_t hasher;
	uint8_t digest[ERX_BLAKE3_OUT_LEN];
	uint64_t offset, count;
	uint8_t *bytes, *runs;
	size_t length, runs_length, cursor, line_end;
	int status;

	if (argc != 3) {
		fputs("usage: pack-hash FILE RUNS\n", stderr);
		return (2);
	}
	bytes = erx_host_input_read(argv[1], &length);
	runs = erx_host_input_read(argv[2], &runs_length);
	if (bytes == NULL || runs == NULL) {
		free(bytes);
		free(runs);
		fputs("cannot read inputs within host budget\n", stderr);
		return (1);
	}
	/* Pass 0 checks every line; pass 1 hashes and prints. */
	status = 0;
	for (int pass = 0; pass < 2 && status == 0; pass++) {
		for (cursor = 0; cursor < runs_length && status == 0;
		    cursor = line_end + 1) {
			line_end = cursor;
			while (line_end < runs_length && runs[line_end] != '\n')
				line_end++;
			if (line_end == runs_length ||
			    !erx_run_parse(runs + cursor, line_end - cursor,
			    &offset, &count) ||
			    offset > length || count > length - offset) {
				fputs("a run is malformed or outside the file\n",
				    stderr);
				status = 1;
			} else if (pass == 1) {
				erx_blake3_init(&hasher);
				erx_blake3_update(&hasher, bytes + (size_t)offset,
				    (size_t)count);
				erx_blake3_final(&hasher, digest);
				for (size_t byte = 0; byte < sizeof(digest); byte++)
					printf("%02x", digest[byte]);
				putchar('\n');
			}
		}
	}
	free(bytes);
	free(runs);
	if (status == 0 && (fflush(stdout) != 0 || ferror(stdout))) {
		fputs("cannot write digests\n", stderr);
		status = 1;
	}
	return (status);
}
