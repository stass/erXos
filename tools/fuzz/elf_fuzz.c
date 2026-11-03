/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/elf_plan.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_elf_plan_t plan = {0};
	erx_elf_error_t error;

	if (erx_elf_plan(bytes, length, UINT64_C(16) * 1024 * 1024,
	    &plan, &error)) {
		if (plan.nloads == 0 || plan.nloads > ERX_ELF_SEGMENTS_MAX ||
		    plan.output_size > UINT64_C(16) * 1024 * 1024)
			abort();
		for (uint32_t index = 0; index < plan.nloads; index++) {
			if (plan.loads[index].source_offset > length ||
			    plan.loads[index].segment.file_size >
			    length - plan.loads[index].source_offset ||
			    plan.loads[index].segment.mem_offset > plan.span ||
			    plan.loads[index].segment.mem_size >
			    plan.span - plan.loads[index].segment.mem_offset)
				abort();
		}
	} else if (plan.nloads != 0 || plan.output_size != 0) {
		abort();
	}
	return (0);
}
