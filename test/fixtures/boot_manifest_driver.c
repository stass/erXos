/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdio.h>
#include <stdlib.h>

#include "liberx/backend/core/boot_manifest.h"

/*
 * Reads a manifest from the file named by its one argument and prints what the boot
 * page takes from it, or the check that refused it. boot_manifest_test.rb compares this
 * with the manifest's source.
 */
int
main(int argc, char **argv)
{
	static uint8_t bytes[1024 * 1024];
	erx_boot_manifest_t manifest;
	const char *reason;
	FILE *file;
	size_t length;

	if (argc != 2 || (file = fopen(argv[1], "rb")) == NULL)
		return (2);
	length = fread(bytes, 1, sizeof(bytes), file);
	fclose(file);
	if (!erx_boot_manifest_read(bytes, length, &manifest, &reason)) {
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
	return (0);
}
