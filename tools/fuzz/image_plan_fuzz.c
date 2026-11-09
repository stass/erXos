/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "erx/elf_plan.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/*
 * An accepted plan's loads read only the entry's bytes, after its manifest
 * page, and land in ascending, disjoint pages of the span, which a fixed image
 * places in user space; none is writable and executable at once, a writable
 * one is within its limit, and the entry lies in a read-execute one.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	const erx_elf_load_t *load;
	erx_elf_plan_t plan;
	erx_elf_error_t error;
	uint64_t previous, start, end;
	bool entry_found;

	if (!erx_image_plan(bytes, length, &plan, &error))
		return (0);
	if (plan.nloads == 0 || plan.nloads > ERX_IMAGE_SEGMENTS_MAX ||
	    plan.span == 0 || plan.span > ERX_IMAGE_SPAN_MAX || plan.entry >= plan.span ||
	    plan.phdr_offset != 0 || plan.phnum != 0)
		abort();
	if ((plan.flags & ERX_IMAGE_FIXED) != 0 &&
	    (plan.fixed_base < ERX_USER_BASE_MIN || plan.fixed_base % ERX_PAGE_SIZE != 0 ||
	    plan.fixed_base > ERX_ARCH_USER_LIMIT || plan.span > ERX_ARCH_USER_LIMIT - plan.fixed_base))
		abort();
	previous = 0;
	entry_found = false;
	for (uint32_t index = 0; index < plan.nloads; index++) {
		load = &plan.loads[index];
		if (load->source_offset < ERX_PAGE_SIZE || load->source_offset > length ||
		    load->segment.file_size > length - load->source_offset ||
		    load->segment.file_size > load->segment.mem_size ||
		    load->segment.mem_offset > plan.span ||
		    load->segment.mem_size > plan.span - load->segment.mem_offset ||
		    (load->segment.prot != ERX_PROT_R && load->segment.prot != ERX_PROT_RW &&
		    load->segment.prot != ERX_PROT_RX) ||
		    (load->segment.prot == ERX_PROT_RW && load->segment.mem_size > ERX_IMAGE_WRITABLE_MAX))
			abort();
		start = load->segment.mem_offset;
		end = (start + load->segment.mem_size + ERX_PAGE_SIZE - 1) & ~(uint64_t)(ERX_PAGE_SIZE - 1);
		if (load->segment.mem_size == 0 || start % ERX_PAGE_SIZE != 0 || start < previous)
			abort();
		if (load->segment.prot == ERX_PROT_RX && plan.entry >= start &&
		    plan.entry - start < load->segment.mem_size)
			entry_found = true;
		previous = end;
	}
	if (!entry_found)
		abort();
	return (0);
}
