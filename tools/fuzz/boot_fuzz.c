/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_locate over arbitrary locators, declared sizes and memory maps.
 * The input is the 32-byte locator, then little-endian u64 values: load,
 * linked end, declared size, a flags word (bit 0: an initrd), the initrd's
 * start and size, the device tree's start and size, a memory-range count
 * and a reserved-range count (each taken modulo 5), then the ranges; bytes
 * past the end read as zero. An accepted archive must start on a page, lie
 * inside one memory range and meet no reserved range, the device tree or
 * the first stage, and be what the locator or the initrd names: the
 * locator's rules are stated again here, in subtraction form, so a change
 * to the code's bounds aborts (test/host/boot_file_test.rb seeds one).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/pack.h"

#define RANGES_MAX 4

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint64_t
take(const uint8_t *bytes, size_t length, size_t *cursor)
{
	uint64_t value;

	value = 0;
	for (unsigned byte = 0; byte < 8; byte++, (*cursor)++) {
		if (*cursor < length)
			value |= (uint64_t)bytes[*cursor] << (8 * byte);
	}
	return (value);
}

static erx_boot_range_t
take_range(const uint8_t *bytes, size_t length, size_t *cursor)
{
	erx_boot_range_t range;

	range.start = take(bytes, length, cursor);
	range.size = take(bytes, length, cursor);
	return (range);
}

static int
inside(erx_boot_range_t inner, erx_boot_range_t outer)
{
	return (inner.start >= outer.start && outer.size >= inner.size &&
	    inner.start - outer.start <= outer.size - inner.size);
}

static int
meets(erx_boot_range_t left, erx_boot_range_t right)
{
	return (left.size != 0 && right.size != 0 &&
	    left.start < right.start + right.size &&
	    right.start < left.start + left.size);
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_boot_range_t memory[RANGES_MAX], reserved[RANGES_MAX], result;
	erx_boot_inputs_t inputs;
	erx_pack_error_t error;
	uint8_t locator[ERX_BOOT_LOCATOR_SIZE];
	erx_boot_range_t stage;
	uint64_t archive_off, archive_size;
	size_t cursor;
	int found;

	memset(locator, 0, sizeof(locator));
	memcpy(locator, bytes, length < sizeof(locator) ? length : sizeof(locator));
	cursor = sizeof(locator);
	inputs = (erx_boot_inputs_t){ .locator = locator };
	inputs.load = take(bytes, length, &cursor);
	inputs.linked_end = take(bytes, length, &cursor);
	inputs.declared_size = take(bytes, length, &cursor);
	inputs.has_initrd = (take(bytes, length, &cursor) & 1) != 0;
	inputs.initrd = take_range(bytes, length, &cursor);
	inputs.device_tree = take_range(bytes, length, &cursor);
	inputs.nmemory = take(bytes, length, &cursor) % (RANGES_MAX + 1);
	inputs.nreserved = take(bytes, length, &cursor) % (RANGES_MAX + 1);
	for (size_t index = 0; index < inputs.nmemory; index++)
		memory[index] = take_range(bytes, length, &cursor);
	for (size_t index = 0; index < inputs.nreserved; index++)
		reserved[index] = take_range(bytes, length, &cursor);
	inputs.memory = memory;
	inputs.reserved = reserved;
	result = (erx_boot_range_t){ .start = 1, .size = 1 };
	if (!erx_boot_locate(&inputs, &result, &error)) {
		if (error.reason == NULL || result.start != 1 || result.size != 1)
			abort();
		return (0);
	}
	if (result.size == 0 || result.start % ERX_PAGE_SIZE != 0 ||
	    result.start > UINT64_MAX - result.size ||
	    meets(result, inputs.device_tree))
		abort();
	found = 0;
	for (size_t index = 0; index < inputs.nmemory; index++)
		found |= inside(result, memory[index]);
	for (size_t index = 0; index < inputs.nreserved; index++) {
		if (reserved[index].start <= UINT64_MAX - reserved[index].size &&
		    meets(result, reserved[index]))
			abort();
	}
	if (!found || (inputs.has_initrd && (result.start != inputs.initrd.start ||
	    result.size != inputs.initrd.size)))
		abort();
	stage = (erx_boot_range_t){ .start = inputs.load,
	    .size = inputs.linked_end };
	cursor = 16;
	archive_off = take(locator, sizeof(locator), &cursor);
	archive_size = take(locator, sizeof(locator), &cursor);
	if (meets(result, stage) || (archive_off == 0) != inputs.has_initrd)
		abort();
	if (archive_off != 0 && (archive_off % ERX_PAGE_SIZE != 0 ||
	    archive_off < inputs.linked_end ||
	    archive_off > inputs.declared_size ||
	    archive_size > inputs.declared_size - archive_off ||
	    inputs.load > UINT64_MAX - archive_off ||
	    result.start != inputs.load + archive_off ||
	    result.size != archive_size))
		abort();
	return (0);
}
