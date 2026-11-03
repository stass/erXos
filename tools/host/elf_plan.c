/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/elf_plan.h"
#include "input.h"

static void erx_print_plan(const erx_elf_plan_t *);

static void
erx_print_plan(const erx_elf_plan_t *plan)
{
	const erx_elf_load_t *load;

	printf("{\"abi_version\":%u,\"virtual_origin\":%" PRIu64 ",\"fixed_base\":%" PRIu64
	    ",\"span\":%" PRIu64 ",\"entry\":%" PRIu64
	    ",\"phdr_offset\":%" PRIu64 ",\"output_size\":%" PRIu64
	    ",\"flags\":%u,\"phnum\":%u,\"base_alignment\":%u,\"loads\":[",
	    ERX_ABI_VERSION, plan->virtual_origin, plan->fixed_base, plan->span, plan->entry,
	    plan->phdr_offset, plan->output_size, plan->flags, plan->phnum,
	    plan->base_alignment);
	for (uint32_t index = 0; index < plan->nloads; index++) {
		load = &plan->loads[index];
		printf("%s{\"source_offset\":%" PRIu64
		    ",\"file_offset\":%" PRIu64 ",\"mem_offset\":%" PRIu64
		    ",\"file_size\":%" PRIu64 ",\"mem_size\":%" PRIu64
		    ",\"prot\":%u,\"flags\":%u}", index == 0 ? "" : ",",
		    load->source_offset, load->segment.file_offset,
		    load->segment.mem_offset, load->segment.file_size,
		    load->segment.mem_size, load->segment.prot, load->segment.flags);
	}
	puts("]}");
}

int
main(int argc, char **argv)
{
	erx_elf_plan_t plan;
	erx_elf_error_t error;
	uint8_t *bytes;
	char *end;
	unsigned long long budget;
	size_t length;
	bool accepted;

	if (argc != 3) {
		fputs("usage: elf-plan ELF OUTPUT_BUDGET\n", stderr);
		return (2);
	}
	for (const char *cursor = argv[2]; *cursor != '\0'; cursor++) {
		if (*cursor < '0' || *cursor > '9') {
			fputs("output budget must be an unsigned integer\n", stderr);
			return (2);
		}
	}
	errno = 0;
	budget = strtoull(argv[2], &end, 10);
	if (errno == ERANGE || end == argv[2] || *end != '\0') {
		fputs("output budget is outside its range\n", stderr);
		return (2);
	}
	bytes = erx_host_input_read(argv[1], &length);
	if (bytes == NULL) {
		fputs("cannot read executable within host budget\n", stderr);
		return (1);
	}
	accepted = erx_elf_plan(bytes, length, (uint64_t)budget, &plan, &error);
	if (accepted)
		erx_print_plan(&plan);
	else
		printf("error %s %" PRIu64 "\n", error.reason, error.offset);
	free(bytes);
	return (accepted ? 0 : 1);
}
