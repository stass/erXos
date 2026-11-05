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

/* Set once by erx_release_bind and only read afterwards. */
static erx_pack_view_t	release_view;
static uint32_t		release_first;
static uint32_t		release_count;

static bool erx_release_is_under(const uint8_t *, size_t);

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
