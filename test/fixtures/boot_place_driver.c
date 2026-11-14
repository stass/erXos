/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Drives the boot path's two cores for test/host/boot_place_test.rb.
 *
 * plan FILE LOAD LINKED_END MEMORY_START MEMORY_SIZE [RESERVED_START RESERVED_SIZE]:
 * runs erx_boot_load_plan
 * over FILE as a single bootable file placed at LOAD, with the device tree at
 * the top of memory, and prints the plan or the refusal. A copy's source is
 * printed as its offset in the archive at the place the plan leaves it, and the
 * kernel's views where the loader left the archive as their offsets there.
 *
 * apply, with plan's arguments: plans over a buffer that stands for the whole
 * of memory, with FILE at LOAD, prints the plan, then applies it as bootstrap
 * does: first fills the device tree's copy and the handoff page, as bootstrap
 * writes them before anything moves, then the archive's move as memmove and
 * then the copies, and prints "applied" when the archive at its final place,
 * every copy and both views hold the bytes the file gave them and the two
 * places their fill; otherwise it aborts.
 *
 * handoff FILE: accepts FILE's bytes as a record and prints what it holds.
 * write VALUE SLOT: writes a record with that boot pair, then accepts it and
 * prints what it holds, or "unwritten".
 * pair PARTITION TRYBOOT: derives the boot pair from the two properties' bytes,
 * each in hex, or - when absent, and prints it.
 * args LIMIT TEXT: prints TEXT's length cut at LIMIT.
 * lines START SIZE LINE: prints the cache lines erx_cache_lines gives for the
 * range, as their first address and end, or "wraps".
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/boot_handoff.h"
#include "erx/core/boot_place.h"
#include "erx/core/cache_lines.h"

#define DEVICE_TREE_SIZE 0x2000

_Alignas(8) static uint8_t record[ERX_BOOT_HANDOFF_RECORD_SIZE];
static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;
/* Identification words a writer stores and a reader gives back in order. */
static const uint64_t cpu_id[ERX_BOOT_CPU_ID_COUNT] = { 0x1010, 0x2020, 0x3030, 0x4040, 0x5050, 0x6060, 0x7070, 0x8080 };

static uint8_t *
read_file(const char *path, size_t *length)
{
	FILE *file = fopen(path, "rb");
	uint8_t *bytes;
	long size;

	if (file == NULL || fseek(file, 0, SEEK_END) != 0 ||
	    (size = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0)
		exit(2);
	bytes = malloc((size_t)size + 1);
	if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size)
		exit(2);
	fclose(file);
	*length = (size_t)size;
	return (bytes);
}

static void
print_placed(const char *name, erx_boot_placed_t placed)
{
	printf("%s %" PRIx64 " %" PRIx64 " %" PRIx64 "\n", name, placed.start,
	    placed.size, placed.entry);
}

#define VIEW_CHECKED 16
#define PLACE_FILL 0x5a

/* Whether size bytes at bytes all hold value. */
static bool
filled(const uint8_t *bytes, uint64_t size, uint8_t value)
{
	for (uint64_t at = 0; at < size; at++)
		if (bytes[at] != value)
			return (false);
	return (true);
}

/*
 * The plan applied to ram, which stands for memory from base, and checked
 * against archive, the archive's bytes as the file gave them.
 */
static void
apply_plan(uint8_t *ram, uint64_t base, const uint8_t *archive)
{
	uint8_t kip[VIEW_CHECKED], koptions[VIEW_CHECKED];

	memcpy(kip, ram + (plan.kip_loaded - base), sizeof(kip));
	memcpy(koptions, ram + (plan.koptions_loaded - base), sizeof(koptions));
	memset(ram + (plan.tree_copy.start - base), PLACE_FILL, plan.tree_copy.size);
	memset(ram + (plan.handoff_page - base), PLACE_FILL, 0x1000);
	memmove(ram + (plan.archive.start - base),
	    ram + (plan.archive_loaded.start - base), plan.archive.size);
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];

		memcpy(ram + (copy->target - base), ram + (copy->source - base),
		    copy->file_size);
		memset(ram + (copy->target - base) + copy->file_size, 0,
		    copy->mem_size - copy->file_size);
	}
	if (memcmp(ram + (plan.archive.start - base), archive,
	    plan.archive.size) != 0)
		abort();
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];
		const uint8_t *target = ram + (copy->target - base);

		if (memcmp(target, archive + (copy->source - plan.archive.start),
		    copy->file_size) != 0)
			abort();
		if (!filled(target + copy->file_size, copy->mem_size - copy->file_size, 0))
			abort();
	}
	if (!filled(ram + (plan.tree_copy.start - base), plan.tree_copy.size,
	    PLACE_FILL) || !filled(ram + (plan.handoff_page - base), 0x1000, PLACE_FILL))
		abort();
	if (memcmp(ram + (plan.kip.start - base), kip, sizeof(kip)) != 0 ||
	    memcmp(ram + (plan.koptions.start - base), koptions,
	    sizeof(koptions)) != 0)
		abort();
	printf("applied\n");
}

static int
run_plan(char **argv, bool apply)
{
	erx_boot_error_t error = {0};
	erx_boot_load_request_t request = {0};
	erx_boot_range_t memory, reserved = {0};
	size_t length;
	uint8_t *file = read_file(argv[0], &length);
	uint8_t *ram = NULL;

	memory = (erx_boot_range_t){ .start = strtoull(argv[3], NULL, 0),
	    .size = strtoull(argv[4], NULL, 0) };
	request.locator = file + 64;
	request.load = strtoull(argv[1], NULL, 0);
	request.linked_end = strtoull(argv[2], NULL, 0);
	memcpy(&request.declared_size, file + 16, sizeof(request.declared_size));
	request.device_tree = (erx_boot_range_t){
	    .start = memory.start + memory.size - DEVICE_TREE_SIZE,
	    .size = DEVICE_TREE_SIZE };
	if (argv[5] != NULL) {
		reserved = (erx_boot_range_t){ .start = strtoull(argv[5], NULL, 0),
		    .size = strtoull(argv[6], NULL, 0) };
		request.reserved = &reserved;
		request.nreserved = 1;
	}
	request.memory = &memory;
	request.nmemory = 1;
	request.koptions_min = 256;
	request.window = file;
	request.window_start = request.load;
	request.window_size = length;
	if (apply) {
		if (request.load < memory.start || request.load - memory.start > memory.size ||
		    length > memory.size - (request.load - memory.start) ||
		    (ram = calloc(1, (size_t)memory.size)) == NULL)
			exit(2);
		memcpy(ram + (request.load - memory.start), file, length);
		request.window = ram;
		request.window_start = memory.start;
		request.window_size = memory.size;
	}
	if (!erx_boot_load_plan(&request, &workspace, &plan, &error)) {
		printf("refused %s %s\n", error.path == NULL ? "-" : error.path,
		    error.reason);
		free(ram);
		free(file);
		return (0);
	}
	printf("archive %" PRIx64 " %" PRIx64 "\n", plan.archive.start,
	    plan.archive.size);
	printf("loaded %" PRIx64 " %" PRIx64 "\n", plan.archive_loaded.start,
	    plan.archive_loaded.size);
	print_placed("kernel", plan.kernel);
	print_placed("sigma0", plan.sigma0);
	if (plan.has_stand_in_root)
		print_placed("root", plan.stand_in_root);
	printf("kip %" PRIx64 " %" PRIx64 "\n", plan.kip.start, plan.kip.size);
	printf("koptions %" PRIx64 " %" PRIx64 "\n", plan.koptions.start,
	    plan.koptions.size);
	printf("views %" PRIx64 " %" PRIx64 "\n",
	    plan.kip_loaded - plan.archive_loaded.start,
	    plan.koptions_loaded - plan.archive_loaded.start);
	printf("tree %" PRIx64 " %" PRIx64 "\n", plan.tree_copy.start,
	    plan.tree_copy.size);
	printf("handoff %" PRIx64 " 1000\n", plan.handoff_page);
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];

		/*
		 * A copy reads the archive where the plan leaves it, moved or
		 * not; its offset there is printed.
		 */
		if (copy->source < plan.archive.start ||
		    copy->source - plan.archive.start > plan.archive.size ||
		    copy->file_size > plan.archive.size -
		    (copy->source - plan.archive.start))
			abort();
		printf("copy %" PRIx64 " %" PRIx64 " %" PRIx64 " %" PRIx64 "\n",
		    copy->source - plan.archive.start, copy->target,
		    copy->file_size, copy->mem_size);
	}
	if (!erx_boot_handoff_write(&plan, "erx.a=1", 7, "/pl011@9000000", 14,
	    (erx_boot_pair_t){ .value = ERX_BOOT_VALUE_UNKNOWN, .slot = ERX_BOOT_SLOT_NONE },
	    (erx_boot_range_t){ .start = 0x48000000, .size = 0x2000 }, cpu_id, record, sizeof(record)))
		abort();
	fwrite(record, 1, 48, stdout);
	printf("\n");
	if (apply)
		apply_plan(ram, memory.start,
		    file + (plan.archive_loaded.start - request.load));
	free(ram);
	free(file);
	return (0);
}

static void
print_accepted(size_t length)
{
	erx_boot_handoff_view_t view;
	const char *reason;
	erx_boot_range_t range;
	bool covered;

	reason = erx_boot_handoff_accept(record, length, &view);
	if (reason != NULL) {
		printf("refused %s\n", reason);
		return;
	}
	range = (erx_boot_range_t){ .start = view.image.start, .size = view.image.size };
	covered = erx_boot_handoff_covered(&view, &range, 1);
	range.size -= 1;
	printf("flags %" PRIx32 " development %d test_code %d image %" PRIx64
	    " %" PRIx64 " bootargs %.*s stdout %.*s covered %d %d boot %" PRIu32
	    " %" PRIu32 " tree %" PRIx64 " %" PRIx64 "\n", view.flags, view.development, view.test_code,
	    view.image.start, view.image.size, (int)view.bootargs_len, view.bootargs,
	    (int)view.stdout_path_len, view.stdout_path, covered,
	    erx_boot_handoff_covered(&view, &range, 1), view.boot.value, view.boot.slot,
	    view.tree.start, view.tree.size);
	printf("cpu_id");
	for (size_t index = 0; index < ERX_BOOT_CPU_ID_COUNT; index++)
		printf(" %" PRIx64, view.cpu_id[index]);
	printf("\n");
}

static int
run_handoff(char **argv)
{
	size_t length;
	uint8_t *file = read_file(argv[0], &length);

	memcpy(record, file, length < sizeof(record) ? length : sizeof(record));
	print_accepted(length);
	free(file);
	return (0);
}

static int
run_write(char **argv)
{
	const erx_boot_pair_t boot = { .value = (uint32_t)strtoul(argv[0], NULL, 0),
	    .slot = (uint32_t)strtoul(argv[1], NULL, 0) };

	plan.flags = 1;
	plan.archive = (erx_boot_range_t){ .start = 0x40204000, .size = 0x8000 };
	memset(record, 0xa5, sizeof(record));
	if (!erx_boot_handoff_write(&plan, "erx.a=1", 7, "/pl011@9000000", 14, boot,
	    (erx_boot_range_t){ .start = 0x48000000, .size = 0x2000 }, cpu_id, record, sizeof(record))) {
		/* A refused write leaves the record as it was. */
		for (size_t index = 0; index < sizeof(record); index++)
			if (record[index] != 0xa5)
				abort();
		printf("unwritten\n");
		return (0);
	}
	print_accepted(sizeof(record));
	return (0);
}

/*
 * A property's bytes from hex into buffer one byte past its alignment, since
 * a device tree aligns a property only to 4; NULL for "-".
 */
static const uint8_t *
property(const char *hex, uint8_t buffer[static 17], size_t *length)
{
	const size_t digits = strlen(hex);

	*length = 0;
	if (strcmp(hex, "-") == 0)
		return (NULL);
	if (digits % 2 != 0 || digits / 2 > 16)
		exit(2);
	for (size_t index = 0; index < digits / 2; index++) {
		const char pair[3] = { hex[2 * index], hex[2 * index + 1], 0 };

		buffer[1 + index] = (uint8_t)strtoul(pair, NULL, 16);
	}
	*length = digits / 2;
	return (buffer + 1);
}

static int
run_pair(char **argv)
{
	_Alignas(8) uint8_t partition_bytes[17], tryboot_bytes[17];
	size_t partition_len, tryboot_len;
	const uint8_t *partition = property(argv[0], partition_bytes, &partition_len);
	const uint8_t *tryboot = property(argv[1], tryboot_bytes, &tryboot_len);
	const erx_boot_pair_t boot = erx_boot_pair_derive(partition, partition_len,
	    tryboot, tryboot_len);

	printf("value %" PRIu32 " slot %" PRIu32 "\n", boot.value, boot.slot);
	return (0);
}

int
main(int argc, char **argv)
{
	if ((argc == 7 || argc == 9) && strcmp(argv[1], "plan") == 0)
		return (run_plan(argv + 2, false));
	if ((argc == 7 || argc == 9) && strcmp(argv[1], "apply") == 0)
		return (run_plan(argv + 2, true));
	if (argc == 3 && strcmp(argv[1], "handoff") == 0)
		return (run_handoff(argv + 2));
	if (argc == 4 && strcmp(argv[1], "write") == 0)
		return (run_write(argv + 2));
	if (argc == 4 && strcmp(argv[1], "pair") == 0)
		return (run_pair(argv + 2));
	if (argc == 5 && strcmp(argv[1], "lines") == 0) {
		uint64_t first, end;

		if (!erx_cache_lines(strtoull(argv[2], NULL, 0), strtoull(argv[3], NULL, 0),
		    strtoull(argv[4], NULL, 0), &first, &end))
			printf("wraps\n");
		else
			printf("%" PRIx64 " %" PRIx64 "\n", first, end);
		return (0);
	}
	if (argc == 4 && strcmp(argv[1], "args") == 0) {
		printf("%zu\n", erx_boot_args_cut(argv[3], strlen(argv[3]),
		    strtoull(argv[2], NULL, 0)));
		return (0);
	}
	return (2);
}
