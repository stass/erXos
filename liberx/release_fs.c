/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/release_fs.h"

static int erx_release_fs_order(const erx_release_fs_file_t *, const uint8_t *,
    size_t, bool);
static uint32_t erx_release_fs_first_at(const erx_release_fs_t *, const uint8_t *,
    size_t, bool);
static bool erx_release_fs_is_file(const erx_release_fs_t *, const uint8_t *,
    size_t, uint32_t *);
static bool erx_release_fs_below(const erx_release_fs_file_t *, const uint8_t *,
    size_t);

/* A file's path against the key `key`, or `key/` when slash is set, by bytes. */
static int
erx_release_fs_order(const erx_release_fs_file_t *file, const uint8_t *key,
    size_t length, bool slash)
{
	size_t total, common;
	uint8_t want;

	total = length + (slash ? 1 : 0);
	common = file->length < total ? file->length : total;
	for (size_t index = 0; index < common; index++) {
		want = index < length ? key[index] : '/';
		if (file->path[index] != want)
			return (file->path[index] < want ? -1 : 1);
	}
	if (file->length == total)
		return (0);
	return (file->length < total ? -1 : 1);
}

/* The first file not before the key. */
static uint32_t
erx_release_fs_first_at(const erx_release_fs_t *fs, const uint8_t *key,
    size_t length, bool slash)
{
	uint32_t low, high, middle;

	low = 0;
	high = fs->count;
	while (low < high) {
		middle = low + (high - low) / 2;
		if (erx_release_fs_order(&fs->files[middle], key, length, slash) < 0)
			low = middle + 1;
		else
			high = middle;
	}
	return (low);
}

static bool
erx_release_fs_is_file(const erx_release_fs_t *fs, const uint8_t *key,
    size_t length, uint32_t *file)
{
	uint32_t index;

	index = erx_release_fs_first_at(fs, key, length, false);
	if (index == fs->count ||
	    erx_release_fs_order(&fs->files[index], key, length, false) != 0)
		return (false);
	*file = index;
	return (true);
}

/* Whether a file lies below the directory `names`; the top holds them all. */
static bool
erx_release_fs_below(const erx_release_fs_file_t *file, const uint8_t *names,
    size_t length)
{
	if (length == 0)
		return (true);
	if (file->length <= length || file->path[length] != '/')
		return (false);
	for (size_t index = 0; index < length; index++) {
		if (file->path[index] != names[index])
			return (false);
	}
	return (true);
}

erx_release_fs_kind_t
erx_release_fs_lookup(const erx_release_fs_t *fs, const uint8_t *names,
    size_t length, uint32_t *file)
{
	uint32_t first, ignored;

	if (length == 0)
		return (ERX_RELEASE_FS_DIRECTORY);
	if (erx_release_fs_is_file(fs, names, length, file))
		return (ERX_RELEASE_FS_FILE);
	first = erx_release_fs_first_at(fs, names, length, true);
	if (first < fs->count && erx_release_fs_below(&fs->files[first], names, length))
		return (ERX_RELEASE_FS_DIRECTORY);
	for (size_t prefix = 1; prefix < length; prefix++) {
		if (names[prefix] == '/' &&
		    erx_release_fs_is_file(fs, names, prefix, &ignored))
			return (ERX_RELEASE_FS_NOT_DIRECTORY);
	}
	return (ERX_RELEASE_FS_MISSING);
}

uint32_t
erx_release_fs_list_start(const erx_release_fs_t *fs, const uint8_t *names,
    size_t length)
{
	return (erx_release_fs_first_at(fs, names, length, length > 0));
}

bool
erx_release_fs_list_next(const erx_release_fs_t *fs, const uint8_t *names,
    size_t length, uint32_t *cursor, const uint8_t **name, size_t *name_length)
{
	const erx_release_fs_file_t *file;
	size_t start, end;

	if (*cursor >= fs->count ||
	    !erx_release_fs_below(&fs->files[*cursor], names, length))
		return (false);
	file = &fs->files[*cursor];
	start = length > 0 ? length + 1 : 0;
	end = start;
	while (end < file->length && file->path[end] != '/')
		end++;
	*name = file->path + start;
	*name_length = end - start;
	(*cursor)++;
	/* The files below one subdirectory are one run, so the name comes once. */
	while (end < file->length && *cursor < fs->count &&
	    erx_release_fs_below(&fs->files[*cursor], file->path, end))
		(*cursor)++;
	return (true);
}
