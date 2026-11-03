/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ELF_PLAN_H
#define ERX_ELF_PLAN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

typedef struct erx_elf_load erx_elf_load_t;
typedef struct erx_elf_plan erx_elf_plan_t;
typedef struct erx_elf_error erx_elf_error_t;

struct erx_elf_load {
	uint64_t	 source_offset;
	erx_image_segment_t segment;
};

/* A complete value plan; source bytes stay immutable until it is applied. */
struct erx_elf_plan {
	uint64_t	 virtual_origin;
	uint64_t	 fixed_base;
	uint64_t	 span;
	uint64_t	 entry;
	uint64_t	 phdr_offset;
	uint64_t	 output_size;
	uint32_t	 flags;
	uint32_t	 phnum;
	uint32_t	 base_alignment;
	uint32_t	 nloads;
	erx_elf_load_t	 loads[ERX_ELF_SEGMENTS_MAX];
};

struct erx_elf_error {
	const char	*reason;
	uint64_t	 offset;
};

bool erx_elf_plan(const uint8_t *, size_t, uint64_t,
    erx_elf_plan_t *, erx_elf_error_t *);

#endif /* ERX_ELF_PLAN_H */
