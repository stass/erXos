/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * image-plan ENTRY: erx_image_plan over an image entry's bytes. Prints the
 * plan's fields, then one load line per segment, and exits 0; or prints
 * "error REASON OFFSET" and exits 1.
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/elf_plan.h"
#include "input.h"

int
main(int argc, char **argv)
{
	const erx_elf_load_t *load;
	erx_elf_plan_t plan;
	erx_elf_error_t error;
	uint8_t *bytes;
	size_t length;
	bool accepted;

	if (argc != 2) {
		fputs("usage: image-plan ENTRY\n", stderr);
		return (2);
	}
	bytes = erx_host_input_read(argv[1], &length);
	if (bytes == NULL) {
		fputs("cannot read the entry within host budget\n", stderr);
		return (1);
	}
	accepted = erx_image_plan(bytes, length, &plan, &error);
	if (accepted) {
		printf("plan fixed_base %" PRIu64 " span %" PRIu64 " entry %" PRIu64
		    " flags %u nloads %u\n", plan.fixed_base, plan.span, plan.entry,
		    plan.flags, plan.nloads);
		for (uint32_t index = 0; index < plan.nloads; index++) {
			load = &plan.loads[index];
			printf("load %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64
			    " %u\n", load->source_offset, load->segment.mem_offset,
			    load->segment.file_size, load->segment.mem_size,
			    load->segment.prot);
		}
	} else {
		printf("error %s %" PRIu64 "\n", error.reason, error.offset);
	}
	free(bytes);
	return (accepted ? 0 : 1);
}
