/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/pack.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	static _Thread_local erx_pack_scratch_t scratch;
	erx_pack_error_t error;
	erx_pack_view_t view = {0};
	erx_pack_entry_t entry;
	const uint8_t *path;
	size_t path_length;

	if (erx_pack_open(bytes, length, &scratch, &view, &error)) {
		for (uint32_t index = 0; index < view.header.nentries; index++) {
			if (!erx_pack_entry_at(&view, index, &entry) ||
			    !erx_pack_path_at(&view, index, &path, &path_length) ||
			    entry.data_off > length ||
			    entry.data_size > length - entry.data_off ||
			    path < bytes || path_length > length ||
			    path > bytes + length - path_length)
				abort();
		}
	} else if (view.bytes != NULL || view.length != 0 ||
	    view.header.nentries != 0) {
		abort();
	}
	return (0);
}
