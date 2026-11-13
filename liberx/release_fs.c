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
static bool erx_release_fs_find(const erx_release_fs_t *, const uint8_t *,
    size_t, uint32_t *);
static bool erx_release_fs_below(const erx_release_fs_file_t *, const uint8_t *,
    size_t);
static bool erx_release_fs_utf8_valid(const uint8_t *, size_t);

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

/* Whether an entry, a file or an empty directory, has exactly the path key. */
static bool
erx_release_fs_find(const erx_release_fs_t *fs, const uint8_t *key,
    size_t length, uint32_t *entry)
{
	uint32_t index;

	index = erx_release_fs_first_at(fs, key, length, false);
	if (index == fs->count ||
	    erx_release_fs_order(&fs->files[index], key, length, false) != 0)
		return (false);
	*entry = index;
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
	uint32_t first, found;

	if (length == 0)
		return (ERX_RELEASE_FS_DIRECTORY);
	if (erx_release_fs_find(fs, names, length, &found)) {
		if (fs->files[found].directory)
			return (ERX_RELEASE_FS_DIRECTORY);
		*file = found;
		return (ERX_RELEASE_FS_FILE);
	}
	first = erx_release_fs_first_at(fs, names, length, true);
	if (first < fs->count && erx_release_fs_below(&fs->files[first], names, length))
		return (ERX_RELEASE_FS_DIRECTORY);
	/* Below a file: not a directory; below an empty directory: nothing. */
	for (size_t prefix = 1; prefix < length; prefix++) {
		if (names[prefix] == '/' &&
		    erx_release_fs_find(fs, names, prefix, &found) &&
		    !fs->files[found].directory)
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

/* No NUL, and well-formed UTF-8: no overlong form, surrogate or value past Unicode's end. */
static bool
erx_release_fs_utf8_valid(const uint8_t *bytes, size_t length)
{
	size_t cursor, count;
	uint32_t point, minimum;

	cursor = 0;
	while (cursor < length) {
		point = bytes[cursor++];
		if (point == 0)
			return (false);
		if (point < 0x80)
			continue;
		if (point >= 0xc2 && point <= 0xdf) {
			point &= 0x1f;
			count = 1;
			minimum = 0x80;
		} else if (point >= 0xe0 && point <= 0xef) {
			point &= 0x0f;
			count = 2;
			minimum = 0x800;
		} else if (point >= 0xf0 && point <= 0xf4) {
			point &= 0x07;
			count = 3;
			minimum = 0x10000;
		} else {
			return (false);
		}
		if (count > length - cursor)
			return (false);
		for (size_t index = 0; index < count; index++) {
			if ((bytes[cursor] & 0xc0) != 0x80)
				return (false);
			point = (point << 6) | (bytes[cursor++] & 0x3f);
		}
		if (point < minimum || point > 0x10ffff ||
		    (point >= 0xd800 && point <= 0xdfff))
			return (false);
	}
	return (true);
}

bool
erx_release_fs_add_name(erx_release_fs_names_t *names, const uint8_t *name,
    size_t length)
{
	size_t needed;

	if (names->count == ERX_NS_NAMES_MAX || length == 0 || length > ERX_NAME_MAX ||
	    (length == 1 && name[0] == '.') ||
	    (length == 2 && name[0] == '.' && name[1] == '.') ||
	    !erx_release_fs_utf8_valid(name, length))
		return (false);
	for (size_t index = 0; index < length; index++) {
		if (name[index] == '/')
			return (false);
	}
	/* A `/` before every name but the first; a NUL's room stays, as for a place. */
	needed = length + (names->count > 0 ? 1 : 0);
	if (needed >= sizeof(names->bytes) - names->length)
		return (false);
	if (names->count > 0)
		names->bytes[names->length++] = '/';
	for (size_t index = 0; index < length; index++)
		names->bytes[names->length++] = name[index];
	names->count++;
	return (true);
}

uint32_t
erx_release_fs_walk(const erx_release_fs_t *fs, const erx_release_fs_names_t *names,
    erx_release_fs_kind_t *stop)
{
	erx_release_fs_kind_t kind;
	uint32_t passed, file;
	size_t end;

	/* Each name is looked up as the names up to it, which were all directories. */
	end = 0;
	for (passed = 0; passed < names->count; passed++) {
		do
			end++;
		while (end < names->length && names->bytes[end] != '/');
		kind = erx_release_fs_lookup(fs, names->bytes, end, &file);
		if (kind != ERX_RELEASE_FS_DIRECTORY) {
			*stop = kind;
			return (passed);
		}
		end++;
	}
	*stop = ERX_RELEASE_FS_DIRECTORY;
	return (passed);
}
