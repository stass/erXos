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

/*
 * The plan of an image entry of the boot archive (liberx/image_plan.c): its
 * erx_image_manifest page and the segments after it, as the pack tool wrote
 * them from erx_elf_plan's plan. Each load's source_offset is its segment's
 * file_offset in the entry's bytes; virtual_origin is 0 and output_size the
 * entry's length. The loads, span, base and entry hold erx_elf_plan's
 * invariants; the plan carries no program-header table, so phdr_offset and
 * phnum are 0.
 */
bool erx_image_plan(const uint8_t *, size_t, erx_elf_plan_t *,
    erx_elf_error_t *);

/*
 * The kernel profile: an executable that bootstrap places by physical address
 * before translation is on. A segment's addresses are the ELF's physical ones;
 * with a dynamic section the image relocates itself, so bootstrap may place it
 * at any offset of its alignment, and without one it runs where it is linked.
 * Up to ERX_ELF_SEGMENTS_MAX segments, in ascending physical order.
 */
typedef struct erx_elf_kernel_load erx_elf_kernel_load_t;
typedef struct erx_elf_kernel_plan erx_elf_kernel_plan_t;
typedef struct erx_elf_kernel_view erx_elf_kernel_view_t;
typedef struct erx_elf_kernel_views erx_elf_kernel_views_t;

struct erx_elf_kernel_load {
	uint64_t	source_offset;
	uint64_t	address;
	uint64_t	file_size;
	uint64_t	mem_size;
};

/* A view is a part of a segment by its physical address; no placement. */
struct erx_elf_kernel_view {
	uint64_t	address;
	uint64_t	size;
};

/* The smallest size each required view may report. */
struct erx_elf_kernel_views {
	uint64_t	kip_min;
	uint64_t	koptions_min;
};

struct erx_elf_kernel_plan {
	uint64_t	 entry;
	uint64_t	 alignment;
	uint32_t	 nloads;
	bool		 relocatable;
	erx_elf_kernel_load_t loads[ERX_ELF_SEGMENTS_MAX];
	erx_elf_kernel_view_t kip;
	erx_elf_kernel_view_t koptions;
};

bool erx_elf_plan_kernel(const uint8_t *, size_t,
    const erx_elf_kernel_views_t *, erx_elf_kernel_plan_t *,
    erx_elf_error_t *);

#endif /* ERX_ELF_PLAN_H */
