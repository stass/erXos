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
 * the top of memory, and prints the plan or the refusal.
 *
 * handoff FILE: accepts FILE's bytes as a record and prints what it holds.
 * args LIMIT TEXT: prints TEXT's length cut at LIMIT.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/core/boot_handoff.h"
#include "erx/core/boot_place.h"

#define DEVICE_TREE_SIZE 0x2000

_Alignas(8) static uint8_t record[ERX_BOOT_HANDOFF_RECORD_SIZE];
static erx_boot_workspace_t workspace;
static erx_boot_load_plan_t plan;

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

static int
run_plan(char **argv)
{
	erx_boot_error_t error = {0};
	erx_boot_load_request_t request = {0};
	erx_boot_range_t memory, reserved = {0};
	size_t length;
	uint8_t *file = read_file(argv[0], &length);

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
	if (!erx_boot_load_plan(&request, &workspace, &plan, &error)) {
		printf("refused %s %s\n", error.path == NULL ? "-" : error.path,
		    error.reason);
		free(file);
		return (0);
	}
	printf("archive %" PRIx64 " %" PRIx64 "\n", plan.archive.start,
	    plan.archive.size);
	print_placed("kernel", plan.kernel);
	print_placed("sigma0", plan.sigma0);
	if (plan.has_stand_in_root)
		print_placed("root", plan.stand_in_root);
	printf("kip %" PRIx64 " %" PRIx64 "\n", plan.kip.start, plan.kip.size);
	printf("koptions %" PRIx64 " %" PRIx64 "\n", plan.koptions.start,
	    plan.koptions.size);
	for (uint32_t index = 0; index < plan.ncopies; index++) {
		const erx_boot_copy_t *copy = &plan.copies[index];

		/* A copy reads only what the window holds. */
		if (copy->source < request.window_start ||
		    copy->source - request.window_start + copy->file_size > length)
			abort();
		printf("copy %" PRIx64 " %" PRIx64 " %" PRIx64 " %" PRIx64 "\n",
		    copy->source - request.window_start, copy->target,
		    copy->file_size, copy->mem_size);
	}
	if (!erx_boot_handoff_write(&plan, "erx.a=1", 7, "/pl011@9000000", 14, record,
	    sizeof(record)))
		abort();
	fwrite(record, 1, 48, stdout);
	printf("\n");
	free(file);
	return (0);
}

static int
run_handoff(char **argv)
{
	erx_boot_handoff_view_t view;
	const char *reason;
	size_t length;
	uint8_t *file = read_file(argv[0], &length);
	erx_boot_range_t range;
	bool covered;

	memcpy(record, file, length < sizeof(record) ? length : sizeof(record));
	reason = erx_boot_handoff_accept(record, length, &view);
	if (reason != NULL) {
		printf("refused %s\n", reason);
		free(file);
		return (0);
	}
	range = (erx_boot_range_t){ .start = view.image.start, .size = view.image.size };
	covered = erx_boot_handoff_covered(&view, &range, 1);
	range.size -= 1;
	printf("flags %" PRIx32 " development %d image %" PRIx64 " %" PRIx64
	    " bootargs %.*s stdout %.*s covered %d %d\n", view.flags, view.development,
	    view.image.start, view.image.size, (int)view.bootargs_len, view.bootargs,
	    (int)view.stdout_path_len, view.stdout_path,
	    covered, erx_boot_handoff_covered(&view, &range, 1));
	free(file);
	return (0);
}

int
main(int argc, char **argv)
{
	if ((argc == 7 || argc == 9) && strcmp(argv[1], "plan") == 0)
		return (run_plan(argv + 2));
	if (argc == 3 && strcmp(argv[1], "handoff") == 0)
		return (run_handoff(argv + 2));
	if (argc == 4 && strcmp(argv[1], "args") == 0) {
		printf("%zu\n", erx_boot_args_cut(argv[3], strlen(argv[3]),
		    strtoull(argv[2], NULL, 0)));
		return (0);
	}
	return (2);
}
