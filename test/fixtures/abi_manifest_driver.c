/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdio.h>
#include <stdlib.h>

#include "erx/abi_reader.h"

int
main(int argc, char **argv)
{
	erx_manifest_view_t view;
	erx_abi_error_t error = {0};
	uint8_t *bytes;
	FILE *input;
	size_t length;
	int result, extra;
	bool accepted;

	if (argc != 2)
		return (2);
	input = fopen(argv[1], "rb");
	if (input == NULL)
		return (2);
	bytes = malloc(ERX_MANIFEST_BYTES_MAX);
	if (bytes == NULL) {
		fclose(input);
		return (2);
	}
	length = fread(bytes, 1, ERX_MANIFEST_BYTES_MAX, input);
	extra = fgetc(input);
	if (ferror(input) != 0 || extra != EOF) {
		free(bytes);
		fclose(input);
		return (2);
	}
	fclose(input);
	accepted = erx_manifest_open(bytes, length, &view, &error);
	if (accepted) {
		printf("ok %u %u\n", view.header.principals.count,
		    view.header.partial_boot.count);
		result = 0;
	} else {
		printf("error %s %s %zu\n", error.reason, error.field, error.offset);
		result = 1;
	}
	free(bytes);
	return (result);
}
