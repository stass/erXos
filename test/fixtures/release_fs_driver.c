/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs erx_ns_resolve and the release file system's core over commands from a
 * file, one per line, each operand in hex so a path can hold any byte:
 *
 *   F <path>            a file of the release, in sorted order
 *   M <point> <root>    a mount, kind ERX_NS_RELEASE
 *   C <cwd>             the working directory
 *   S <point> <server> <tree> <rights>
 *                       erx_ns_mount, server in decimal, rights erx_ns_rights_t's
 *                       number; answers its status
 *   B <from> <to> <ro>  erx_ns_bind, ro 1 for read-only; answers its status
 *   U <point>           erx_ns_unmount; answers its status
 *   L                   answers each entry of the table on a line:
 *                       E <point> <kind> <server> <tree> <root> <rights>
 *   N <value>           erx_ns_fid_of on a 64-bit value in decimal; answers
 *                       <1 or 0> <fid>
 *   Q <path>            answer one line:
 *                       <status> <mount or -> <nnames> <names> <path> <kind> <file> <listing>
 *
 * status is erx_ns_status_t's number, mount the table's index, kind
 * erx_release_fs_kind_t's number and listing the names joined by `,`. A refused
 * path answers its status and nothing more. An operand may be `-`, for empty.
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/ns.h"
#include "erx/release_fs.h"

#define DRIVER_FILES_MAX	256
#define DRIVER_LINE_MAX		(4 * ERX_PATH_MAX + 64)

static erx_ns_t ns;
static erx_ns_result_t out;
static erx_release_fs_file_t files[DRIVER_FILES_MAX];
static uint32_t nfiles;
static char line[DRIVER_LINE_MAX];

static size_t driver_unhex(const char *, uint8_t *, size_t);
static void driver_put_hex(const char *, size_t);
static void driver_field(const char *, char *, size_t);
static void driver_answer(const uint8_t *, size_t);

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
driver_put_hex(const char *bytes, size_t length)
{
	if (length == 0)
		fputs("-", stdout);
	for (size_t index = 0; index < length; index++)
		printf("%02x", (unsigned char)bytes[index]);
}

static void
driver_field(const char *text, char *field, size_t capacity)
{
	size_t length;

	length = driver_unhex(text, (uint8_t *)field, capacity - 1);
	field[length] = '\0';
}

static void
driver_answer(const uint8_t *path, size_t length)
{
	erx_release_fs_t fs = { .files = files, .count = nfiles };
	erx_release_fs_kind_t kind;
	erx_ns_status_t status;
	const uint8_t *name;
	size_t name_length;
	uint32_t file, cursor;
	bool first;

	status = erx_ns_resolve(&ns, path, length, &out);
	if (status != ERX_NS_OK) {
		printf("%d\n", (int)status);
		return;
	}
	printf("%d ", (int)status);
	if (out.res_mount == NULL)
		fputs("- ", stdout);
	else
		printf("%d ", (int)(out.res_mount - ns.mounts));
	printf("%u ", out.res_nnames);
	driver_put_hex(out.res_names, out.res_names_length);
	putchar(' ');
	driver_put_hex(out.res_path, out.res_path_length);
	file = UINT32_MAX;
	kind = erx_release_fs_lookup(&fs, (const uint8_t *)out.res_names, out.res_names_length, &file);
	printf(" %d %d ", (int)kind, kind == ERX_RELEASE_FS_FILE ? (int)file : -1);
	first = true;
	if (kind == ERX_RELEASE_FS_DIRECTORY) {
		cursor = erx_release_fs_list_start(&fs, (const uint8_t *)out.res_names, out.res_names_length);
		while (erx_release_fs_list_next(&fs, (const uint8_t *)out.res_names, out.res_names_length,
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
	static uint8_t path[2 * ERX_PATH_MAX];
	static uint8_t other[2 * ERX_PATH_MAX];
	static char first[DRIVER_LINE_MAX], second[DRIVER_LINE_MAX];
	static char third[DRIVER_LINE_MAX], fourth[DRIVER_LINE_MAX];
	FILE *input;
	size_t length, other_length;
	uint32_t fid;
	bool found;

	if (argc != 2 || (input = fopen(argv[1], "r")) == NULL)
		return (2);
	ns.cwd[0] = '/';
	while (fgets(line, sizeof(line), input) != NULL) {
		first[0] = second[0] = third[0] = fourth[0] = '\0';
		if (line[0] != 'L' &&
		    sscanf(line + 1, "%s %s %s %s", first, second, third, fourth) < 1)
			return (2);
		switch (line[0]) {
		case 'F':
			length = driver_unhex(first, path, sizeof(path));
			files[nfiles].path = malloc(length);
			memcpy((void *)(uintptr_t)files[nfiles].path, path, length);
			files[nfiles].length = length;
			nfiles++;
			break;
		case 'M':
			driver_field(first, ns.mounts[ns.count].point, ERX_PATH_MAX);
			driver_field(second, ns.mounts[ns.count].root, ERX_PATH_MAX);
			ns.count++;
			break;
		case 'C':
			driver_field(first, ns.cwd, ERX_PATH_MAX);
			break;
		case 'S':
			length = driver_unhex(first, path, sizeof(path));
			other_length = driver_unhex(third, other, sizeof(other));
			printf("%d\n", (int)erx_ns_mount(&ns, path, length,
			    strtoull(second, NULL, 10), other, other_length,
			    (erx_ns_rights_t)strtoul(fourth, NULL, 10)));
			break;
		case 'B':
			length = driver_unhex(first, path, sizeof(path));
			other_length = driver_unhex(second, other, sizeof(other));
			printf("%d\n", (int)erx_ns_bind(&ns, path, length, other,
			    other_length, strcmp(third, "1") == 0));
			break;
		case 'U':
			length = driver_unhex(first, path, sizeof(path));
			printf("%d\n", (int)erx_ns_unmount(&ns, path, length));
			break;
		case 'L':
			for (uint32_t index = 0; index < ns.count; index++) {
				const erx_ns_mount_t *mount = &ns.mounts[index];

				printf("E ");
				driver_put_hex(mount->point, strlen(mount->point));
				printf(" %d %llu ", (int)mount->kind,
				    (unsigned long long)mount->server);
				driver_put_hex(mount->tree, strlen(mount->tree));
				printf(" ");
				driver_put_hex(mount->root, strlen(mount->root));
				printf(" %d\n", (int)mount->rights);
			}
			break;
		case 'N':
			fid = 0;
			found = erx_ns_fid_of(strtoull(first, NULL, 10), &fid);
			printf("%d %lu\n", found ? 1 : 0, (unsigned long)fid);
			break;
		case 'Q':
			length = driver_unhex(first, path, sizeof(path));
			driver_answer(path, length);
			break;
		default:
			return (2);
		}
	}
	fclose(input);
	return (0);
}
