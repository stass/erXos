/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_ns_resolve and the release file system's core. The input is lines: the
 * first byte's low bits say how many of them are mount points, the next is the
 * path, and the rest are the release's file paths. Whatever the path holds, a
 * resolved result keeps design-files.md's properties; a lookup and a listing
 * agree with a plain scan of the table.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/ns.h"
#include "erx/release_fs.h"

#define FUZZ_FILES_MAX	64
#define FUZZ_LIST_MAX	(FUZZ_FILES_MAX + 1)

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static bool fuzz_next_line(const uint8_t *, size_t, size_t *, const uint8_t **, size_t *);
static bool fuzz_clean(const uint8_t *, size_t);
static int fuzz_compare(const void *, const void *);
static void fuzz_check_result(const erx_ns_t *, const erx_ns_result_t *);
static void fuzz_check_lookup(const erx_release_fs_t *, const uint8_t *, size_t);
static void fuzz_check_listing(const erx_release_fs_t *, const uint8_t *, size_t);
static bool fuzz_below(const erx_release_fs_file_t *, const uint8_t *, size_t);

static bool
fuzz_next_line(const uint8_t *bytes, size_t length, size_t *cursor,
    const uint8_t **line, size_t *line_length)
{
	size_t start;

	if (*cursor >= length)
		return (false);
	start = *cursor;
	while (*cursor < length && bytes[*cursor] != '\n')
		(*cursor)++;
	*line = bytes + start;
	*line_length = *cursor - start;
	(*cursor)++;
	return (true);
}

/* Names only: no empty name, `.`, `..` or NUL, and short enough to stay in the table. */
static bool
fuzz_clean(const uint8_t *line, size_t length)
{
	size_t start;

	if (length == 0 || length > 200)
		return (false);
	start = 0;
	for (size_t index = 0; index <= length; index++) {
		if (index < length && line[index] == '\0')
			return (false);
		if (index < length && line[index] != '/')
			continue;
		if (index == start || (index - start == 1 && line[start] == '.') ||
		    (index - start == 2 && line[start] == '.' && line[start + 1] == '.'))
			return (false);
		start = index + 1;
	}
	return (true);
}

static int
fuzz_compare(const void *left, const void *right)
{
	const erx_release_fs_file_t *a = left, *b = right;
	size_t common;
	int order;

	common = a->length < b->length ? a->length : b->length;
	order = common == 0 ? 0 : memcmp(a->path, b->path, common);
	if (order != 0)
		return (order);
	return (a->length < b->length ? -1 : a->length > b->length);
}

static void
fuzz_check_result(const erx_ns_t *ns, const erx_ns_result_t *out)
{
	static erx_ns_result_t again;
	size_t start;
	uint32_t count;

	if (out->path_length == 0 || out->path_length >= ERX_PATH_MAX ||
	    out->path[0] != '/' || strlen(out->path) != out->path_length ||
	    strlen(out->names) != out->names_length ||
	    out->nnames > ERX_NS_NAMES_MAX)
		abort();
	/* The names hold no `.`, `..`, empty or over-long name. */
	count = 0;
	start = 0;
	for (size_t index = 0; index <= out->names_length && out->names_length > 0; index++) {
		if (index < out->names_length && out->names[index] != '/')
			continue;
		if (index == start || index - start > ERX_NAME_MAX ||
		    (index - start == 1 && out->names[start] == '.') ||
		    (index - start == 2 && out->names[start] == '.' &&
		    out->names[start + 1] == '.'))
			abort();
		start = index + 1;
		count++;
	}
	if (count != out->nnames)
		abort();
	/* Resolving a normalised path again gives the same result. */
	if (erx_ns_resolve(ns, (const uint8_t *)out->path, out->path_length, &again) !=
	    ERX_NS_OK || again.mount != out->mount ||
	    again.path_length != out->path_length ||
	    strcmp(again.path, out->path) != 0 || strcmp(again.names, out->names) != 0)
		abort();
}

static bool
fuzz_below(const erx_release_fs_file_t *file, const uint8_t *names, size_t length)
{
	if (length == 0)
		return (true);
	return (file->length > length && file->path[length] == '/' &&
	    memcmp(file->path, names, length) == 0);
}

static void
fuzz_check_lookup(const erx_release_fs_t *fs, const uint8_t *names, size_t length)
{
	erx_release_fs_kind_t want, got;
	uint32_t file, want_file;

	want = length == 0 ? ERX_RELEASE_FS_DIRECTORY : ERX_RELEASE_FS_MISSING;
	want_file = UINT32_MAX;
	for (uint32_t index = 0; index < fs->count && length > 0; index++) {
		const erx_release_fs_file_t *entry = &fs->files[index];

		if (entry->length == length && memcmp(entry->path, names, length) == 0) {
			want = ERX_RELEASE_FS_FILE;
			want_file = index;
		} else if (fuzz_below(entry, names, length)) {
			want = ERX_RELEASE_FS_DIRECTORY;
		} else if (entry->length < length && names[entry->length] == '/' &&
		    memcmp(entry->path, names, entry->length) == 0) {
			want = ERX_RELEASE_FS_NOT_DIRECTORY;
		}
	}
	got = erx_release_fs_lookup(fs, names, length, &file);
	if (got != want || (got == ERX_RELEASE_FS_FILE && file != want_file))
		abort();
}

static void
fuzz_check_listing(const erx_release_fs_t *fs, const uint8_t *names, size_t length)
{
	const uint8_t *seen[FUZZ_LIST_MAX], *name;
	size_t seen_length[FUZZ_LIST_MAX], name_length;
	uint32_t cursor, count, below;

	count = 0;
	cursor = erx_release_fs_list_start(fs, names, length);
	while (erx_release_fs_list_next(fs, names, length, &cursor, &name, &name_length)) {
		if (count == FUZZ_LIST_MAX || name_length == 0)
			abort();
		for (uint32_t index = 0; index < count; index++) {
			if (seen_length[index] == name_length &&
			    memcmp(seen[index], name, name_length) == 0)
				abort();
		}
		seen[count] = name;
		seen_length[count] = name_length;
		count++;
	}
	below = 0;
	for (uint32_t index = 0; index < fs->count; index++) {
		if (fuzz_below(&fs->files[index], names, length))
			below++;
	}
	/* Every file below is under a listed name, and a listed name has a file. */
	if ((below == 0) != (count == 0) || count > below)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	static erx_ns_t ns;
	static erx_ns_result_t out;
	static erx_release_fs_file_t files[FUZZ_FILES_MAX], kept[FUZZ_FILES_MAX];
	erx_release_fs_t fs;
	const uint8_t *line;
	size_t cursor, line_length;
	uint32_t mounts, count, nkept;

	if (length == 0)
		return (0);
	cursor = 1;
	mounts = bytes[0] & 3;
	ns.count = 0;
	strcpy(ns.cwd, "/");
	if ((bytes[0] & 4) != 0) {
		ns.count = 1;
		strcpy(ns.mounts[0].point, "/");
		strcpy(ns.mounts[0].root, "/");
	}
	for (uint32_t index = 0; index < mounts &&
	    fuzz_next_line(bytes, length, &cursor, &line, &line_length); index++) {
		erx_ns_mount_t *mount = &ns.mounts[ns.count];

		if (line_length < 2 || line[0] != '/' ||
		    !fuzz_clean(line + 1, line_length - 1))
			continue;
		memcpy(mount->point, line, line_length);
		mount->point[line_length] = '\0';
		strcpy(mount->root, (bytes[0] & 8) != 0 ? "/under" : "/");
		ns.count++;
	}
	if (!fuzz_next_line(bytes, length, &cursor, &line, &line_length))
		return (0);
	if (erx_ns_resolve(&ns, line, line_length, &out) == ERX_NS_OK)
		fuzz_check_result(&ns, &out);
	else if (out.mount != NULL || out.nnames != 0 || out.names_length != 0 ||
	    out.path_length != 0)
		abort();

	count = 0;
	{
		const uint8_t *row;
		size_t row_length;

		while (count < FUZZ_FILES_MAX &&
		    fuzz_next_line(bytes, length, &cursor, &row, &row_length)) {
			if (fuzz_clean(row, row_length))
				files[count++] = (erx_release_fs_file_t){ .path = row,
				    .length = row_length, .size = row_length };
		}
	}
	qsort(files, count, sizeof(files[0]), fuzz_compare);
	/* What the archive's checks leave: unique, and no file a prefix of another. */
	nkept = 0;
	for (uint32_t index = 0; index < count; index++) {
		bool conflict = false;

		for (uint32_t other = 0; other < nkept && !conflict; other++) {
			conflict = fuzz_compare(&kept[other], &files[index]) == 0 ||
			    fuzz_below(&files[index], kept[other].path, kept[other].length) ||
			    fuzz_below(&kept[other], files[index].path, files[index].length);
		}
		if (!conflict)
			kept[nkept++] = files[index];
	}
	fs = (erx_release_fs_t){ .files = kept, .count = nkept };
	if (out.path_length > 0) {
		fuzz_check_lookup(&fs, (const uint8_t *)out.names, out.names_length);
		fuzz_check_listing(&fs, (const uint8_t *)out.names, out.names_length);
	}
	for (uint32_t index = 0; index < nkept; index++) {
		fuzz_check_lookup(&fs, kept[index].path, kept[index].length);
		for (size_t prefix = 1; prefix < kept[index].length; prefix++) {
			if (kept[index].path[prefix] == '/') {
				fuzz_check_lookup(&fs, kept[index].path, prefix);
				fuzz_check_listing(&fs, kept[index].path, prefix);
			}
		}
	}
	fuzz_check_listing(&fs, (const uint8_t *)"", 0);
	return (0);
}
