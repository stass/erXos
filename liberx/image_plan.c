/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The planner of an image entry: the one reader of an erx_image_manifest's
 * segments outside the boot image validator. An image entry is the manifest
 * at offset 0, its segment table after it in the same page, then each
 * segment's bytes at its file_offset (tools/lib/erx/pack_wire.rb,
 * write_image). The bytes are read as untrusted, though the archive's hash
 * and validator have seen them: every count is bounded by this build's
 * limits, every offset and size goes through checked arithmetic, and a plan
 * comes back only when each load's bytes lie inside the entry and its memory
 * inside the image's span. Pure: it reads only bytes and writes only result.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi_reader.h"
#include "erx/elf_plan.h"

_Static_assert(ERX_IMAGE_SEGMENTS_MAX <= ERX_ELF_SEGMENTS_MAX,
    "an image's segments fit an erx_elf_plan_t");

static bool erx_image_fail(erx_elf_error_t *, const char *, uint64_t);
static bool erx_image_extent(uint64_t, uint64_t, uint64_t);
static bool erx_image_header(const erx_image_manifest_t *, size_t,
    erx_elf_error_t *);
static bool erx_image_segment_check(const erx_image_manifest_t *,
    const erx_image_segment_t *, size_t, uint64_t, uint64_t, uint64_t *,
    erx_elf_error_t *);

static bool
erx_image_fail(erx_elf_error_t *error, const char *reason, uint64_t offset)
{
	if (error != NULL) {
		error->reason = reason;
		error->offset = offset;
	}
	return (false);
}

/* True when [offset, offset + length) lies inside [0, total). */
static bool
erx_image_extent(uint64_t offset, uint64_t length, uint64_t total)
{
	return (offset <= total && length <= total - offset);
}

/*
 * The manifest's own fields: this build's magic, version and ABI version,
 * known flags, a segment table inside the first page and the entry, and a
 * span of whole pages that a fixed image places inside user space.
 */
static bool
erx_image_header(const erx_image_manifest_t *image, size_t length,
    erx_elf_error_t *error)
{
	uint64_t table_end;

	if (image->magic != ERX_IMAGE_MAGIC)
		return (erx_image_fail(error, "image_magic", 0));
	if (image->version != ERX_IMAGE_VERSION)
		return (erx_image_fail(error, "image_version", 4));
	if (image->abi_version != ERX_ABI_VERSION)
		return (erx_image_fail(error, "image_abi_version", 8));
	if ((image->flags & ~(ERX_IMAGE_FIXED | ERX_IMAGE_JIT)) != 0)
		return (erx_image_fail(error, "image_flags", 12));
	if (image->nsegments == 0 || image->nsegments > ERX_IMAGE_SEGMENTS_MAX)
		return (erx_image_fail(error, "image_segments", 6));
	table_end = ERX_IMAGE_MANIFEST_SIZE +
	    (uint64_t)image->nsegments * ERX_IMAGE_SEGMENT_SIZE;
	if (table_end > ERX_PAGE_SIZE || table_end > length)
		return (erx_image_fail(error, "image_segments", 6));
	if (image->span == 0 || image->span > ERX_IMAGE_SPAN_MAX ||
	    image->span % ERX_PAGE_SIZE != 0 ||
	    image->base_alignment < ERX_PAGE_SIZE ||
	    (image->base_alignment & (image->base_alignment - 1)) != 0)
		return (erx_image_fail(error, "image_span", 16));
	if ((image->flags & ERX_IMAGE_FIXED) == 0) {
		if (image->fixed_base != 0)
			return (erx_image_fail(error, "image_base", 24));
		return (true);
	}
	if (image->base_alignment != ERX_PAGE_SIZE ||
	    image->fixed_base < ERX_USER_BASE_MIN ||
	    image->fixed_base % ERX_PAGE_SIZE != 0 ||
	    !erx_image_extent(image->fixed_base, image->span, ERX_ARCH_USER_LIMIT))
		return (erx_image_fail(error, "image_base", 24));
	return (true);
}

/*
 * One segment, the table's at offset, checked against the rounded end of the
 * segment before it (previous): read-only, read-write or read-execute and
 * never more, a writable one no larger than ERX_IMAGE_WRITABLE_MAX, memory
 * from a page boundary at or above previous and inside the span, and file
 * bytes after the manifest's page and inside the entry. On success *end is
 * this segment's memory end rounded up to a page.
 */
static bool
erx_image_segment_check(const erx_image_manifest_t *image,
    const erx_image_segment_t *segment, size_t length, uint64_t offset,
    uint64_t previous, uint64_t *end, erx_elf_error_t *error)
{
	uint64_t memory_end, rounded;

	if ((segment->prot != ERX_PROT_R && segment->prot != ERX_PROT_RW &&
	    segment->prot != ERX_PROT_RX) ||
	    (segment->flags & ~ERX_SEG_GUARDED) != 0)
		return (erx_image_fail(error, "segment_prot", offset));
	if (segment->mem_size == 0 || segment->mem_size < segment->file_size ||
	    (segment->prot == ERX_PROT_RW &&
	    segment->mem_size > ERX_IMAGE_WRITABLE_MAX) ||
	    segment->mem_offset % ERX_PAGE_SIZE != 0 ||
	    segment->mem_offset < previous ||
	    __builtin_add_overflow(segment->mem_offset, segment->mem_size,
	    &memory_end) ||
	    __builtin_add_overflow(memory_end, ERX_PAGE_SIZE - 1, &rounded))
		return (erx_image_fail(error, "segment_memory", offset));
	rounded &= ~(uint64_t)(ERX_PAGE_SIZE - 1);
	if (rounded > image->span)
		return (erx_image_fail(error, "segment_span", offset));
	if (segment->file_offset < ERX_PAGE_SIZE ||
	    !erx_image_extent(segment->file_offset, segment->file_size, length))
		return (erx_image_fail(error, "segment_file", offset));
	*end = rounded;
	return (true);
}

/*
 * The plan of an image entry's bytes: each load's segment as the manifest
 * gives it, its source_offset the segment's file_offset in bytes, and the
 * image's fixed base, span, entry and flags. The entry must lie in a
 * read-execute segment. False, with the reason and the offset of the field
 * refused, for anything outside the checks above; result is written only on
 * success.
 */
bool
erx_image_plan(const uint8_t *bytes, size_t length, erx_elf_plan_t *result,
    erx_elf_error_t *error)
{
	erx_image_manifest_t image;
	erx_image_segment_t segment;
	erx_elf_plan_t plan;
	uint64_t offset, previous, end;
	bool entry_found;

	if (bytes == NULL || result == NULL ||
	    !erx_image_manifest_decode(bytes, length, &image))
		return (erx_image_fail(error, "image_header", 0));
	if (!erx_image_header(&image, length, error))
		return (false);
	plan = (erx_elf_plan_t){ .fixed_base = image.fixed_base,
	    .span = image.span, .entry = image.entry, .output_size = length,
	    .flags = image.flags, .base_alignment = image.base_alignment,
	    .nloads = image.nsegments };
	previous = 0;
	entry_found = false;
	for (uint32_t index = 0; index < plan.nloads; index++) {
		offset = ERX_IMAGE_MANIFEST_SIZE +
		    (uint64_t)index * ERX_IMAGE_SEGMENT_SIZE;
		/* erx_image_header put the table inside length. */
		if (!erx_image_segment_decode(bytes + (size_t)offset,
		    length - (size_t)offset, &segment))
			return (erx_image_fail(error, "segment", offset));
		if (!erx_image_segment_check(&image, &segment, length, offset,
		    previous, &end, error))
			return (false);
		if (segment.prot == ERX_PROT_RX &&
		    image.entry >= segment.mem_offset &&
		    image.entry - segment.mem_offset < segment.mem_size)
			entry_found = true;
		plan.loads[index] = (erx_elf_load_t){
		    .source_offset = segment.file_offset, .segment = segment };
		previous = end;
	}
	if (!entry_found)
		return (erx_image_fail(error, "entry_not_executable", 32));
	*result = plan;
	return (true);
}
