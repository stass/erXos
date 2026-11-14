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
 * plan, the byte giving the memory's size in units of 2 MiB. For the plan the
 * second byte lays the machine out (lay_out names its bits) and the third
 * places the reservation; the archive follows. Every plan accepted is held to the
 * placement's rules, stated again here so a change to its bounds aborts: copies
 * read only from the archive where the plan leaves it and land inside memory,
 * clear of that archive, the first stage, the device tree, the reservation and
 * each other, with a kernel at the unit behind the archive's rounded extent; an
 * archive that moves keeps its size and lands on a page inside memory clear of
 * the first stage, the device tree and the reservation, and moves only when an
 * image that can stay at its link addresses lands on it; the kernel's views lie
 * in the loaded archive where the copies will read them; and the device tree's
 * copy and the handoff page lie inside memory clear of everything, the loaded
 * archive included.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/core/boot_place.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"

#define FUZZ_LOW	0x40000000ULL
/* Memory from 0, as the Raspberry Pi's starts. */
#define FUZZ_ZERO	0ULL
/* Memory from here passes 4 GiB once it holds more than 128 units. */
#define FUZZ_HIGH	0xf0000000ULL
#define FUZZ_STAGE	0x4000ULL
#define FUZZ_RESERVED	0x10000ULL
#define FUZZ_RANGES_MAX	3
#define FUZZ_UNIT	0x200000ULL
#define HEADER		96ULL
#define ENTRY		64ULL
#define PAGE		4096ULL

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * The machine the second and third bytes give: memory from 0, a low or a high
 * base, the first stage 2 MiB into it, memory cut into up to three ranges with a
 * unit between each, at most one reservation, and a device tree of one page or
 * of 1 MiB, as QEMU virt's declares, at the base of memory, at its top, on the
 * page behind the file as QEMU virt puts it, or on the unit behind the file.
 */
struct layout {
	uint64_t	 load;
	erx_boot_range_t memory[FUZZ_RANGES_MAX];
	size_t		 nmemory;
	erx_boot_range_t reserved;
	size_t		 nreserved;
	erx_boot_range_t tree;
};

static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;
static erx_blake3_ctx_t hasher;
static struct layout machine;

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

static uint64_t
pages(uint64_t value)
{
	return ((value + PAGE - 1) / PAGE * PAGE);
}

static bool
meets(uint64_t start, uint64_t size, uint64_t other, uint64_t other_size)
{
	return (start < other + other_size && other < start + size);
}

static bool
inside_memory(uint64_t start, uint64_t size)
{
	for (size_t index = 0; index < machine.nmemory; index++) {
		const erx_boot_range_t *memory = &machine.memory[index];

		if (start >= memory->start && start + size <= memory->start + memory->size)
			return (true);
	}
	return (false);
}

/* What every place keeps clear of: the first stage, the tree, the reservation. */
static bool
meets_held(uint64_t start, uint64_t size)
{
	return (meets(start, size, machine.load, FUZZ_STAGE) ||
	    meets(start, size, machine.tree.start & ~(PAGE - 1),
	    pages(machine.tree.start + machine.tree.size) -
	    (machine.tree.start & ~(PAGE - 1))) ||
	    (machine.nreserved != 0 && meets(start, size, machine.reserved.start,
	    machine.reserved.size)));
}

/* A view inside the kernel's copies, at the offset in the loaded archive they read. */
static void
check_view(erx_boot_range_t view, uint64_t loaded)
{
	if (loaded < plan.archive_loaded.start ||
	    loaded - plan.archive_loaded.start > plan.archive_loaded.size ||
	    view.size > plan.archive_loaded.size - (loaded - plan.archive_loaded.start))
		abort();
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];

		if (view.start >= copy->target &&
		    view.start + view.size <= copy->target + copy->file_size) {
			if (loaded - plan.archive_loaded.start !=
			    copy->source - plan.archive.start + (view.start - copy->target))
				abort();
			return;
		}
	}
	abort();
}

static void
check_plan(uint64_t file_length)
{
	const uint64_t archive_end = plan.archive.start + plan.archive.size;
	const uint64_t archive_pages = pages(archive_end);
	const uint64_t loaded_pages = pages(plan.archive_loaded.start +
	    plan.archive_loaded.size) - plan.archive_loaded.start;
	const bool moved = plan.archive.start != plan.archive_loaded.start;
	const erx_boot_placed_t root = plan.has_stand_in_root ?
	    plan.stand_in_root : (erx_boot_placed_t){0};
	const erx_boot_placed_t images[] = { plan.kernel, plan.sigma0, root };
	const erx_boot_range_t places[] = { plan.tree_copy,
	    { .start = plan.handoff_page, .size = PAGE } };

	if (plan.kip.start < plan.kernel.start ||
	    plan.kip.start + plan.kip.size > plan.kernel.start + plan.kernel.size ||
	    plan.koptions.start < plan.kernel.start ||
	    plan.koptions.start + plan.koptions.size >
	    plan.kernel.start + plan.kernel.size)
		abort();
	check_view(plan.kip, plan.kip_loaded);
	check_view(plan.koptions, plan.koptions_loaded);
	if (plan.archive_loaded.start != machine.load + FUZZ_STAGE ||
	    plan.archive_loaded.size != file_length - FUZZ_STAGE ||
	    plan.archive.size != plan.archive_loaded.size)
		abort();
	if (moved && (plan.archive.start % PAGE != 0 ||
	    !inside_memory(plan.archive.start, archive_pages - plan.archive.start) ||
	    meets_held(plan.archive.start, archive_pages - plan.archive.start)))
		abort();
	/* Only the root or sigma0 can stay at its link addresses and so force it. */
	if (moved && !meets(plan.sigma0.start, plan.sigma0.size,
	    plan.archive_loaded.start, loaded_pages) &&
	    !meets(root.start, root.size, plan.archive_loaded.start, loaded_pages))
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
		if (!inside_memory(copy->target, copy->mem_size) ||
		    meets_held(copy->target, copy->mem_size) ||
		    meets(copy->target, copy->mem_size, plan.archive.start,
		    archive_pages - plan.archive.start))
			abort();
		for (uint32_t other = 0; other < index; other++) {
			const erx_boot_copy_t *earlier = &plan.copies[other];

			if (meets(copy->target, copy->mem_size, earlier->target,
			    earlier->mem_size))
				abort();
		}
	}
	if (plan.tree_copy.size != pages(machine.tree.size))
		abort();
	for (size_t index = 0; index < 2; index++) {
		const uint64_t start = places[index].start, size = places[index].size;

		/* Past the first page, which bootstrap's allocator never gives. */
		if (start % PAGE != 0 || start < PAGE || !inside_memory(start, size) ||
		    meets_held(start, size) ||
		    meets(start, size, plan.archive.start,
		    archive_pages - plan.archive.start) ||
		    meets(start, size, plan.archive_loaded.start, loaded_pages))
			abort();
		for (size_t image = 0; image < 3; image++)
			if (meets(start, size, images[image].start, images[image].size))
				abort();
	}
	if (meets(places[0].start, places[0].size, places[1].start, places[1].size))
		abort();
}

/*
 * The machine from the layout byte and the reservation byte. The layout's bits:
 * 0, memory from FUZZ_HIGH; 1-2, one more memory range for each, up to three;
 * 3, a reservation the reservation byte places in MiB past the base; 4-5, where
 * the device tree lies; 6, memory from 0, over bit 0; 7, a tree of 1 MiB.
 */
static void
lay_out(uint8_t units, uint8_t layout, uint8_t reservation, uint64_t file_length)
{
	const uint64_t total = (uint64_t)units * FUZZ_UNIT;
	uint64_t base, file_end;

	if ((layout & 0x40) != 0)
		base = FUZZ_ZERO;
	else if ((layout & 1) != 0)
		base = FUZZ_HIGH;
	else
		base = FUZZ_LOW;
	file_end = base + FUZZ_UNIT + file_length;

	machine = (struct layout){ .load = base + FUZZ_UNIT };
	machine.nmemory = 1 + (layout >> 1 & 3) % FUZZ_RANGES_MAX;
	for (size_t index = 0; index < machine.nmemory; index++) {
		const uint64_t piece = total / machine.nmemory / PAGE * PAGE;

		machine.memory[index] = (erx_boot_range_t){
		    .start = base + index * (piece + FUZZ_UNIT), .size = piece };
	}
	if ((layout & 8) != 0) {
		machine.reserved = (erx_boot_range_t){
		    .start = base + (uint64_t)reservation * 0x100000, .size = FUZZ_RESERVED };
		machine.nreserved = 1;
	}
	switch (layout >> 4 & 3) {
	case 0:
		machine.tree.start = base;
		break;
	case 1:
		machine.tree.start = base + total - PAGE;
		break;
	case 2:
		machine.tree.start = pages(file_end);
		break;
	default:
		machine.tree.start = (file_end + FUZZ_UNIT - 1) / FUZZ_UNIT * FUZZ_UNIT;
		break;
	}
	machine.tree.size = (layout & 0x80) != 0 ? 0x100000 : PAGE;
}

int
LLVMFuzzerTestOneInput(const uint8_t *input, size_t size)
{
	erx_boot_load_request_t request = {0};
	erx_boot_error_t error = {0};
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
	if (size <= 3)
		return (0);
	archive_length = pages(size - 3);
	single = calloc(1, (size_t)FUZZ_STAGE + archive_length);
	if (single == NULL)
		return (0);
	memcpy(single + FUZZ_STAGE, input + 3, size - 3);
	fix_hashes(single + FUZZ_STAGE, archive_length);
	memcpy(single, "ERXBOOT\0", 8);
	single[8] = 1;
	for (size_t index = 0; index < 8; index++) {
		single[16 + index] = (uint8_t)(FUZZ_STAGE >> (8 * index));
		single[24 + index] = (uint8_t)((uint64_t)archive_length >> (8 * index));
	}
	lay_out(input[0], input[1], input[2], FUZZ_STAGE + archive_length);
	request.locator = single;
	request.load = machine.load;
	request.linked_end = FUZZ_STAGE;
	request.declared_size = FUZZ_STAGE + archive_length;
	request.device_tree = machine.tree;
	request.memory = machine.memory;
	request.nmemory = machine.nmemory;
	request.reserved = &machine.reserved;
	request.nreserved = machine.nreserved;
	request.koptions_min = 256;
	request.window = single;
	request.window_start = machine.load;
	request.window_size = FUZZ_STAGE + archive_length;
	if (erx_boot_load_plan(&request, &workspace, &plan, &error))
		check_plan(FUZZ_STAGE + archive_length);
	free(single);
	return (0);
}
