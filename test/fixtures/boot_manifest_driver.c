/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/backend/core/boot_manifest.h"

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
given_print(const erx_boot_device_t *device)
{
	char words[ERX_BOOT_GIVEN_WORDS_MAX];
	erx_boot_window_t window;
	erx_boot_given_t given;
	size_t length;

	if (!erx_boot_device_window(device, &window)) {
		printf("window refused\n");
		return;
	}
	given = erx_boot_device_given(device, &window, WINDOW_HANDLE, LINE_HANDLE, MEMORY_HANDLE);
	length = erx_boot_given_words(&given, words, sizeof(words));
	printf("window %llu %llu %llu words", (unsigned long long)window.base, (unsigned long long)window.size,
	    (unsigned long long)window.offset);
	for (size_t byte = 0; byte < length; byte++)
		putchar(words[byte] == '\0' ? ' ' : words[byte]);
	printf("exact %d short %zu\n", length != 0 && erx_boot_given_words(&given, words, length) == length,
	    length == 0 ? 0 : erx_boot_given_words(&given, words, length - 1));
}

/*
 * Reads a manifest from the file named by its first argument and prints what the boot
 * page takes from it, or the check that refused it. A second argument is a stdout-path to
 * match the console against, and a third, the word hostlink, asks for the host link as
 * erx.hostlink=1 does. boot_manifest_test.rb compares this
 * with the manifest's source. A given device is printed by given_print; a physical one with
 * its words, NULs as spaces, and what erx_boot_device_words returns given exactly their room
 * and one byte less. With the arguments window BASE SIZE, it prints what given_print makes
 * of a block device of that register window and no DMA memory.
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
		    .base = strtoull(argv[2], NULL, 0), .size = strtoull(argv[3], NULL, 0) };

		given_print(&device);
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
	printf("devices %zu\n", manifest.device_count);
	for (size_t at = 0; at < manifest.device_count; at++) {
		const erx_boot_device_t *device = &manifest.devices[at];
		char words[ERX_BOOT_DEVICE_WORDS_MAX];
		size_t length;

		printf("device %s %s %llu %llu %u %llu ", device->role, device->peripheral,
		    (unsigned long long)device->base, (unsigned long long)device->size, device->line,
		    (unsigned long long)device->dma_memory);
		if (device->given) {
			given_print(device);
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
