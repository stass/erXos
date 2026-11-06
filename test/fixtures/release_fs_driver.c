/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs the release file system's core over commands from a file, one per
 * line, each operand in hex so a name can hold any byte:
 *
 *   F <path>   a file of the release, in sorted order
 *   R          empties the name list
 *   A <name>   erx_release_fs_add_name on the list; answers 1 or 0
 *   Q          answers one line for the list:
 *              <count> <names> <passed> <stop> <kind> <file> <listing>
 *   N <value>  erx_fid_of on a 64-bit value in decimal, not hex; answers
 *              <1 or 0> <fid>
 *
 * names is the list's bytes, passed and stop erx_release_fs_walk's answer,
 * kind erx_release_fs_lookup's of the whole list as erx_release_fs_kind_t's
 * number, file the file's index or -1, and listing the directory's names
 * joined by `,`. An operand may be `-`, for empty.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/release_fs.h"
#include "erx_fid.h"

#define DRIVER_FILES_MAX	256
#define DRIVER_LINE_MAX		(4 * ERX_PATH_MAX + 64)

static erx_release_fs_file_t files[DRIVER_FILES_MAX];
static uint32_t nfiles;
static erx_release_fs_names_t names;
static char line[DRIVER_LINE_MAX];

static size_t driver_unhex(const char *, uint8_t *, size_t);
static void driver_put_hex(const uint8_t *, size_t);
static void driver_answer(void);

static size_t
driver_unhex(const char *text, uint8_t *bytes, size_t capacity)
{
	size_t length;
	unsigned int value;

	if (strcmp(text, "-") == 0)
		return (0);
	length = 0;
	while (sscanf(text, "%2x", &value) == 1) {
		if (length == capacity)
			abort();
		bytes[length++] = (uint8_t)value;
		text += 2;
	}
	return (length);
}

static void
driver_put_hex(const uint8_t *bytes, size_t length)
{
	if (length == 0)
		fputs("-", stdout);
	for (size_t index = 0; index < length; index++)
		printf("%02x", bytes[index]);
}

static void
driver_answer(void)
{
	erx_release_fs_t fs = { .files = files, .count = nfiles };
	erx_release_fs_kind_t kind, stop;
	const uint8_t *name;
	size_t name_length;
	uint32_t passed, file, cursor;
	bool first;

	printf("%u ", names.count);
	driver_put_hex(names.bytes, names.length);
	passed = erx_release_fs_walk(&fs, &names, &stop);
	file = UINT32_MAX;
	kind = erx_release_fs_lookup(&fs, names.bytes, names.length, &file);
	printf(" %u %d %d %d ", passed, (int)stop, (int)kind,
	    kind == ERX_RELEASE_FS_FILE ? (int)file : -1);
	first = true;
	if (kind == ERX_RELEASE_FS_DIRECTORY) {
		cursor = erx_release_fs_list_start(&fs, names.bytes, names.length);
		while (erx_release_fs_list_next(&fs, names.bytes, names.length,
		    &cursor, &name, &name_length)) {
			if (!first)
				putchar(',');
			first = false;
			fwrite(name, 1, name_length, stdout);
		}
	}
	if (first)
		putchar('-');
	putchar('\n');
}

int
main(int argc, char **argv)
{
	static uint8_t bytes[2 * ERX_PATH_MAX];
	static char operand[DRIVER_LINE_MAX];
	FILE *input;
	size_t length;
	uint32_t fid;
	bool found;

	if (argc != 2 || (input = fopen(argv[1], "r")) == NULL)
		return (2);
	while (fgets(line, sizeof(line), input) != NULL) {
		operand[0] = '\0';
		if ((line[0] == 'F' || line[0] == 'A') &&
		    sscanf(line + 1, "%s", operand) != 1)
			return (2);
		switch (line[0]) {
		case 'F':
			if (nfiles == DRIVER_FILES_MAX)
				return (2);
			length = driver_unhex(operand, bytes, sizeof(bytes));
			files[nfiles].path = malloc(length == 0 ? 1 : length);
			if (files[nfiles].path == NULL)
				return (2);
			memcpy((void *)(uintptr_t)files[nfiles].path, bytes, length);
			files[nfiles].length = length;
			nfiles++;
			break;
		case 'R':
			names.count = 0;
			names.length = 0;
			break;
		case 'A':
			length = driver_unhex(operand, bytes, sizeof(bytes));
			printf("%d\n", erx_release_fs_add_name(&names, bytes, length) ? 1 : 0);
			break;
		case 'Q':
			driver_answer();
			break;
		case 'N':
			fid = 0;
			found = erx_fid_of(strtoull(line + 1, NULL, 10), &fid);
			printf("%d %lu\n", found ? 1 : 0, (unsigned long)fid);
			break;
		default:
			return (2);
		}
	}
	fclose(input);
	return (0);
}
