/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_args_parse over raw bytes. A line it accepts must walk to the words it
 * counted, each without a space or a NUL and all within the page's strings. A refusal
 * must name a word of the line that starts with erx.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/boot_args.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t length)
{
	const char *bytes = (const char *)data;
	erx_boot_args_t out;
	size_t cursor = 0, word_len;
	const char *word;
	uint32_t count = 0, total = 0;

	if (!erx_boot_args_parse(bytes, length, &out)) {
		if (out.refused < bytes || out.refused_len < 4 || out.refused_len > length - (size_t)(out.refused - bytes) ||
		    memcmp(out.refused, "erx.", 4) != 0)
			abort();
		return (0);
	}
	while (erx_boot_args_next_arg(bytes, length, &cursor, &word, &word_len)) {
		if (word_len == 0 || memchr(word, ' ', word_len) != NULL || memchr(word, '\0', word_len) != NULL)
			abort();
		count++;
		total += (uint32_t)word_len + 1;
	}
	if (count != out.arg_count || total != out.arg_bytes || total > ERX_BOOT_STRINGS_MAX)
		abort();
	return (0);
}
