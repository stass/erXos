/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/backend/core/boot_manifest.h"
#include "liberx/backend/core/manifest_dma.h"

/* The handles the driver stands in for the root's register window, line and memory objects. */
#define WINDOW_HANDLE	11u
#define LINE_HANDLE	12u
#define MEMORY_HANDLE	13u

/*
 * Prints the window erx_boot_device_window makes of a given device's registers, or that it
 * refuses them, then the -erx given record erx_boot_device_given assembles with the handles
 * above, NULs as spaces, and what erx_boot_given_words returns given exactly its room and one
 * byte less.
 */
static void
given_print(const erx_boot_device_t *device, const erx_dt_device_t *facts, uint64_t memory_handle)
{
	char words[ERX_BOOT_GIVEN_WORDS_MAX];
	erx_boot_window_t window;
	erx_boot_given_t given;
	size_t length;

	if (!erx_boot_device_window(device, &window)) {
		printf("window refused\n");
		return;
	}
	given = erx_boot_device_given(device, &window, facts, WINDOW_HANDLE, LINE_HANDLE, memory_handle);
	length = erx_boot_given_words(&given, words, sizeof(words));
	printf("window %llu %llu %llu words", (unsigned long long)window.base, (unsigned long long)window.size,
	    (unsigned long long)window.offset);
	for (size_t byte = 0; byte < length; byte++)
		putchar(words[byte] == '\0' ? ' ' : words[byte]);
	printf("exact %d short %zu\n", length != 0 && erx_boot_given_words(&given, words, length) == length,
	    length == 0 ? 0 : erx_boot_given_words(&given, words, length - 1));
}

/* The mark a record writes beside its line. */
static const char *
mark(bool shared)
{
	return (shared ? "shared" : "direct");
}

/*
 * Reads a manifest from the file named by its first argument and prints what the boot
 * page takes from it, or the check that refused it. A second argument is a stdout-path to
 * match the console against, and a third, the word hostlink, asks for the host link as
 * erx.hostlink=1 does. boot_manifest_test.rb compares this
 * with the manifest's source. A given device is printed by given_print; a physical one with
 * its words, NULs as spaces, and what erx_boot_device_words returns given exactly their room
 * and one byte less. With the arguments window BASE SIZE, it prints what given_print makes
 * of a block device of that register window and no DMA memory; the modes dma and
 * framebuffer are described where main reads them.
 */
int
main(int argc, char **argv)
{
	static uint8_t bytes[1024 * 1024];
	erx_boot_manifest_t manifest;
	const char *reason;
	bool hostlink;
	FILE *file;
	size_t length;

	if (argc == 4 && strcmp(argv[1], "window") == 0) {
		const erx_boot_device_t device = { .role = "block", .peripheral = "virtio_mmio", .given = true,
		    .base = strtoull(argv[2], NULL, 0), .size = strtoull(argv[3], NULL, 0),
		    .path = { "/virtio_mmio@a003e00", 20 } };

		given_print(&device, NULL, MEMORY_HANDLE);
		return (0);
	}
	/*
	 * dma_range CPU BUS LAST: the translation both gives make a device's memory inside, from
	 * facts with that range (erx_boot_dma_range), as "range CPU BUS LAST" in hexadecimal.
	 */
	if (argc == 5 && strcmp(argv[1], "dma_range") == 0) {
		const erx_dt_device_t facts = { .dma = ERX_DT_DMA_OK, .cpu = strtoull(argv[2], NULL, 0),
		    .bus = strtoull(argv[3], NULL, 0), .last = strtoull(argv[4], NULL, 0) };
		const erx_mem_dma_range_t range = erx_boot_dma_range(&facts);

		printf("range 0x%llx 0x%llx 0x%llx\n", (unsigned long long)range.cpu, (unsigned long long)range.bus,
		    (unsigned long long)range.last);
		return (0);
	}
	/*
	 * dma ROLE MEMORY STATUS COHERENT CPU BUS LAST MAC FIRST SIZE: the root's device step
	 * (liberx/backend/fiasco/runtime_entry.c) for a ROLE device, net or block, of MEMORY
	 * bytes of DMA memory and those facts: whether it asks the tree, the reason
	 * erx_boot_dma_absent gives before the memory is made and, when that is none, again
	 * for memory at FIRST of SIZE bytes, then its record, with memory only when both are
	 * none, then its console line.
	 */
	if (argc == 12 && strcmp(argv[1], "dma") == 0) {
		const erx_boot_device_t device = { .role = argv[2], .peripheral = "virtio_mmio", .given = true,
		    .base = 0x0a003e00, .size = 0x200, .dma_memory = strtoull(argv[3], NULL, 0),
		    .network = strcmp(argv[2], "net") == 0, .path = { "/virtio_mmio@a003e00", 20 } };
		erx_dt_device_t facts = { .dma = (erx_dt_dma_status_t)strtoul(argv[4], NULL, 0),
		    .coherent = strtoul(argv[5], NULL, 0) != 0, .cpu = strtoull(argv[6], NULL, 0),
		    .bus = strtoull(argv[7], NULL, 0), .last = strtoull(argv[8], NULL, 0) };
		const uint64_t mac = strtoull(argv[9], NULL, 0);
		/* The catalogue entry's memory (tree_facts), then the give's check of the memory made. */
		const uint64_t admitted = erx_boot_dma_memory(&facts, device.dma_memory);
		const char *const before = device.dma_memory != 0 && admitted == 0 ? erx_boot_dma_absent(&facts, 0, 0) : NULL;
		const char *const after = admitted != 0 ?
		    erx_boot_dma_absent(&facts, strtoull(argv[10], NULL, 0), strtoull(argv[11], NULL, 0)) : NULL;
		const bool memory = admitted != 0 && after == NULL;
		char line[ERX_BOOT_TREE_LINE_MAX];
		size_t line_length;

		facts.mac_status = mac != 0 ? ERX_DT_MAC_OK : ERX_DT_MAC_NONE;
		for (size_t at = 0; at < ERX_DT_MAC_BYTES; at++)
			facts.mac[at] = (uint8_t)(mac >> (8 * (ERX_DT_MAC_BYTES - 1 - at)));
		printf("asks %d before %s after %s ", erx_boot_row_asks(device.dma_memory, device.network),
		    before != NULL ? before : "none", after != NULL ? after : "none");
		given_print(&device, &facts, memory ? MEMORY_HANDLE : ERX_CAP_NULL);
		line_length = erx_boot_tree_line(device.path, device.dma_memory, device.network, &facts, after, line,
		    sizeof(line));
		printf("line %.*s", (int)line_length, line);
		return (0);
	}
	/*
	 * framebuffer STATUS BASE LENGTH WIDTH HEIGHT STRIDE FORMAT WINDOW_BASE WINDOW_SIZE: the
	 * root's step for a
	 * framebuffer row at /chosen (framebuffer_facts and framebuffer_give,
	 * liberx/backend/fiasco/runtime_entry.c) over facts of that erx_dt_fb_status_t and a
	 * format of that name, "-" for none, in a row of that window: the pages
	 * erx_boot_framebuffer_place places it in, or
	 * none, then the record over them with the window handle above, NULs as spaces, and what
	 * erx_boot_framebuffer_words returns given exactly its room and one byte less, then the
	 * console line.
	 */
	if (argc == 11 && strcmp(argv[1], "framebuffer") == 0) {
		const erx_dt_framebuffer_t fb = { .status = (erx_dt_fb_status_t)strtoul(argv[2], NULL, 0),
		    .base = strtoull(argv[3], NULL, 0), .length = strtoull(argv[4], NULL, 0),
		    .width = (uint32_t)strtoul(argv[5], NULL, 0), .height = (uint32_t)strtoul(argv[6], NULL, 0),
		    .stride = (uint32_t)strtoul(argv[7], NULL, 0) };
		const char *const format = strcmp(argv[8], "-") == 0 ? NULL : argv[8];
		const erx_dt_window_t window = { strtoull(argv[9], NULL, 0), strtoull(argv[10], NULL, 0) };
		const erx_boot_words_t path = { "/chosen", 7 };
		char words[ERX_BOOT_FRAMEBUFFER_WORDS_MAX];
		char line[ERX_BOOT_TREE_LINE_MAX];
		erx_boot_window_t pages = { 0 };

		if (erx_boot_framebuffer_place(&fb, format, window, &pages))
			printf("pages %llu %llu %llu", (unsigned long long)pages.base, (unsigned long long)pages.size,
			    (unsigned long long)pages.offset);
		else
			printf("pages none");
		length = erx_boot_framebuffer_words(&fb, format, WINDOW_HANDLE, pages.offset, words, sizeof(words));
		printf(" words");
		for (size_t byte = 0; byte < length; byte++)
			putchar(words[byte] == '\0' ? ' ' : words[byte]);
		printf("exact %d short %zu\n", length != 0 && erx_boot_framebuffer_words(&fb, format, WINDOW_HANDLE,
		    pages.offset, words, length) == length, length == 0 ? 0 : erx_boot_framebuffer_words(&fb, format,
		    WINDOW_HANDLE, pages.offset, words, length - 1));
		length = erx_boot_framebuffer_line(path, &fb, format, line, sizeof(line));
		printf("line %.*s", (int)length, line);
		return (0);
	}
	if (argc < 2 || argc > 4 || (argc == 4 && strcmp(argv[3], "hostlink") != 0) || (file = fopen(argv[1], "rb")) == NULL)
		return (2);
	hostlink = argc == 4;
	length = fread(bytes, 1, sizeof(bytes), file);
	fclose(file);
	if (!erx_boot_manifest_read(bytes, length, hostlink, &manifest, &reason)) {
		printf("refused %s\n", reason);
		return (1);
	}
	printf("node %.*s\n", (int)manifest.node_len, manifest.node);
	printf("words");
	for (size_t at = 0; at < manifest.system_args.length; at++)
		putchar(manifest.system_args.bytes[at] == '\0' ? ' ' : manifest.system_args.bytes[at]);
	printf("\nlimits %u %u %u %u %llu %llu %u %u %u\n", manifest.limits.max_frame, manifest.limits.max_message_heap,
	    manifest.limits.funnel_depth, manifest.limits.exports, (unsigned long long)manifest.limits.tmp,
	    (unsigned long long)manifest.limits.overlay, manifest.limits.atoms, manifest.limits.foreign_atoms,
	    manifest.limits.processes);
	printf("console_uart %llu %llu %u %s %u\n", (unsigned long long)manifest.console.base,
	    (unsigned long long)manifest.console.size, manifest.console.line, mark(manifest.console.line_shared),
	    manifest.console.clock);
	{
		char words[ERX_BOOT_CONSOLE_WORDS_MAX];
		const size_t length = erx_boot_console_words(&manifest.console, words, sizeof(words));

		printf("console_words");
		for (size_t byte = 0; byte < length; byte++)
			putchar(words[byte] == '\0' ? ' ' : words[byte]);
		printf("exact %d short %zu\n", length != 0 && erx_boot_console_words(&manifest.console, words, length) == length,
		    length == 0 ? 0 : erx_boot_console_words(&manifest.console, words, length - 1));
	}
	printf("console_page %llu\n", (unsigned long long)erx_boot_console_page(&manifest));
	{
		erx_abi_error_t error = { 0 };
		erx_manifest_view_t view;
		uint64_t total;

		if (erx_manifest_open(bytes, length, &view, &error) && erx_boot_manifest_dma_total(&view, &total))
			printf("dma_total %llu\n", (unsigned long long)total);
		else
			printf("dma_total refused\n");
	}
	printf("devices %zu\n", manifest.device_count);
	for (size_t at = 0; at < manifest.device_count; at++) {
		const erx_boot_device_t *device = &manifest.devices[at];
		char words[ERX_BOOT_DEVICE_WORDS_MAX];
		size_t length;

		/* A framebuffer row has no kind: its window, its path and that it has no physical record. */
		if (device->framebuffer) {
			printf("framebuffer %llu %llu %.*s words %zu\n", (unsigned long long)device->base,
			    (unsigned long long)device->size, (int)device->path.length, device->path.bytes,
			    erx_boot_device_words(device, words, sizeof(words)));
			continue;
		}
		printf("device %s %s %llu %llu %u %s %llu %u ", device->role, device->peripheral,
		    (unsigned long long)device->base, (unsigned long long)device->size, device->line,
		    mark(device->line_shared), (unsigned long long)device->dma_memory, device->clock);
		if (device->given) {
			given_print(device, NULL, MEMORY_HANDLE);
			continue;
		}
		length = erx_boot_device_words(device, words, sizeof(words));
		printf("words");
		for (size_t byte = 0; byte < length; byte++)
			putchar(words[byte] == '\0' ? ' ' : words[byte]);
		printf("exact %d short %zu\n", length != 0 && erx_boot_device_words(device, words, length) == length,
		    length == 0 ? 0 : erx_boot_device_words(device, words, length - 1));
	}
	if (argc >= 3)
		printf("console %.*s matches %d\n", (int)manifest.console_path.length,
		    manifest.console_path.bytes,
		    erx_boot_console_matches(&manifest, argv[2], strlen(argv[2])));
	return (0);
}
