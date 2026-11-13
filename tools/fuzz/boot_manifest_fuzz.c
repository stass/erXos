/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_manifest_read over raw bytes, in a buffer of exactly their size. A refusal names
 * its reason. What it accepts names a system node and arguments inside the buffer, and goes
 * on as an entry takes it: into a page from erx_boot_info_build, which the reader must
 * accept and which must say the same. Read again without the host link, the same bytes give
 * the same records less the host link's. Every record's words, a framebuffer row's among
 * them, fit the room erx/boot_words.h gives its form.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"
#include "liberx/backend/core/boot_manifest.h"
#include "liberx/backend/core/manifest_dma.h"

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
	    a->line == b->line && a->line_shared == b->line_shared && a->clock == b->clock &&
	    a->dma_memory == b->dma_memory && a->framebuffer == b->framebuffer && a->index == b->index);
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
		/* A framebuffer row has no role: it is never the host link's. */
		if (with->devices[at].role != NULL && strcmp(with->devices[at].role, "hostlink") == 0)
			continue;
		if (kept == without.device_count || !same_device(&with->devices[at], &without.devices[kept]))
			abort();
		kept++;
	}
	if (kept != without.device_count)
		abort();
}

/*
 * A framebuffer row's record (erx_boot_framebuffer_words) and its line (erx_boot_framebuffer_line)
 * over the longest facts: every number at its widest, a format of the longest name the room
 * takes, which is longer than every name of the reader's table, and an outside range at the
 * top of the address space. The row itself gives no -erx device words: it has no role.
 */
static void
check_a_framebuffer_fits(const erx_boot_device_t *device)
{
	static const char format[ERX_BOOT_FORMAT_WORD_MAX] = "abcdefghijk";
	const erx_dt_framebuffer_t placed = { .status = ERX_DT_FB_OK, .base = 0, .length = UINT64_MAX,
	    .width = UINT32_MAX, .height = UINT32_MAX, .stride = UINT32_MAX };
	const erx_dt_framebuffer_t outside = { .status = ERX_DT_FB_OUTSIDE, .base = UINT64_MAX, .length = UINT64_MAX };
	char words[ERX_BOOT_FRAMEBUFFER_WORDS_MAX];
	char line[ERX_BOOT_TREE_LINE_MAX];

	if (erx_boot_device_words(device, words, sizeof(words)) != 0)
		abort();
	if (erx_boot_framebuffer_words(&placed, format, UINT64_MAX, UINT64_MAX, words, sizeof(words)) == 0)
		abort();
	if (device->path.length == 0 || device->path.length >= ERX_PATH_MAX ||
	    !erx_boot_node_path_valid((const uint8_t *)device->path.bytes, device->path.length))
		return;
	if (erx_boot_framebuffer_line(device->path, &placed, format, line, sizeof(line)) == 0 ||
	    erx_boot_framebuffer_line(device->path, &outside, NULL, line, sizeof(line)) == 0)
		abort();
}

/*
 * Every record's words fit the room erx/boot_words.h gives its form, whatever the manifest
 * says, with every handle at its widest: the root sizes its buffers by that room.
 */
static void
check_the_words_fit(const erx_boot_manifest_t *manifest)
{
	/* The longest facts: a coherent range at the top of the address space and an address. */
	static const erx_dt_device_t longest = { .dma = ERX_DT_DMA_OK, .coherent = true, .cpu = UINT64_MAX,
	    .bus = UINT64_MAX, .last = UINT64_MAX, .mac_status = ERX_DT_MAC_OK,
	    .mac = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } };
	char words[ERX_BOOT_GIVEN_WORDS_MAX];
	char line[ERX_BOOT_TREE_LINE_MAX];
	erx_boot_window_t window;
	erx_boot_given_t given;

	if (manifest->console.size != 0 && erx_boot_console_words(&manifest->console, words, ERX_BOOT_CONSOLE_WORDS_MAX) == 0)
		abort();
	for (size_t at = 0; at < manifest->device_count; at++) {
		const erx_boot_device_t *device = &manifest->devices[at];

		if (device->framebuffer) {
			check_a_framebuffer_fits(device);
		} else if (!device->given) {
			if (erx_boot_device_words(device, words, ERX_BOOT_DEVICE_WORDS_MAX) == 0)
				abort();
		} else if (erx_boot_device_window(device, &window)) {
			given = erx_boot_device_given(device, &window, &longest, UINT64_MAX, UINT64_MAX, UINT64_MAX);
			if (erx_boot_given_words(&given, words, ERX_BOOT_GIVEN_WORDS_MAX) == 0)
				abort();
			/* A device that asks has a node path, so its line fits ERX_BOOT_TREE_LINE_MAX. */
			if (erx_boot_row_asks(device->dma_memory, device->network) && device->path.length != 0 &&
			    device->path.length < ERX_PATH_MAX &&
			    erx_boot_node_path_valid((const uint8_t *)device->path.bytes, device->path.length) &&
			    erx_boot_tree_line(device->path, device->dma_memory, device->network, &longest, NULL, line,
			    sizeof(line)) == 0)
				abort();
		}
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_boot_manifest_t manifest;
	erx_manifest_view_t view;
	erx_abi_error_t error = { 0 };
	const char *reason = NULL;
	const uint8_t *args;
	uint64_t dma_total;

	/* The root's contiguous pool total walks the whole device table of any manifest that opens. */
	if (erx_manifest_open(bytes, length, &view, &error))
		(void)erx_boot_manifest_dma_total(&view, &dma_total);
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
	check_the_words_fit(&manifest);
	return (0);
}
