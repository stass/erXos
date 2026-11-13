/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Binds an archive from a file and prints what erx_release_entry answers, one
 * entry a line: <path> <size> <offset> <kind>, then the status past the run. A refused
 * archive prints `refused <check>`.
 */

#include <stdio.h>
#include <stdlib.h>

#include "erx/release.h"

int
main(int argc, char **argv)
{
	static erx_release_entry_t entry;
	const char *reason;
	uint8_t *bytes;
	long length;
	FILE *input;
	uint64_t index;
	int status;

	if (argc != 2 || (input = fopen(argv[1], "rb")) == NULL ||
	    fseek(input, 0, SEEK_END) != 0 || (length = ftell(input)) <= 0 ||
	    fseek(input, 0, SEEK_SET) != 0 || (bytes = malloc((size_t)length)) == NULL ||
	    fread(bytes, 1, (size_t)length, input) != (size_t)length)
		return (2);
	fclose(input);
	reason = "none";
	if (erx_release_bind(bytes, (size_t)length, &reason) != 0) {
		printf("refused %s\n", reason);
		free(bytes);
		return (0);
	}
	for (index = 0; (status = erx_release_entry(index, &entry)) == 0; index++) {
		printf("%.*s %llu %llu %s\n", (int)entry.path_length, (const char *)entry.path,
		    (unsigned long long)entry.size, (unsigned long long)entry.offset,
		    entry.kind == ERX_ENTRY_DIRECTORY ? "directory" :
		    entry.kind == ERX_ENTRY_IMAGE ? "image" : "file");
	}
	printf("past %d\n", status == ERX_ERANGE ? 1 : 0);
	printf("addr %d\n", erx_release_addr() == bytes ? 1 : 0);
	free(bytes);
	return (0);
}
