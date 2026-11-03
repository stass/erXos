/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/pack.h"
#include "input.h"

int
main(int argc, char **argv)
{
	erx_pack_error_t error;
	erx_pack_scratch_t *scratch;
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
	accepted = erx_pack_open(bytes, length, scratch, &view, &error);
	if (accepted) {
		printf("ok %u\n", view.header.nentries);
	} else {
		printf("error %s %u\n", error.reason, error.entry);
	}
	free(scratch);
	free(bytes);
	return (accepted ? 0 : 1);
}
