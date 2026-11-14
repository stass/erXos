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
	    (record.flags & ~(uint32_t)(ERX_PACK_DEVELOPMENT | ERX_PACK_UNCONFINED_DMA | ERX_PACK_TEST_CODE)) != 0 ||
	    ((record.flags & ERX_PACK_TEST_CODE) != 0 && (record.flags & ERX_PACK_DEVELOPMENT) == 0) ||
	    record.image_size == 0 || record.image_start % ERX_PAGE_SIZE != 0 || record.image_size % ERX_PAGE_SIZE != 0 ||
	    __builtin_add_overflow(record.image_start, record.image_size, &end) ||
	    record.bootargs_len > ERX_BOOT_STRINGS_MAX || record.stdout_path_len > ERX_BOOT_STDOUT_PATH_MAX ||
	    !(record.boot_value == ERX_BOOT_VALUE_UNKNOWN ? record.boot_slot == ERX_BOOT_SLOT_NONE :
	    (record.boot_value == ERX_BOOT_VALUE_NORMAL || record.boot_value == ERX_BOOT_VALUE_TRIAL) &&
	    (record.boot_slot == ERX_BOOT_SLOT_A || record.boot_slot == ERX_BOOT_SLOT_B)) ||
	    record.tree_start % ERX_PAGE_SIZE != 0 || record.tree_size == 0 || record.tree_size > ERX_BOOT_TREE_MAX ||
	    __builtin_add_overflow(record.tree_start, record.tree_size, &end))
		abort();
	if (view.flags != record.flags || view.development != ((record.flags & ERX_PACK_DEVELOPMENT) != 0) ||
	    view.test_code != ((record.flags & ERX_PACK_TEST_CODE) != 0) ||
	    view.image.start != record.image_start || view.image.size != record.image_size ||
	    view.pool_usable != record.pool_usable || view.pool_heap != record.pool_heap ||
	    view.pool_regions != record.pool_regions || view.bootargs_len != record.bootargs_len ||
	    view.stdout_path_len != record.stdout_path_len ||
	    view.boot.value != record.boot_value || view.boot.slot != record.boot_slot ||
	    view.tree.start != record.tree_start || view.tree.size != record.tree_size ||
	    memcmp(view.build_id, record.build_id, sizeof(view.build_id)) != 0 ||
	    memcmp(view.index_hash, record.index_hash, sizeof(view.index_hash)) != 0 ||
	    memcmp(view.cpu_id, record.cpu_id, sizeof(view.cpu_id)) != 0)
		abort();
	/* The whole string the view points to lies inside the record. */
	if (view.bootargs != (const char *)at + ERX_BOOT_HANDOFF_OFF_BOOTARGS ||
	    ERX_BOOT_HANDOFF_OFF_BOOTARGS + view.bootargs_len > ERX_BOOT_HANDOFF_SIZE ||
	    view.stdout_path != (const char *)at + ERX_BOOT_HANDOFF_OFF_STDOUT_PATH ||
	    ERX_BOOT_HANDOFF_OFF_STDOUT_PATH + view.stdout_path_len > ERX_BOOT_HANDOFF_OFF_BOOT_VALUE)
		abort();
	/* An accepted stdout path is empty or a node path: no byte the root could not print. */
	for (uint32_t index = 0; index < view.stdout_path_len; index++) {
		const char c = view.stdout_path[index];

		if (c < 0x21 || c > 0x7e || c == 0x3a || (index == 0 && c != 0x2f))
			abort();
	}
	return (0);
}
