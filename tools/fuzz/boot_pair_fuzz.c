/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot pair bootstrap derives from /chosen/bootloader's partition and
 * tryboot properties. The first input byte shapes the two properties: its low
 * three bits are the partition's length and the next three the tryboot's, bit
 * 6 leaves the partition out and bit 7 the tryboot; their bytes follow. Each
 * property gets a heap block of its exact length, so a read past it is a
 * report. Every pair must be one a reader accepts, and must be the one the
 * rule gives, stated again here so a change to the derivation aborts.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/core/boot_place.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* A property's own block, NULL when it is left out or the input runs short. */
static uint8_t *
property(const uint8_t *data, size_t size, size_t *at, size_t length, int absent)
{
	uint8_t *block;

	if (absent || length > size - *at)
		return (NULL);
	block = malloc(length == 0 ? 1 : length);
	if (block == NULL)
		abort();
	memcpy(block, data + *at, length);
	*at += length;
	return (block);
}

static uint32_t
cell(const uint8_t *bytes)
{
	return ((uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
	    (uint32_t)bytes[2] << 8 | bytes[3]);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	size_t at = 1, partition_len, tryboot_len;
	uint8_t *partition, *tryboot;
	uint32_t value = ERX_BOOT_VALUE_UNKNOWN, slot = ERX_BOOT_SLOT_NONE;
	erx_boot_pair_t pair;

	if (size < 1)
		return (0);
	partition_len = data[0] & 7;
	tryboot_len = (data[0] >> 3) & 7;
	partition = property(data, size, &at, partition_len, data[0] & 0x40);
	tryboot = property(data, size, &at, tryboot_len, data[0] & 0x80);
	pair = erx_boot_pair_derive(partition, partition_len, tryboot, tryboot_len);

	if (partition != NULL && tryboot != NULL && partition_len == 4 && tryboot_len == 4 &&
	    (cell(partition) == ERX_MEDIUM_SLOT_A_PARTITION || cell(partition) == ERX_MEDIUM_SLOT_B_PARTITION) &&
	    cell(tryboot) <= 1) {
		value = cell(tryboot) == 1 ? ERX_BOOT_VALUE_TRIAL : ERX_BOOT_VALUE_NORMAL;
		slot = cell(partition) == ERX_MEDIUM_SLOT_A_PARTITION ? ERX_BOOT_SLOT_A : ERX_BOOT_SLOT_B;
	}
	if (!erx_boot_pair_valid(pair.value, pair.slot) || pair.value != value || pair.slot != slot)
		abort();
	free(partition);
	free(tryboot);
	return (0);
}
