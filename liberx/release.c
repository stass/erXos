/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "blake3/blake3.h"
#include "erx/abi_reader.h"
#include "erx/pack.h"
#include "erx/release.h"

#define ERX_RELEASE_PREFIX		"system/"
#define ERX_RELEASE_PREFIX_LENGTH	(sizeof(ERX_RELEASE_PREFIX) - 1)

/* Set by erx_release_bind, before any thread reads them, and only read afterwards. */
static erx_pack_view_t	release_view;
static uint32_t		release_first;
static uint32_t		release_count;

static bool erx_release_is_under(const uint8_t *, size_t);
static bool erx_release_names_fit(const uint8_t *, size_t);

static bool
erx_release_is_under(const uint8_t *path, size_t length)
{
	if (length <= ERX_RELEASE_PREFIX_LENGTH)
		return (false);
	for (size_t index = 0; index < ERX_RELEASE_PREFIX_LENGTH; index++) {
		if (path[index] != (uint8_t)ERX_RELEASE_PREFIX[index])
			return (false);
	}
	return (true);
}

/*
 * Whether a name list can name a path under the prefix: erx_release_fs_add_name
 * refuses a longer name or more names, and a release file no path resolves to must not bind.
 * erx_pack_open has refused `.`, `..` and empty names, so each name counts.
 */
static bool
erx_release_names_fit(const uint8_t *path, size_t length)
{
	size_t name_length;
	uint32_t names;

	names = 1;
	name_length = 0;
	for (size_t cursor = ERX_RELEASE_PREFIX_LENGTH; cursor < length; cursor++) {
		if (path[cursor] == '/') {
			names++;
			name_length = 0;
		} else if (++name_length > ERX_NAME_MAX) {
			return (false);
		}
	}
	return (names <= ERX_NS_NAMES_MAX);
}

int
erx_release_bind(const uint8_t *bytes, size_t length, const char **reason)
{
	/* The workspace is large for a stack, and the one call owns it. */
	static erx_pack_scratch_t scratch;
	erx_blake3_ctx_t hasher;
	erx_pack_error_t error;
	const uint8_t *path;
	size_t path_length;
	uint32_t first, count;

	release_first = 0;
	release_count = 0;
	error = (erx_pack_error_t){ .reason = "archive", .entry = UINT32_MAX };
	if (!erx_pack_open(bytes, length, &scratch, &hasher, &release_view, &error)) {
		*reason = error.reason;
		return (ERX_EINVAL);
	}
	first = 0;
	count = 0;
	/* The index is sorted, so the paths under the prefix form one run. */
	for (uint32_t index = 0; index < release_view.header.nentries; index++) {
		if (!erx_pack_path_at(&release_view, index, &path, &path_length) ||
		    !erx_release_is_under(path, path_length))
			continue;
		if (!erx_release_names_fit(path, path_length)) {
			release_view = (erx_pack_view_t){ 0 };
			*reason = "release_name";
			return (ERX_EINVAL);
		}
		if (count == 0)
			first = index;
		count++;
	}
	release_first = first;
	release_count = count;
	return (0);
}

int
erx_release_entry(uint64_t index, erx_release_entry_t *entry)
{
	erx_pack_entry_t raw;
	const uint8_t *path;
	size_t path_length;

	if (index >= release_count ||
	    !erx_pack_entry_at(&release_view, release_first + (uint32_t)index, &raw) ||
	    !erx_pack_path_at(&release_view, release_first + (uint32_t)index, &path,
	    &path_length) || path_length <= ERX_RELEASE_PREFIX_LENGTH)
		return (ERX_ERANGE);
	entry->size = raw.data_size;
	entry->offset = raw.data_off;
	entry->kind = raw.kind;
	entry->path_length = path_length - ERX_RELEASE_PREFIX_LENGTH;
	for (size_t cursor = 0; cursor < entry->path_length; cursor++)
		entry->path[cursor] = path[ERX_RELEASE_PREFIX_LENGTH + cursor];
	return (0);
}

const uint8_t *
erx_release_addr(void)
{
	return (release_view.bytes);
}

int
erx_release_manifest(const uint8_t **bytes, size_t *length, const char **reason)
{
	static const uint8_t name[] = ERX_SYSTEM_MANIFEST_PATH_BYTES;
	erx_blake3_ctx_t hasher;
	erx_pack_error_t error;
	erx_pack_entry_t raw;
	const uint8_t *path;
	size_t path_length;

	for (uint32_t index = 0; index < release_view.header.nentries; index++) {
		bool same;

		if (!erx_pack_path_at(&release_view, index, &path, &path_length))
			continue;
		same = path_length == sizeof(name);
		for (size_t cursor = 0; same && cursor < path_length; cursor++)
			same = path[cursor] == name[cursor];
		if (!same)
			continue;
		error = (erx_pack_error_t){ .reason = "manifest", .entry = index };
		if (!erx_pack_file_check(&release_view, index, &hasher, &error) ||
		    !erx_pack_entry_at(&release_view, index, &raw)) {
			*reason = error.reason;
			return (ERX_EINVAL);
		}
		*bytes = release_view.bytes + raw.data_off;
		*length = raw.data_size;
		return (0);
	}
	*reason = "manifest";
	return (ERX_EINVAL);
}

int
erx_release_check(uint64_t index, const char **reason)
{
	erx_blake3_ctx_t hasher;
	erx_pack_error_t error;

	if (index >= release_count)
		return (ERX_ERANGE);
	error = (erx_pack_error_t){ .reason = "file", .entry = release_first + (uint32_t)index };
	if (!erx_pack_file_check(&release_view, release_first + (uint32_t)index, &hasher, &error)) {
		*reason = error.reason;
		return (ERX_ECORRUPT);
	}
	return (0);
}

uint32_t
erx_release_pack_flags(void)
{
	return (release_view.header.flags);
}
