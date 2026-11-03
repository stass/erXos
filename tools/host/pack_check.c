/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * pack-check IMAGE: the boot validator over an archive, then the file check
 * of every entry, as the boot and the first slices would run them. Prints
 * "ok NENTRIES" or "error REASON ENTRY"; a refused version prints
 * "error version FOUND, expected 2 ENTRY".
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/pack.h"
#include "input.h"

int
main(int argc, char **argv)
{
	erx_pack_error_t error;
	erx_pack_scratch_t *scratch;
	erx_blake3_ctx_t hasher;
	erx_pack_view_t view;
	uint8_t *bytes;
	size_t length;
	bool accepted;

	if (argc != 2) {
		fputs("usage: pack-check IMAGE\n", stderr);
		return (2);
	}
	bytes = erx_host_input_read(argv[1], &length);
	scratch = malloc(sizeof(*scratch));
	if (bytes == NULL || scratch == NULL) {
		free(bytes);
		free(scratch);
		fputs("cannot read image within host budget\n", stderr);
		return (1);
	}
	accepted = erx_pack_open(bytes, length, scratch, &hasher, &view, &error);
	for (uint32_t index = 0; accepted && index < view.header.nentries;
	    index++)
		accepted = erx_pack_file_check(&view, index, &hasher, &error);
	if (accepted) {
		printf("ok %u\n", view.header.nentries);
	} else if (strcmp(error.reason, ERX_PACK_REASON_VERSION) == 0) {
		printf("error version %llu, expected %u %u\n",
		    (unsigned long long)error.found, (unsigned)ERX_PACK_VERSION,
		    error.entry);
	} else {
		printf("error %s %u\n", error.reason, error.entry);
	}
	free(scratch);
	free(bytes);
	return (accepted ? 0 : 1);
}
