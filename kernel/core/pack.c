/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi_reader.h"
#include "erx/pack.h"

static bool erx_pack_fail(erx_pack_error_t *, uint32_t, const char *);
static bool erx_extent(uint64_t, uint64_t, uint64_t);
static bool erx_round_page(uint64_t, uint64_t *);
static bool erx_zeroes(const uint8_t *, uint64_t, uint64_t, size_t);
static int erx_path_compare(const uint8_t *, size_t, const uint8_t *, size_t);
static bool erx_path_valid(const uint8_t *, size_t);
static bool erx_image_valid(const uint8_t *, size_t, bool,
    erx_pack_error_t *, uint32_t);
static bool erx_phdr_covered(const uint8_t *, size_t,
    const erx_image_manifest_t *);
static bool erx_pack_manifest_valid(const uint8_t *, size_t, uint32_t,
    erx_pack_error_t *, uint32_t);
static bool erx_entry_decode(const uint8_t *, size_t,
    const erx_pack_header_t *, uint32_t, erx_pack_entry_t *);

static bool
erx_pack_fail(erx_pack_error_t *error, uint32_t entry, const char *reason)
{
	if (error != NULL) {
		error->entry = entry;
		error->reason = reason;
	}
	return (false);
}

static bool
erx_extent(uint64_t offset, uint64_t count, uint64_t length)
{
	return (offset <= length && count <= length - offset);
}

static bool
erx_round_page(uint64_t value, uint64_t *result)
{
	uint64_t rounded;

	if (__builtin_add_overflow(value, (uint64_t)ERX_PAGE_SIZE - 1,
	    &rounded))
		return (false);
	*result = rounded & ~((uint64_t)ERX_PAGE_SIZE - 1);
	return (true);
}

static bool
erx_zeroes(const uint8_t *bytes, uint64_t start, uint64_t end, size_t length)
{
	if (start > end || end > length)
		return (false);
	/* The span is bounded by the already checked archive or image length. */
	for (uint64_t index = start; index < end; index++) {
		if (bytes[(size_t)index] != 0)
			return (false);
	}
	return (true);
}

static int
erx_path_compare(const uint8_t *left, size_t left_length,
    const uint8_t *right, size_t right_length)
{
	size_t common;

	common = left_length < right_length ? left_length : right_length;
	for (size_t index = 0; index < common; index++) {
		if (left[index] < right[index])
			return (-1);
		if (left[index] > right[index])
			return (1);
	}
	if (left_length < right_length)
		return (-1);
	return (left_length != right_length);
}

static bool
erx_path_valid(const uint8_t *path, size_t length)
{
	uint32_t point, minimum;
	size_t component, cursor, count;

	if (length == 0 || length > ERX_PACK_PATH_MAX)
		return (false);
	component = 0;
	cursor = 0;
	while (cursor < length) {
		if (path[cursor] == '/') {
			count = cursor - component;
			if (count == 0 || (count == 1 && path[component] == '.') ||
			    (count == 2 && path[component] == '.' &&
			    path[component + 1] == '.'))
				return (false);
			component = cursor + 1;
		}
		if (path[cursor] < 0x20 || path[cursor] == 0x7f)
			return (false);
		point = path[cursor++];
		if (point < 0x80)
			continue;
		if (point >= 0xc2 && point <= 0xdf) {
			point &= 0x1f;
			count = 1;
			minimum = 0x80;
		} else if (point >= 0xe0 && point <= 0xef) {
			point &= 0x0f;
			count = 2;
			minimum = 0x800;
		} else if (point >= 0xf0 && point <= 0xf4) {
			point &= 0x07;
			count = 3;
			minimum = 0x10000;
		} else {
			return (false);
		}
		if (count > length - cursor)
			return (false);
		for (size_t index = 0; index < count; index++) {
			if ((path[cursor] & 0xc0) != 0x80)
				return (false);
			point = (point << 6) | (path[cursor++] & 0x3f);
		}
		if (point < minimum || point > 0x10ffff ||
		    (point >= 0xd800 && point <= 0xdfff))
			return (false);
	}
	count = length - component;
	return (count != 0 && !(count == 1 && path[component] == '.') &&
	    !(count == 2 && path[component] == '.' && path[component + 1] == '.'));
}

static bool
erx_entry_decode(const uint8_t *bytes, size_t length,
    const erx_pack_header_t *header, uint32_t index, erx_pack_entry_t *entry)
{
	uint64_t relative, offset;

	if (index >= header->nentries ||
	    __builtin_mul_overflow((uint64_t)index,
	    (uint64_t)ERX_PACK_ENTRY_SIZE, &relative) ||
	    __builtin_add_overflow(header->entries_off, relative, &offset) ||
	    !erx_extent(offset, ERX_PACK_ENTRY_SIZE, length))
		return (false);
	return (erx_pack_entry_decode(bytes + (size_t)offset,
	    ERX_PACK_ENTRY_SIZE, entry));
}

static bool
erx_phdr_covered(const uint8_t *bytes, size_t length,
    const erx_image_manifest_t *image)
{
	erx_image_segment_t segment;
	uint64_t cursor, end, segment_end, table_bytes, offset;

	if (image->phnum == 0 ||
	    __builtin_mul_overflow((uint64_t)image->phnum,
	    (uint64_t)ERX_ELF64_PHDR_SIZE, &table_bytes) ||
	    __builtin_add_overflow(image->phdr_offset, table_bytes, &end))
		return (false);
	cursor = image->phdr_offset;
	for (uint16_t index = 0; index < image->nsegments && cursor < end; index++) {
		offset = ERX_IMAGE_MANIFEST_SIZE +
		    (uint64_t)index * ERX_IMAGE_SEGMENT_SIZE;
		if (!erx_extent(offset, ERX_IMAGE_SEGMENT_SIZE, length) ||
		    !erx_image_segment_decode(bytes + (size_t)offset,
		    ERX_IMAGE_SEGMENT_SIZE, &segment) ||
		    __builtin_add_overflow(segment.mem_offset,
		    segment.file_size, &segment_end))
			return (false);
		if (cursor >= segment_end)
			continue;
		if (cursor < segment.mem_offset)
			return (false);
		cursor = segment_end < end ? segment_end : end;
	}
	return (cursor == end);
}

static bool
erx_image_valid(const uint8_t *bytes, size_t length, bool root,
    erx_pack_error_t *error, uint32_t entry)
{
	erx_image_manifest_t image;
	erx_image_segment_t segment;
	uint64_t table_bytes, table_end, data_cursor, storage, data_end;
	uint64_t memory_end, rounded_end, previous_end, offset;
	bool executable_entry;

	if (!erx_image_manifest_decode(bytes, length, &image) ||
	    image.magic != ERX_IMAGE_MAGIC || image.version != ERX_IMAGE_VERSION ||
	    image.abi_version != ERX_ABI_VERSION ||
	    image.base_alignment < ERX_PAGE_SIZE ||
	    (image.base_alignment & (image.base_alignment - 1)) != 0 ||
	    image.nsegments == 0 || image.nsegments > ERX_IMAGE_SEGMENTS_MAX ||
	    (image.flags & ~(ERX_IMAGE_FIXED | ERX_IMAGE_JIT)) != 0 ||
	    (root && (image.flags & ERX_IMAGE_JIT) != 0))
		return (erx_pack_fail(error, entry, "image_header"));
	if (__builtin_mul_overflow((uint64_t)image.nsegments,
	    (uint64_t)ERX_IMAGE_SEGMENT_SIZE, &table_bytes) ||
	    __builtin_add_overflow((uint64_t)ERX_IMAGE_MANIFEST_SIZE,
	    table_bytes, &table_end) || table_end > ERX_PAGE_SIZE ||
	    !erx_zeroes(bytes, table_end, ERX_PAGE_SIZE, length))
		return (erx_pack_fail(error, entry, "image_index"));
	if (image.span == 0 || image.span > ERX_IMAGE_SPAN_MAX ||
	    image.span % ERX_PAGE_SIZE != 0 ||
	    ((image.flags & ERX_IMAGE_FIXED) == 0 && image.fixed_base != 0) ||
	    ((image.flags & ERX_IMAGE_FIXED) != 0 &&
	    (image.base_alignment != ERX_PAGE_SIZE ||
	    image.fixed_base < ERX_USER_BASE_MIN ||
	    image.fixed_base % ERX_PAGE_SIZE != 0 ||
	    !erx_extent(image.fixed_base, image.span, ERX_ARCH_USER_LIMIT))))
		return (erx_pack_fail(error, entry, "image_span"));
	data_cursor = ERX_PAGE_SIZE;
	previous_end = 0;
	executable_entry = false;
	for (uint16_t index = 0; index < image.nsegments; index++) {
		offset = ERX_IMAGE_MANIFEST_SIZE +
		    (uint64_t)index * ERX_IMAGE_SEGMENT_SIZE;
		if (!erx_image_segment_decode(bytes + (size_t)offset,
		    ERX_IMAGE_SEGMENT_SIZE, &segment))
			return (erx_pack_fail(error, entry, "image_segment"));
		if (segment.mem_size == 0 || segment.mem_size < segment.file_size ||
		    segment.mem_offset % ERX_PAGE_SIZE != 0 ||
		    segment.file_offset != data_cursor ||
		    (segment.flags & ~ERX_SEG_GUARDED) != 0 ||
		    (segment.prot != ERX_PROT_R && segment.prot != ERX_PROT_RW &&
		    segment.prot != ERX_PROT_RX) ||
		    (segment.prot == ERX_PROT_RW &&
		    segment.mem_size > ERX_IMAGE_WRITABLE_MAX) ||
		    __builtin_add_overflow(segment.mem_offset, segment.mem_size,
		    &memory_end) || !erx_round_page(memory_end, &rounded_end) ||
		    segment.mem_offset < previous_end || rounded_end > image.span)
			return (erx_pack_fail(error, entry, "image_segment_range"));
		storage = segment.prot == ERX_PROT_RW ?
		    segment.file_size : segment.mem_size;
		if (!erx_round_page(storage, &storage) ||
		    !erx_extent(segment.file_offset, storage, length) ||
		    __builtin_add_overflow(segment.file_offset,
		    segment.file_size, &data_end) ||
		    !erx_zeroes(bytes, data_end, segment.file_offset + storage, length))
			return (erx_pack_fail(error, entry, "image_payload"));
		if (segment.prot == ERX_PROT_RX && image.entry >= segment.mem_offset &&
		    image.entry < memory_end)
			executable_entry = true;
		data_cursor = segment.file_offset + storage;
		previous_end = rounded_end;
	}
	if (data_cursor != length || previous_end != image.span ||
	    !executable_entry || !erx_phdr_covered(bytes, length, &image))
		return (erx_pack_fail(error, entry, "image_entry_or_phdr"));
	return (true);
}

static bool
erx_pack_manifest_valid(const uint8_t *bytes, size_t length,
    uint32_t pack_flags, erx_pack_error_t *error, uint32_t entry)
{
	erx_manifest_view_t manifest;
	erx_abi_error_t manifest_error;
	bool pack_development, manifest_development;

	if (!erx_manifest_open(bytes, length, &manifest, &manifest_error))
		return (erx_pack_fail(error, entry, "system_manifest"));
	pack_development = (pack_flags & ERX_PACK_DEVELOPMENT) != 0;
	manifest_development =
	    (manifest.header.flags & ERX_MANIFEST_DEVELOPMENT) != 0;
	if (pack_development != manifest_development)
		return (erx_pack_fail(error, entry, "manifest_flags"));
	return (true);
}

bool
erx_pack_open(const uint8_t *bytes, size_t length, erx_pack_scratch_t *scratch,
    erx_pack_view_t *result, erx_pack_error_t *error)
{
	static const uint8_t magic[] = ERX_PACK_MAGIC_BYTES;
	static const uint8_t manifest_path[] = ERX_SYSTEM_MANIFEST_PATH_BYTES;
	erx_pack_header_t header;
	erx_pack_entry_t entry, candidate, previous;
	const uint8_t *path, *prior_path;
	uint64_t table_bytes, strings_offset, index_end, cursor, end;
	size_t depth;
	unsigned system_run, seal_run;
	bool was_system, was_seal, has_manifest;

	if (bytes == NULL || scratch == NULL || result == NULL ||
	    !erx_pack_header_decode(bytes, length, &header))
		return (erx_pack_fail(error, UINT32_MAX, "header_extent"));
	for (size_t index = 0; index < sizeof(magic); index++) {
		if (header.magic[index] != magic[index])
			return (erx_pack_fail(error, UINT32_MAX, "magic"));
	}
	if (header.version != ERX_PACK_VERSION || header.total_size != length ||
	    header.total_size % ERX_PAGE_SIZE != 0 || header.nentries == 0 ||
	    header.nentries > ERX_PACK_ENTRIES_MAX ||
	    header.entry_size != ERX_PACK_ENTRY_SIZE ||
	    header.entries_off != ERX_PACK_HEADER_SIZE ||
	    header.strings_size > ERX_PACK_STRINGS_MAX ||
	    header.root_entry >= header.nentries ||
	    (header.flags & ~(ERX_PACK_DEVELOPMENT | ERX_PACK_UNCONFINED_DMA)) != 0)
		return (erx_pack_fail(error, UINT32_MAX, "header_values"));
	if (__builtin_mul_overflow((uint64_t)header.nentries,
	    (uint64_t)ERX_PACK_ENTRY_SIZE, &table_bytes) ||
	    __builtin_add_overflow((uint64_t)ERX_PACK_HEADER_SIZE,
	    table_bytes, &strings_offset) || header.strings_off != strings_offset ||
	    !erx_extent(header.strings_off, header.strings_size, length) ||
	    __builtin_add_overflow(header.strings_off,
	    (uint64_t)header.strings_size, &index_end) ||
	    !erx_round_page(index_end, &cursor) ||
	    !erx_zeroes(bytes, index_end, cursor, length))
		return (erx_pack_fail(error, UINT32_MAX, "index_extent"));
	depth = 0;
	system_run = 0;
	seal_run = 0;
	was_system = false;
	was_seal = false;
	has_manifest = false;
	previous = (erx_pack_entry_t){0};
	for (uint32_t index = 0; index < header.nentries; index++) {
		if (!erx_entry_decode(bytes, length, &header, index, &entry) ||
		    !erx_extent(entry.path_off, entry.path_len, header.strings_size))
			return (erx_pack_fail(error, index, "path_extent"));
		path = bytes + (size_t)header.strings_off + entry.path_off;
		if (!erx_path_valid(path, entry.path_len))
			return (erx_pack_fail(error, index, "path"));
		if (index != 0) {
			prior_path = bytes + (size_t)header.strings_off + previous.path_off;
			if (erx_path_compare(prior_path, previous.path_len,
			    path, entry.path_len) >= 0)
				return (erx_pack_fail(error, index, "path_order"));
		}
		/*
		 * A pending file can still precede a later descendant when the
		 * next byte is below '/': a, a-foo, a/b. Retain that candidate;
		 * pop it only after lexical order has passed its descendant run.
		 * Pending candidates are strict prefixes, so depth is path-bounded.
		 */
		while (depth != 0) {
			if (!erx_entry_decode(bytes, length, &header,
			    scratch->pending[depth - 1], &candidate))
				return (erx_pack_fail(error, index, "prefix_index"));
			prior_path = bytes + (size_t)header.strings_off + candidate.path_off;
			if (candidate.path_len < entry.path_len &&
			    erx_path_compare(prior_path, candidate.path_len,
			    path, candidate.path_len) == 0) {
				if (path[candidate.path_len] == '/')
					return (erx_pack_fail(error, index, "file_prefix"));
				if (path[candidate.path_len] < '/')
					break;
			}
			depth--;
		}
		if (depth >= ERX_PACK_PATH_MAX)
			return (erx_pack_fail(error, index, "prefix_depth"));
		scratch->pending[depth++] = index;
		if ((entry.kind != ERX_ENTRY_FILE && entry.kind != ERX_ENTRY_IMAGE) ||
		    (entry.flags & ~(ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) != 0 ||
		    (entry.flags & (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) ==
		    (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL) || entry.manifest_off != 0 ||
		    entry.data_off != cursor ||
		    !erx_extent(entry.data_off, entry.data_size, length) ||
		    __builtin_add_overflow(entry.data_off, entry.data_size, &end))
			return (erx_pack_fail(error, index, "entry_values"));
		if ((entry.flags & ERX_ENTRY_SYSTEM) != 0) {
			if (!was_system)
				system_run++;
			was_system = true;
		} else {
			was_system = false;
		}
		if ((entry.flags & ERX_ENTRY_SEAL) != 0) {
			if (!was_seal)
				seal_run++;
			was_seal = true;
		} else {
			was_seal = false;
		}
		if (system_run > 1 || seal_run > 1 ||
		    (index == header.root_entry &&
		    (entry.kind != ERX_ENTRY_IMAGE || !was_system)))
			return (erx_pack_fail(error, index, "release_run"));
		if (entry.path_len == sizeof(manifest_path) &&
		    erx_path_compare(path, entry.path_len,
		    manifest_path, sizeof(manifest_path)) == 0) {
			if (entry.kind != ERX_ENTRY_FILE || !was_system)
				return (erx_pack_fail(error, index, "manifest_binding"));
			if (!erx_pack_manifest_valid(bytes + (size_t)entry.data_off,
			    (size_t)entry.data_size, header.flags, error, index))
				return (false);
			has_manifest = true;
		}
		if (entry.kind == ERX_ENTRY_IMAGE &&
		    !erx_image_valid(bytes + (size_t)entry.data_off,
		    (size_t)entry.data_size, index == header.root_entry, error, index))
			return (false);
		if (!erx_round_page(end, &cursor) ||
		    !erx_zeroes(bytes, end, cursor, length))
			return (erx_pack_fail(error, index, "data_padding"));
		previous = entry;
	}
	if (cursor != length || system_run != 1 || !has_manifest)
		return (erx_pack_fail(error, UINT32_MAX, "archive_end"));
	*result = (erx_pack_view_t){ .bytes = bytes, .length = length,
	    .header = header };
	return (true);
}

bool
erx_pack_entry_at(const erx_pack_view_t *view, uint32_t index,
    erx_pack_entry_t *result)
{
	if (view == NULL || result == NULL)
		return (false);
	return (erx_entry_decode(view->bytes, view->length, &view->header,
	    index, result));
}

bool
erx_pack_path_at(const erx_pack_view_t *view, uint32_t index,
    const uint8_t **path, size_t *length)
{
	erx_pack_entry_t entry;

	if (path == NULL || length == NULL ||
	    !erx_pack_entry_at(view, index, &entry) ||
	    !erx_extent(entry.path_off, entry.path_len, view->header.strings_size))
		return (false);
	*path = view->bytes + (size_t)view->header.strings_off + entry.path_off;
	*length = entry.path_len;
	return (true);
}
