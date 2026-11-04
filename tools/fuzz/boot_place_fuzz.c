/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel profile of the ELF reader over raw bytes, and erx_boot_load_plan
 * over a whole first stage and archive, with the index and file hashes fixed up
 * so mutations reach the file checks, the reader and the placement.
 *
 * The first input byte picks the target: 0, the reader alone; otherwise the
 * plan, the byte giving the memory's size in units of 2 MiB. Every plan accepted
 * must copy only from the archive, to targets inside memory and clear of the
 * archive, the first stage and each other, with a kernel at the unit behind the
 * archive's rounded extent: the placement's rules stated again here, so a change
 * to its bounds aborts.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/core/boot_place.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"

#define FUZZ_LOAD	0x40200000ULL
#define FUZZ_MEMORY	0x40000000ULL
#define FUZZ_STAGE	0x4000ULL
#define FUZZ_UNIT	0x200000ULL
#define HEADER		96ULL
#define ENTRY		64ULL
#define PAGE		4096ULL

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;
static erx_blake3_ctx_t hasher;

static uint64_t
read_le(const uint8_t *bytes, size_t width)
{
	uint64_t value = 0;

	for (size_t index = 0; index < width; index++)
		value |= (uint64_t)bytes[index] << (8 * index);
	return (value);
}

static void
digest(const uint8_t *bytes, size_t length, uint8_t *out)
{
	erx_blake3_init(&hasher);
	erx_blake3_update(&hasher, bytes, length);
	erx_blake3_final(&hasher, out);
}

/* Field values are read as stored; only what lies inside gets a hash. */
static void
fix_hashes(uint8_t *bytes, size_t length)
{
	uint64_t count, index_end, start, stop;

	if (length < HEADER)
		return;
	count = read_le(bytes + 24, 4);
	for (uint64_t index = 0; index < count && HEADER + (index + 1) * ENTRY <= length;
	    index++) {
		uint8_t *entry = bytes + HEADER + index * ENTRY;

		start = read_le(entry + 8, 8);
		stop = read_le(entry + 16, 8);
		if (start > length || stop > length - start)
			continue;
		stop = (start + stop + PAGE - 1) / PAGE * PAGE;
		digest(bytes + start, (size_t)((stop > length ? length : stop) - start),
		    entry + 32);
	}
	index_end = read_le(bytes + 40, 8) + read_le(bytes + 48, 4);
	if (index_end < read_le(bytes + 40, 8))
		return;
	index_end = (index_end + PAGE - 1) / PAGE * PAGE;
	if (index_end > length)
		index_end = length;
	memset(bytes + 64, 0, ERX_PACK_HASH_SIZE);
	digest(bytes, (size_t)index_end, bytes + 64);
}

static void
check_plan(const erx_boot_range_t *memory, uint64_t file_length)
{
	const uint64_t archive_end = plan.archive.start + plan.archive.size;

	if (plan.kip.start < plan.kernel.start ||
	    plan.kip.start + plan.kip.size > plan.kernel.start + plan.kernel.size ||
	    plan.koptions.start < plan.kernel.start ||
	    plan.koptions.start + plan.koptions.size >
	    plan.kernel.start + plan.kernel.size)
		abort();
	if (plan.archive.start != FUZZ_LOAD + FUZZ_STAGE ||
	    plan.archive.size != file_length - FUZZ_STAGE)
		abort();
	if (plan.kernel.start / FUZZ_UNIT * FUZZ_UNIT <
	    (archive_end + FUZZ_UNIT - 1) / FUZZ_UNIT * FUZZ_UNIT)
		abort();
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];

		if (copy->source < plan.archive.start || copy->source > archive_end ||
		    copy->file_size > archive_end - copy->source ||
		    copy->file_size > copy->mem_size)
			abort();
		if (copy->target < memory->start ||
		    copy->target + copy->mem_size > memory->start + memory->size)
			abort();
		if (copy->target < archive_end &&
		    copy->target + copy->mem_size > FUZZ_LOAD)
			abort();
		/* The device tree, at the base of memory. */
		if (copy->target < FUZZ_MEMORY + PAGE)
			abort();
		for (uint32_t other = 0; other < index; other++) {
			const erx_boot_copy_t *earlier = &plan.copies[other];

			if (copy->target < earlier->target + earlier->mem_size &&
			    earlier->target < copy->target + copy->mem_size)
				abort();
		}
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	erx_boot_load_request_t request = {0};
	erx_boot_error_t error = {0};
	erx_boot_range_t memory;
	erx_elf_kernel_plan_t kernel;
	erx_elf_kernel_views_t views = { .kip_min = 4096, .koptions_min = 256 };
	uint8_t *single;
	size_t archive_length;

	if (size == 0)
		return (0);
	if (input[0] == 0) {
		erx_elf_error_t elf_error = {0};

		(void)erx_elf_plan_kernel(input + 1, size - 1, &views, &kernel, &elf_error);
		(void)erx_elf_plan_kernel(input + 1, size - 1, NULL, &kernel, &elf_error);
		return (0);
	}
	archive_length = (size - 1 + PAGE - 1) / PAGE * PAGE;
	if (archive_length == 0)
		return (0);
	single = calloc(1, (size_t)FUZZ_STAGE + archive_length);
	if (single == NULL)
		return (0);
	memcpy(single + FUZZ_STAGE, input + 1, size - 1);
	fix_hashes(single + FUZZ_STAGE, archive_length);
	memcpy(single, "ERXBOOT\0", 8);
	single[8] = 1;
	for (size_t index = 0; index < 8; index++) {
		single[16 + index] = (uint8_t)(FUZZ_STAGE >> (8 * index));
		single[24 + index] = (uint8_t)((uint64_t)archive_length >> (8 * index));
	}
	memory = (erx_boot_range_t){ .start = FUZZ_MEMORY,
	    .size = (uint64_t)input[0] * FUZZ_UNIT };
	request.locator = single;
	request.load = FUZZ_LOAD;
	request.linked_end = FUZZ_STAGE;
	request.declared_size = FUZZ_STAGE + archive_length;
	request.device_tree = (erx_boot_range_t){ .start = FUZZ_MEMORY, .size = PAGE };
	request.memory = &memory;
	request.nmemory = 1;
	request.koptions_min = 256;
	request.window = single;
	request.window_start = FUZZ_LOAD;
	request.window_size = FUZZ_STAGE + archive_length;
	if (erx_boot_load_plan(&request, &workspace, &plan, &error))
		check_plan(&memory, FUZZ_STAGE + archive_length);
	free(single);
	return (0);
}
