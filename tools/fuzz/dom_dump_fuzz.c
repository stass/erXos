/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_dom_dump_read over raw bytes, an area of exactly their size. The
 * reader must accept exactly the areas the header rules of
 * docs/design-runtime.md, "Data model", accept, which this restates over
 * little-endian loads of its own, and what it accepts must lie inside the
 * area: the slogan within its field and ending at its first NUL, the text
 * right after the header and within the area.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/dom.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint64_t
load_le(const uint8_t *bytes, size_t width)
{
	uint64_t value = 0;

	for (size_t at = width; at > 0; at--)
		value = value << 8 | bytes[at - 1];
	return (value);
}

/* The header rules, restated. */
static bool
dump_valid(const uint8_t *area, size_t size)
{
	if (size < ERX_DUMP_HEADER_SIZE)
		return (false);
	return (load_le(area + ERX_DUMP_HEADER_OFF_MAGIC, 4) == ERX_DUMP_MAGIC &&
	    load_le(area + ERX_DUMP_HEADER_OFF_VERSION, 4) == ERX_DUMP_VERSION &&
	    (load_le(area + ERX_DUMP_HEADER_OFF_FLAGS, 4) & ~(uint64_t)ERX_DUMP_TRUNCATED) == 0 &&
	    load_le(area + ERX_DUMP_HEADER_OFF_PAD, 4) == 0 &&
	    load_le(area + ERX_DUMP_HEADER_OFF_LENGTH, 8) <= size - ERX_DUMP_HEADER_SIZE &&
	    memchr(area + ERX_DUMP_HEADER_OFF_SLOGAN, '\0', ERX_DUMP_SLOGAN) != NULL);
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	const uint8_t *slogan;
	erx_dom_dump_t dump;
	const erx_status_t status = erx_dom_dump_read(bytes, length, &dump);

	if ((status == ERX_OK) != dump_valid(bytes, length) || (status != ERX_OK && status != ERX_ECORRUPT))
		abort();
	if (status != ERX_OK)
		return (0);
	slogan = bytes + ERX_DUMP_HEADER_OFF_SLOGAN;
	if (dump.slogan != slogan || dump.slogan_len >= ERX_DUMP_SLOGAN || slogan[dump.slogan_len] != '\0' ||
	    memchr(slogan, '\0', dump.slogan_len) != NULL)
		abort();
	if (dump.text != bytes + ERX_DUMP_HEADER_SIZE || dump.length > length - ERX_DUMP_HEADER_SIZE ||
	    dump.length != load_le(bytes + ERX_DUMP_HEADER_OFF_LENGTH, 8) ||
	    dump.truncated != ((bytes[ERX_DUMP_HEADER_OFF_FLAGS] & ERX_DUMP_TRUNCATED) != 0))
		abort();
	return (0);
}
