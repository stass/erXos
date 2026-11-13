/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot validator and the file check. The first input byte chooses
 * fix-ups, the rest is the archive: bit 0 recomputes the index hash, and
 * bit 1 every file hash and then the index hash, so mutations reach the
 * checks behind the hashes instead of stopping at them. Every accepted
 * entry must lie inside the archive, a file check runs over every entry of
 * an accepted index, and a refused archive leaves the view zero.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/abi_reader.h"
#include "erx/pack.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static void
digest(erx_blake3_ctx_t *hasher, const uint8_t *bytes, size_t length,
    uint8_t *out)
{
	erx_blake3_init(hasher);
	erx_blake3_update(hasher, bytes, length);
	erx_blake3_final(hasher, out);
}

/* Rewrites the index hash over the index run the header declares. */
static void
fix_index(uint8_t *bytes, size_t length, erx_blake3_ctx_t *hasher)
{
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
	digest(hasher, bytes, (size_t)end, bytes + ERX_PACK_HEADER_OFF_INDEX_HASH);
}

/* Rewrites each file hash whose entry and run lie inside the archive. */
static void
fix_files(uint8_t *bytes, size_t length, erx_blake3_ctx_t *hasher)
{
	erx_pack_header_t header;
	erx_pack_entry_t entry;
	uint64_t offset, end;

	if (!erx_pack_header_decode(bytes, length, &header))
		return;
	for (uint32_t index = 0; index < header.nentries &&
	    index < ERX_PACK_ENTRIES_MAX; index++) {
		offset = ERX_PACK_HEADER_SIZE + (uint64_t)index * ERX_PACK_ENTRY_SIZE;
		if (offset + ERX_PACK_ENTRY_SIZE > length)
			return;
		if (!erx_pack_entry_decode(bytes + offset, ERX_PACK_ENTRY_SIZE,
		    &entry) || entry.data_off > length ||
		    entry.data_size > length - entry.data_off)
			continue;
		end = entry.data_off + entry.data_size;
		end = (end + ERX_PAGE_SIZE - 1) & ~(uint64_t)(ERX_PAGE_SIZE - 1);
		if (end > length)
			end = length;
		digest(hasher, bytes + entry.data_off,
		    (size_t)(end - entry.data_off),
		    bytes + offset + ERX_PACK_ENTRY_OFF_FILE_HASH);
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	static _Thread_local erx_pack_scratch_t scratch;
	static _Thread_local erx_blake3_ctx_t hasher;
	erx_pack_error_t error;
	erx_pack_view_t view;
	erx_pack_entry_t entry;
	const uint8_t *path;
	uint8_t *bytes;
	size_t length, path_length;

	if (size == 0)
		return (0);
	length = size - 1;
	bytes = malloc(length == 0 ? 1 : length);
	if (bytes == NULL)
		abort();
	memcpy(bytes, input + 1, length);
	memset(&view, 0xa5, sizeof(view));
	if ((input[0] & 2) != 0)
		fix_files(bytes, length, &hasher);
	if ((input[0] & 3) != 0)
		fix_index(bytes, length, &hasher);
	if (erx_pack_open(bytes, length, &scratch, &hasher, &view, &error)) {
		for (uint32_t index = 0; index < view.header.nentries; index++) {
			if (!erx_pack_entry_at(&view, index, &entry) ||
			    !erx_pack_path_at(&view, index, &path, &path_length) ||
			    entry.data_off > length ||
			    entry.data_size > length - entry.data_off ||
			    path < bytes || path_length > length ||
			    path > bytes + length - path_length ||
			    (entry.kind == ERX_ENTRY_DIRECTORY &&
			    entry.data_size != 0))
				abort();
			if (!erx_pack_file_check(&view, index, &hasher, &error) &&
			    (error.reason == NULL || error.entry != index))
				abort();
		}
	} else if (view.bytes != NULL || view.length != 0 ||
	    view.header.nentries != 0 || view.header.total_size != 0 ||
	    view.header.version != 0 || error.reason == NULL) {
		abort();
	}
	free(bytes);
	return (0);
}
