/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"

_Static_assert(ERX_BOOT_HANDOFF_RECORD_SIZE == ERX_BOOT_HANDOFF_SIZE,
    "the seam's record size is the ABI's");
_Static_assert(ERX_BOOT_TREE_COPY_MAX == ERX_BOOT_TREE_MAX &&
    ERX_BOOT_TREE_ALIGN == ERX_PAGE_SIZE, "the seam's tree bounds are the ABI's");
_Static_assert(sizeof(((erx_boot_handoff_view_t *)0)->build_id) ==
    sizeof(((erx_boot_handoff_t *)0)->build_id) &&
    sizeof(((erx_boot_handoff_view_t *)0)->index_hash) ==
    sizeof(((erx_boot_handoff_t *)0)->index_hash), "the view holds the record's identifiers");

const char *
erx_boot_handoff_accept(const uint8_t *record, size_t length,
    erx_boot_handoff_view_t *view)
{
	const erx_boot_handoff_t *handoff;
	uint64_t end;

	if (record == NULL || view == NULL || length < ERX_BOOT_HANDOFF_SIZE ||
	    ((uintptr_t)record % ERX_BOOT_HANDOFF_ALIGN) != 0)
		return ("record_extent");
	handoff = (const erx_boot_handoff_t *)(const void *)record;
	if (handoff->version != ERX_BOOT_HANDOFF_VERSION)
		return ("version");
	/* Only a development build may carry test code. */
	if ((handoff->flags & ~ERX_PACK_FLAGS_KNOWN) != 0 ||
	    ((handoff->flags & ERX_PACK_TEST_CODE) != 0 &&
	    (handoff->flags & ERX_PACK_DEVELOPMENT) == 0))
		return ("flags");
	if (handoff->image_size == 0 ||
	    (handoff->image_start % ERX_PAGE_SIZE) != 0 ||
	    (handoff->image_size % ERX_PAGE_SIZE) != 0 ||
	    __builtin_add_overflow(handoff->image_start, handoff->image_size, &end))
		return ("image_range");
	if (handoff->bootargs_len > ERX_BOOT_STRINGS_MAX)
		return ("bootargs_length");
	if (handoff->stdout_path_len > ERX_BOOT_STDOUT_PATH_MAX)
		return ("stdout_path_length");
	if (!erx_boot_node_path_valid(handoff->stdout_path, handoff->stdout_path_len))
		return ("stdout_path");
	if (!erx_boot_pair_valid(handoff->boot_value, handoff->boot_slot))
		return ("boot_value");
	if (!erx_boot_tree_range_valid(handoff->tree_start, handoff->tree_size))
		return ("tree_range");
	*view = (erx_boot_handoff_view_t){
		.flags = handoff->flags,
		.development = (handoff->flags & ERX_PACK_DEVELOPMENT) != 0,
		.test_code = (handoff->flags & ERX_PACK_TEST_CODE) != 0,
		.image = { .start = handoff->image_start,
		    .size = handoff->image_size },
		.pool_usable = handoff->pool_usable,
		.pool_heap = handoff->pool_heap,
		.pool_regions = handoff->pool_regions,
		.bootargs = (const char *)handoff->bootargs,
		.bootargs_len = handoff->bootargs_len,
		.stdout_path = (const char *)handoff->stdout_path,
		.stdout_path_len = handoff->stdout_path_len,
		.boot = { .value = handoff->boot_value, .slot = handoff->boot_slot },
		.tree = { .start = handoff->tree_start, .size = handoff->tree_size },
	};
	for (size_t index = 0; index < sizeof(view->build_id); index++)
		view->build_id[index] = handoff->build_id[index];
	for (size_t index = 0; index < sizeof(view->index_hash); index++)
		view->index_hash[index] = handoff->index_hash[index];
	return (NULL);
}

bool
erx_boot_handoff_covered(const erx_boot_handoff_view_t *view,
    const erx_boot_range_t *ranges, size_t count)
{
	uint64_t end, range_end;

	if (view == NULL || ranges == NULL ||
	    __builtin_add_overflow(view->image.start, view->image.size, &end))
		return (false);
	for (size_t index = 0; index < count; index++) {
		if (__builtin_add_overflow(ranges[index].start, ranges[index].size,
		    &range_end))
			continue;
		if (ranges[index].start <= view->image.start && end <= range_end)
			return (true);
	}
	return (false);
}
