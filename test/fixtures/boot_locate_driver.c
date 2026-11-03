/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * boot-locate FILE LOAD LINKED_END [KIND START SIZE]...: erx_boot_locate over
 * the locator and declared size in FILE, a first stage or a single file.
 * KIND is initrd, tree, memory or reserved. Prints "ok START SIZE" in
 * hexadecimal, or "error REASON". Numbers take any strtoull base.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi_reader.h"
#include "erx/pack.h"
#include "input.h"

#define RANGES_MAX 8

int
main(int argc, char **argv)
{
	erx_boot_range_t memory[RANGES_MAX], reserved[RANGES_MAX], range, result;
	erx_arch_boot_header_t header;
	erx_boot_inputs_t inputs;
	erx_pack_error_t error;
	uint8_t *bytes;
	size_t length, nmemory, nreserved;

	if (argc < 4 || (argc - 4) % 3 != 0)
		return (2);
	bytes = erx_host_input_read(argv[1], &length);
	if (bytes == NULL || !erx_arch_boot_header_decode(bytes, length, &header) ||
	    length < ERX_ARCH_BOOT_LOCATOR_OFFSET + ERX_BOOT_LOCATOR_SIZE)
		return (2);
	inputs = (erx_boot_inputs_t){
		.locator = bytes + ERX_ARCH_BOOT_LOCATOR_OFFSET,
		.load = strtoull(argv[2], NULL, 0),
		.linked_end = strtoull(argv[3], NULL, 0),
		.declared_size = header.image_size,
	};
	nmemory = 0;
	nreserved = 0;
	for (int index = 4; index < argc; index += 3) {
		range.start = strtoull(argv[index + 1], NULL, 0);
		range.size = strtoull(argv[index + 2], NULL, 0);
		if (strcmp(argv[index], "initrd") == 0) {
			inputs.has_initrd = true;
			inputs.initrd = range;
		} else if (strcmp(argv[index], "tree") == 0) {
			inputs.device_tree = range;
		} else if (strcmp(argv[index], "memory") == 0 &&
		    nmemory < RANGES_MAX) {
			memory[nmemory++] = range;
		} else if (strcmp(argv[index], "reserved") == 0 &&
		    nreserved < RANGES_MAX) {
			reserved[nreserved++] = range;
		} else {
			return (2);
		}
	}
	inputs.memory = memory;
	inputs.nmemory = nmemory;
	inputs.reserved = reserved;
	inputs.nreserved = nreserved;
	if (erx_boot_locate(&inputs, &result, &error))
		printf("ok %llx %llx\n", (unsigned long long)result.start,
		    (unsigned long long)result.size);
	else
		printf("error %s\n", error.reason);
	free(bytes);
	return (0);
}
