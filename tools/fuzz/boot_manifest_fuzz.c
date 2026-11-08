/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_manifest_read over raw bytes, in a buffer of exactly their size. A refusal names
 * its reason. What it accepts names a system node and arguments inside the buffer, and goes
 * on as an entry takes it: into a page from erx_boot_info_build, which the reader must
 * accept and which must say the same. Read again without the host link, the same bytes give
 * the same records less the host link's.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_manifest.h"

#define NODE_PREFIX	"system@"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint8_t page[4096];

static void
check_the_page_says_the_same(const erx_boot_manifest_t *manifest)
{
	const erx_boot_inputs_t inputs = {
		.flags = ERX_BOOT_ROOT,
		.node = manifest->node,
		.node_len = manifest->node_len,
		.args = &manifest->system_args,
		.nargs = 1,
		.limits = manifest->limits,
	};
	erx_boot_view_t view;

	if (erx_boot_info_build(&inputs, page, sizeof(page)) != ERX_BOOT_INFO_OK)
		return;
	if (erx_boot_info_read(page, sizeof(page), &view) != ERX_BOOT_INFO_OK)
		abort();
	if (view.info.node_len != manifest->node_len || memcmp(view.node, manifest->node, manifest->node_len) != 0)
		abort();
	if (manifest->system_args.length != 0 &&
	    memcmp(view.args, manifest->system_args.bytes, manifest->system_args.length) != 0)
		abort();
	if (memcmp(&view.info.limits, &manifest->limits, sizeof(manifest->limits)) != 0)
		abort();
}

static bool
same_device(const erx_boot_device_t *a, const erx_boot_device_t *b)
{
	return (a->role == b->role && a->peripheral == b->peripheral && a->base == b->base && a->size == b->size &&
	    a->line == b->line && a->dma_memory == b->dma_memory);
}

/* Without the host link the reader accepts what it accepted with it, and gives its records less the host link's. */
static void
check_without_the_hostlink(const uint8_t *bytes, size_t length, const erx_boot_manifest_t *with)
{
	erx_boot_manifest_t without;
	const char *reason = NULL;
	size_t kept = 0;

	if (!erx_boot_manifest_read(bytes, length, false, &without, &reason))
		abort();
	for (size_t at = 0; at < with->device_count; at++) {
		if (strcmp(with->devices[at].role, "hostlink") == 0)
			continue;
		if (kept == without.device_count || !same_device(&with->devices[at], &without.devices[kept]))
			abort();
		kept++;
	}
	if (kept != without.device_count)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_boot_manifest_t manifest;
	const char *reason = NULL;
	const uint8_t *args;

	if (!erx_boot_manifest_read(bytes, length, true, &manifest, &reason)) {
		if (reason == NULL || reason[0] == '\0')
			abort();
		return (0);
	}
	if (manifest.node_len < sizeof(NODE_PREFIX) - 1 || manifest.node_len > sizeof(manifest.node) ||
	    memcmp(manifest.node, NODE_PREFIX, sizeof(NODE_PREFIX) - 1) != 0)
		abort();
	args = (const uint8_t *)manifest.system_args.bytes;
	if (args < bytes || args > bytes + length || manifest.system_args.length > (size_t)(bytes + length - args))
		abort();
	for (size_t at = 0; at < manifest.system_args.length; at++) {
		if (args[at] != '\0' && (args[at] < 0x20 || args[at] > 0x7e))
			abort();
	}
	check_the_page_says_the_same(&manifest);
	check_without_the_hostlink(bytes, length, &manifest);
	return (0);
}
