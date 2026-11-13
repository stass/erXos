/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device-tree reader, kernel/core/dt.c, over arbitrary bytes, handed
 * over in a buffer of exactly their length so that a read past them is an
 * AddressSanitizer report. An accepted view goes to erx_dt_device for
 * fixed paths and to erx_dt_framebuffer, and every answer must keep the
 * reader's promises: memory ranges within the bound and ordered, no DMA
 * facts beside a status other than ok, and a framebuffer whose pages lie in
 * its window and whose rows fit its length.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static const char *const paths[] = {
	"/", "/dev", "/bus/dev", "/outer/inner/dev", "/pcie", "/virtio_mmio@a003e00", "/pcie@10000000",
	"/emmc2bus/mmc@7e340000", "/scb/ethernet@7d580000", "/scb/pcie@7d500000", "/n1/n2/n3/n4/n5/n6/n7/n8"
};

static void
device_check(const erx_dt_t *tree, const char *path, erx_dt_row_t row)
{
	erx_dt_device_t facts;

	erx_dt_device(tree, path, row, &facts);
	if (facts.dma > ERX_DT_DMA_RANGES || facts.mac_status > ERX_DT_MAC_NONE)
		abort();
	if (facts.dma != ERX_DT_DMA_OK && (facts.coherent || facts.cpu != 0 || facts.bus != 0 || facts.last != 0))
		abort();
	if (facts.dma == ERX_DT_DMA_OK && facts.last < facts.cpu)
		abort();
	if (facts.mac_status == ERX_DT_MAC_OK && (facts.mac[0] & 1) != 0)
		abort();
}

static void
framebuffer_check(const erx_dt_t *tree, uint64_t base, uint64_t size)
{
	erx_dt_window_t window = { base, size };
	erx_dt_framebuffer_t fb;

	erx_dt_framebuffer(tree, "/chosen", "simple-framebuffer", window, &fb);
	if (fb.status > ERX_DT_FB_OUTSIDE)
		abort();
	if (fb.status != ERX_DT_FB_OK)
		return;
	if (erx_dt_fb_format_name(fb.format) == NULL || fb.length == 0 || size == 0 ||
	    (fb.base & ~(uint64_t)(ERX_PAGE_SIZE - 1)) < base ||
	    ((fb.base + (fb.length - 1)) | (ERX_PAGE_SIZE - 1)) > base + (size - 1) ||
	    (uint64_t)fb.stride * fb.height > fb.length || (uint64_t)fb.width * (fb.bits_per_pixel / 8) > fb.stride)
		abort();
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_dt_t tree;
	uint8_t *bytes;
	uint32_t i;
	size_t p;

	bytes = malloc(size == 0 ? 1 : size);
	if (bytes == NULL)
		return (0);
	memcpy(bytes, data, size);
	if (erx_dt_accept(bytes, size, &tree) == NULL) {
		if (tree.bytes != bytes || tree.size != size || tree.memory_count > ERX_DT_MEMORY_MAX)
			abort();
		for (i = 0; i < tree.memory_count; i++)
			if (tree.memory[i].last < tree.memory[i].first)
				abort();
		for (p = 0; p < sizeof(paths) / sizeof(paths[0]); p++) {
			device_check(&tree, paths[p], ERX_DT_ROW_NODE);
			device_check(&tree, paths[p], ERX_DT_ROW_PCIE);
		}
		framebuffer_check(&tree, 0x7e000000, 0x400000);
		framebuffer_check(&tree, 0, UINT64_MAX);
	} else if (tree.bytes != NULL || tree.memory_count != 0) {
		abort();
	}
	free(bytes);
	return (0);
}
