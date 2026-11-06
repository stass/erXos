/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The C reader's verdicts on a corpus of system manifests, for the differential fuzz
 * target of the Erlang reader (tools/fuzz/erx_manifest.rb). The corpus file holds
 * records of a 32-bit big-endian length and that many bytes. For each record this
 * prints one line, "ok" when erx_manifest_open accepts it and "error REASON FIELD"
 * when it refuses it, and runs manifest_fuzz.c's walk of every table row over it,
 * which aborts if an accepted manifest has a row the reader refuses.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/abi_reader.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* The most bytes one record may hold: the pack fuzz targets' input bound. */
#define RECORD_MAX	32768

int
main(int argc, char **argv)
{
	uint8_t *record;
	uint8_t length_bytes[4];
	erx_manifest_view_t view;
	erx_abi_error_t error;
	FILE *corpus;
	size_t length;

	if (argc != 2 || (corpus = fopen(argv[1], "rb")) == NULL) {
		fprintf(stderr, "usage: manifest_verdicts CORPUS\n");
		return (2);
	}
	while (fread(length_bytes, 1, sizeof(length_bytes), corpus) == sizeof(length_bytes)) {
		length = (size_t)length_bytes[0] << 24 | (size_t)length_bytes[1] << 16 |
		    (size_t)length_bytes[2] << 8 | (size_t)length_bytes[3];
		/*
		 * Each record in an allocation of exactly its size, so that
		 * AddressSanitizer catches a read past its end.
		 */
		if (length > RECORD_MAX ||
		    ((record = malloc(length)) == NULL && length > 0) ||
		    fread(record, 1, length, corpus) != length) {
			fprintf(stderr, "manifest_verdicts: malformed corpus record\n");
			return (2);
		}
		error = (erx_abi_error_t){ 0 };
		if (erx_manifest_open(record, length, &view, &error))
			printf("ok\n");
		else if (error.reason == NULL || error.field == NULL)
			abort();
		else
			printf("error %s %s\n", error.reason, error.field);
		(void)LLVMFuzzerTestOneInput(record, length);
		free(record);
	}
	if (ferror(corpus) || !feof(corpus)) {
		fprintf(stderr, "manifest_verdicts: corpus read failed\n");
		return (2);
	}
	(void)fclose(corpus);
	return (0);
}
