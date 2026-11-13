/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_release_bind and erx_release_entry over an archive. The first input byte's
 * bit 0 recomputes the index hash, so mutations reach the checks behind it.
 * Every accepted entry must lie inside the archive and its path must pass
 * erx_release_fs_add_name name by name, so the limits of the bind and of the
 * release NIFs' decoder cannot drift apart. An empty directory holds
 * nothing, and over the run's first entries the release file system finds
 * each file as itself and each empty directory as a directory with nothing
 * in it. A refused archive names its check and lists nothing.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/abi_reader.h"
#include "erx/release_fs.h"
#include "erx/pack.h"
#include "erx/release.h"

#define FUZZ_TABLE_MAX	16

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* Rewrites the index hash over the index run the header declares. */
static void
fix_index(uint8_t *bytes, size_t length)
{
	static _Thread_local erx_blake3_ctx_t hasher;
	erx_pack_header_t header;
	uint64_t end;

	if (!erx_pack_header_decode(bytes, length, &header) ||
	    header.strings_off > length ||
	    header.strings_size > length - header.strings_off)
		return;
	end = header.strings_off + header.strings_size;
	end = (end + ERX_PAGE_SIZE - 1) & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	if (end > length || end < ERX_PACK_HEADER_SIZE)
		return;
	memset(bytes + ERX_PACK_HEADER_OFF_INDEX_HASH, 0, ERX_PACK_HASH_SIZE);
	erx_blake3_init(&hasher);
	erx_blake3_update(&hasher, bytes, (size_t)end);
	erx_blake3_final(&hasher, bytes + ERX_PACK_HEADER_OFF_INDEX_HASH);
}

static void
check_entry(const erx_release_entry_t *entry, size_t length)
{
	static _Thread_local erx_release_fs_names_t names;
	size_t start;

	if ((entry->kind != ERX_ENTRY_FILE && entry->kind != ERX_ENTRY_IMAGE &&
	    entry->kind != ERX_ENTRY_DIRECTORY) ||
	    (entry->kind == ERX_ENTRY_DIRECTORY && entry->size != 0) ||
	    entry->offset > length || entry->size > length - entry->offset ||
	    entry->path_length == 0 || entry->path_length >= sizeof(names.bytes))
		abort();
	names.count = 0;
	names.length = 0;
	start = 0;
	for (size_t end = 0; end <= entry->path_length; end++) {
		if (end < entry->path_length && entry->path[end] != '/')
			continue;
		if (!erx_release_fs_add_name(&names, entry->path + start, end - start))
			abort();
		start = end + 1;
	}
	if (names.length != entry->path_length ||
	    memcmp(names.bytes, entry->path, entry->path_length) != 0)
		abort();
}

/*
 * The release file system over the run's first FUZZ_TABLE_MAX entries, a
 * sorted table in which no path is a prefix of another.
 */
static void
check_table(void)
{
	static _Thread_local uint8_t paths[FUZZ_TABLE_MAX][ERX_PACK_PATH_MAX];
	static _Thread_local erx_release_fs_file_t files[FUZZ_TABLE_MAX];
	static _Thread_local erx_release_entry_t entry;
	erx_release_fs_t fs;
	const uint8_t *name, *path;
	size_t name_length, length;
	uint32_t count, cursor, file;

	for (count = 0; count < FUZZ_TABLE_MAX &&
	    erx_release_entry(count, &entry) == 0; count++) {
		memcpy(paths[count], entry.path, entry.path_length);
		files[count] = (erx_release_fs_file_t){ .path = paths[count],
		    .length = entry.path_length, .size = entry.size,
		    .offset = entry.offset,
		    .directory = entry.kind == ERX_ENTRY_DIRECTORY };
	}
	fs = (erx_release_fs_t){ .files = files, .count = count };
	for (uint32_t index = 0; index < count; index++) {
		path = files[index].path;
		length = files[index].length;
		file = UINT32_MAX;
		switch (erx_release_fs_lookup(&fs, path, length, &file)) {
		case ERX_RELEASE_FS_FILE:
			if (files[index].directory || file != index)
				abort();
			break;
		case ERX_RELEASE_FS_DIRECTORY:
			cursor = erx_release_fs_list_start(&fs, path, length);
			if (!files[index].directory ||
			    erx_release_fs_list_next(&fs, path, length, &cursor,
			    &name, &name_length))
				abort();
			break;
		default:
			abort();
		}
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	static _Thread_local erx_release_entry_t entry;
	const char *reason;
	uint8_t *bytes;
	size_t length;
	int status;

	if (size == 0)
		return (0);
	length = size - 1;
	bytes = malloc(length == 0 ? 1 : length);
	if (bytes == NULL)
		abort();
	memcpy(bytes, input + 1, length);
	if ((input[0] & 1) != 0)
		fix_index(bytes, length);
	reason = NULL;
	if (erx_release_bind(bytes, length, &reason) != 0) {
		if (reason == NULL || erx_release_entry(0, &entry) != ERX_ERANGE)
			abort();
	} else {
		for (uint64_t index = 0;
		    (status = erx_release_entry(index, &entry)) == 0; index++)
			check_entry(&entry, length);
		if (status != ERX_ERANGE)
			abort();
		check_table();
	}
	free(bytes);
	return (0);
}
