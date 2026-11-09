/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The reader of a domain's crash area (docs/design-runtime.md, "Data model"
 * and "Crash handling"). The domain's runtime wrote the area, so the system
 * domain treats it as untrusted input: the domain service copies the area
 * into memory of its own first (erx_dom_lib_crash_copy), and this checks
 * every header field before any of it is believed. Nothing here performs a
 * kernel call, so the reader builds for the host and has a fuzz target.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"

erx_status_t
erx_dom_dump_read(const uint8_t *area, size_t size, erx_dom_dump_t *dump)
{
	erx_dump_header_t header;
	const uint8_t *slogan, *nul;

	/* The decoder refuses an area shorter than the header, so size - header cannot wrap. */
	if (!erx_dump_header_decode(area, size, &header) ||
	    header.magic != ERX_DUMP_MAGIC ||
	    header.version != ERX_DUMP_VERSION ||
	    (header.flags & ~ERX_DUMP_FLAGS_KNOWN) != 0 || header.pad != 0 ||
	    header.length > size - ERX_DUMP_HEADER_SIZE)
		return (ERX_ECORRUPT);
	slogan = area + ERX_DUMP_HEADER_OFF_SLOGAN;
	nul = memchr(slogan, '\0', ERX_DUMP_SLOGAN);
	if (nul == NULL)
		return (ERX_ECORRUPT);
	*dump = (erx_dom_dump_t){ .slogan = slogan, .slogan_len = (size_t)(nul - slogan),
	    .text = area + ERX_DUMP_HEADER_SIZE, .length = header.length,
	    .truncated = (header.flags & ERX_DUMP_TRUNCATED) != 0 };
	return (ERX_OK);
}
