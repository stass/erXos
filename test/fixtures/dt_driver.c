/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives kernel/core/dt.c for test/host/dt_test.rb. Usage: dt_driver TREE
 * [PREFIX]. The tree's bytes, or only their first PREFIX bytes, go in a
 * buffer of exactly that length, so a read past them is a sanitizer
 * report. The first output line is the acceptance: "accept ok" or "accept
 * REASON". Then each query on standard input gets one line:
 *
 *   device PATH node|pcie
 *     -> device DMA coherent C range CPU BUS LAST mac M
 *   fb PATH COMPATIBLE WINDOW_BASE WINDOW_SIZE
 *     -> fb STATUS BASE LENGTH WIDTHxHEIGHT STRIDE FORMAT
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/dt.h"

static const char *const dma_names[] = { "ok", "no_node", "coherence", "cells", "malformed", "ranges" };
static const char *const fb_names[] = { "ok", "none", "ambiguous", "malformed", "unsupported", "outside" };

static void
device_print(const erx_dt_t *tree, const char *path, const char *row)
{
	erx_dt_device_t facts;

	erx_dt_device(tree, path, strcmp(row, "pcie") == 0 ? ERX_DT_ROW_PCIE : ERX_DT_ROW_NODE, &facts);
	printf("device %s coherent %d range 0x%" PRIx64 " 0x%" PRIx64 " 0x%" PRIx64 " mac ", dma_names[facts.dma],
	    facts.coherent, facts.cpu, facts.bus, facts.last);
	if (facts.mac_status == ERX_DT_MAC_OK)
		printf("%02x:%02x:%02x:%02x:%02x:%02x\n", facts.mac[0], facts.mac[1], facts.mac[2], facts.mac[3],
		    facts.mac[4], facts.mac[5]);
	else
		printf("none\n");
}

static void
fb_print(const erx_dt_t *tree, const char *path, const char *compatible, const char *base, const char *size)
{
	erx_dt_window_t window = { strtoull(base, NULL, 0), strtoull(size, NULL, 0) };
	erx_dt_framebuffer_t fb;
	const char *format;

	erx_dt_framebuffer(tree, path, compatible, window, &fb);
	format = fb.status == ERX_DT_FB_OK ? erx_dt_fb_format_name(fb.format) : "-";
	printf("fb %s 0x%" PRIx64 " 0x%" PRIx64 " %ux%u %u %s %u\n", fb_names[fb.status], fb.base, fb.length,
	    fb.width, fb.height, fb.stride, format, fb.bits_per_pixel);
}

int
main(int argc, char **argv)
{
	char line[2048], *words[6], *save;
	unsigned char *bytes;
	const char *reason;
	erx_dt_t tree;
	FILE *file;
	long size;
	size_t length;
	int count;

	if (argc < 2 || (file = fopen(argv[1], "rb")) == NULL || fseek(file, 0, SEEK_END) != 0 ||
	    (size = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0)
		return (2);
	length = argc > 2 ? strtoul(argv[2], NULL, 0) : (size_t)size;
	if (length > (size_t)size || (bytes = malloc(length == 0 ? 1 : length)) == NULL ||
	    fread(bytes, 1, length, file) != length)
		return (2);
	fclose(file);

	reason = erx_dt_accept(bytes, length, &tree);
	printf("accept %s memory %u\n", reason == NULL ? "ok" : reason, tree.memory_count);
	while (fgets(line, sizeof(line), stdin) != NULL) {
		count = 0;
		for (words[0] = strtok_r(line, " \n", &save); words[count] != NULL && count < 5;)
			words[++count] = strtok_r(NULL, " \n", &save);
		if (count == 3 && strcmp(words[0], "device") == 0)
			device_print(&tree, words[1], words[2]);
		else if (count == 5 && strcmp(words[0], "fb") == 0)
			fb_print(&tree, words[1], words[2], words[3], words[4]);
		else
			return (2);
	}
	free(bytes);
	return (0);
}
