/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot handoff record's reader over raw bytes, at the record's alignment. Every
 * record it accepts must satisfy each check the root's start relies on, stated again
 * here so that a change to the reader's bounds aborts, and must come back the same in
 * the view. The first input byte moves the record off its alignment when it is odd.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static _Alignas(ERX_BOOT_HANDOFF_ALIGN) uint8_t buffer[ERX_BOOT_HANDOFF_SIZE + 2 * ERX_BOOT_HANDOFF_ALIGN];
	erx_boot_handoff_t record;
	erx_boot_handoff_view_t view;
	uint64_t end;
	const uint8_t *at;
	size_t length;

	if (size < 1)
		return (0);
	at = buffer + (data[0] & 1);
	length = size - 1 < ERX_BOOT_HANDOFF_SIZE + ERX_BOOT_HANDOFF_ALIGN ? size - 1 : ERX_BOOT_HANDOFF_SIZE + ERX_BOOT_HANDOFF_ALIGN;
	memset(buffer, 0, sizeof(buffer));
	memcpy(buffer + (data[0] & 1), data + 1, length);
	if (erx_boot_handoff_accept(at, length, &view) != NULL)
		return (0);

	if ((uintptr_t)at % ERX_BOOT_HANDOFF_ALIGN != 0 || length < ERX_BOOT_HANDOFF_SIZE)
		abort();
	memcpy(&record, at, sizeof(record));
	if (record.version != ERX_BOOT_HANDOFF_VERSION ||
	    (record.flags & ~(uint32_t)(ERX_PACK_DEVELOPMENT | ERX_PACK_UNCONFINED_DMA)) != 0 ||
	    record.image_size == 0 || record.image_start % ERX_PAGE_SIZE != 0 || record.image_size % ERX_PAGE_SIZE != 0 ||
	    __builtin_add_overflow(record.image_start, record.image_size, &end) ||
	    record.bootargs_len > ERX_BOOT_STRINGS_MAX)
		abort();
	if (view.flags != record.flags || view.development != ((record.flags & ERX_PACK_DEVELOPMENT) != 0) ||
	    view.image.start != record.image_start || view.image.size != record.image_size ||
	    view.pool_usable != record.pool_usable || view.pool_heap != record.pool_heap ||
	    view.pool_regions != record.pool_regions || view.bootargs_len != record.bootargs_len ||
	    memcmp(view.build_id, record.build_id, sizeof(view.build_id)) != 0 ||
	    memcmp(view.index_hash, record.index_hash, sizeof(view.index_hash)) != 0)
		abort();
	/* The whole string the view points to lies inside the record. */
	if (view.bootargs != (const char *)at + ERX_BOOT_HANDOFF_OFF_BOOTARGS ||
	    ERX_BOOT_HANDOFF_OFF_BOOTARGS + view.bootargs_len > ERX_BOOT_HANDOFF_SIZE)
		abort();
	return (0);
}
