/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_release_bind and erx_release_entry over an archive. The first input byte's
 * bit 0 recomputes the index hash, so mutations reach the checks behind it.
 * Every accepted entry must lie inside the archive and resolve through
 * erx_ns_resolve to its own name, so the limits of the bind and of the resolver
 * cannot drift apart. A refused archive names its check and lists nothing.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/abi_reader.h"
#include "erx/ns.h"
#include "erx/pack.h"
#include "erx/release.h"

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
	static _Thread_local erx_ns_t ns;
	static _Thread_local erx_ns_result_t out;
	static _Thread_local uint8_t path[ERX_PATH_MAX];

	if (entry->offset > length || entry->size > length - entry->offset ||
	    entry->path_length == 0 || entry->path_length >= sizeof(path))
		abort();
	ns.count = 1;
	ns.mounts[0].kind = ERX_NS_RELEASE;
	ns.mounts[0].point[0] = '/';
	ns.mounts[0].root[0] = '/';
	ns.cwd[0] = '/';
	path[0] = '/';
	memcpy(path + 1, entry->path, entry->path_length);
	if (erx_ns_resolve(&ns, path, entry->path_length + 1, &out) != ERX_NS_OK ||
	    out.res_names_length != entry->path_length ||
	    memcmp(out.res_names, entry->path, entry->path_length) != 0)
		abort();
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
	}
	free(bytes);
	return (0);
}
