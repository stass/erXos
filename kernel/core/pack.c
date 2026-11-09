/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot image's checks (design-kernel.md, The boot image, Checking a
 * file and The bootable file). erx_boot_locate finds the archive,
 * erx_pack_open checks its index run and erx_pack_file_check checks one
 * file's run; each is a pure function of the bytes and values it is given.
 * Every size and offset read from the archive or the locator is bounded
 * with checked arithmetic before it is used.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "blake3/blake3.h"
#include "erx/abi_reader.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"

_Static_assert(ERX_PACK_HASH_SIZE == ERX_BLAKE3_OUT_LEN,
    "the pack's hash is BLAKE3's output");
_Static_assert(sizeof(((erx_pack_header_t *)0)->index_hash) ==
    ERX_PACK_HASH_SIZE, "index hash width");
_Static_assert(sizeof(((erx_pack_entry_t *)0)->file_hash) ==
    ERX_PACK_HASH_SIZE, "file hash width");
_Static_assert(ERX_PACK_HEADER_OFF_INDEX_HASH + ERX_PACK_HASH_SIZE ==
    ERX_PACK_HEADER_SIZE, "the index hash ends the header");

/* What check 7 has seen of the entries so far. */
typedef struct erx_release {
	unsigned	system_runs;
	unsigned	seal_runs;
	bool		in_system;
	bool		in_seal;
	bool		has_manifest;
} erx_release_t;

static bool erx_pack_fail(erx_pack_error_t *, uint32_t, const char *);
static bool erx_pack_fail_found(erx_pack_error_t *, uint32_t, const char *,
    uint64_t);
static bool erx_extent(uint64_t, uint64_t, uint64_t);
static bool erx_round_page(uint64_t, uint64_t *);
static bool erx_zeroes(const uint8_t *, uint64_t, uint64_t, size_t);
static bool erx_hash_equal(const uint8_t *, const uint8_t *);
static void erx_index_digest(const uint8_t *, size_t, erx_blake3_ctx_t *,
    uint8_t *);
static int erx_path_compare(const uint8_t *, size_t, const uint8_t *, size_t);
static bool erx_path_valid(const uint8_t *, size_t);
static bool erx_is_manifest_path(const uint8_t *, size_t);
static bool erx_image_valid(const uint8_t *, size_t, bool,
    erx_pack_error_t *, uint32_t);
static bool erx_phdr_covered(const erx_elf_plan_t *, uint64_t, uint32_t);
static bool erx_pack_manifest_valid(const uint8_t *, size_t, uint32_t,
    erx_pack_error_t *, uint32_t);
static bool erx_entry_decode(const uint8_t *, size_t,
    const erx_pack_header_t *, uint32_t, erx_pack_entry_t *);
static bool erx_index_check(const uint8_t *, size_t, erx_blake3_ctx_t *,
    erx_pack_header_t *, uint64_t *, erx_pack_error_t *);
static bool erx_prefix_step(const erx_pack_view_t *, erx_pack_scratch_t *,
    size_t *, uint32_t, const uint8_t *, size_t, erx_pack_error_t *);
static bool erx_entry_place(const erx_pack_entry_t *, uint64_t *, size_t);
static const char *erx_release_step(erx_release_t *, const erx_pack_entry_t *,
    bool, bool);
static bool erx_ranges_clear(erx_boot_range_t, erx_boot_range_t);
static bool erx_locator_range(const erx_boot_inputs_t *,
    const erx_boot_locator_t *, erx_boot_range_t *);
static bool erx_archive_place(const erx_boot_inputs_t *, erx_boot_range_t,
    erx_pack_error_t *);

static bool
erx_pack_fail(erx_pack_error_t *error, uint32_t entry, const char *reason)
{
	return (erx_pack_fail_found(error, entry, reason, 0));
}

static bool
erx_pack_fail_found(erx_pack_error_t *error, uint32_t entry,
    const char *reason, uint64_t found)
{
	if (error != NULL) {
		error->entry = entry;
		error->reason = reason;
		error->found = found;
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

/* Integrity, not secrecy: the hashes are public, so no constant time. */
static bool
erx_hash_equal(const uint8_t *left, const uint8_t *right)
{
	for (size_t index = 0; index < ERX_PACK_HASH_SIZE; index++) {
		if (left[index] != right[index])
			return (false);
	}
	return (true);
}

/*
 * The index run's hash: the bytes [0, index_end) with the header's own
 * index_hash field read as zeros. index_end lies inside the archive and
 * past the header, which the caller has checked.
 */
static void
erx_index_digest(const uint8_t *bytes, size_t index_end,
    erx_blake3_ctx_t *hasher, uint8_t *digest)
{
	static const uint8_t zero_hash[ERX_PACK_HASH_SIZE];

	erx_blake3_init(hasher);
	erx_blake3_update(hasher, bytes, ERX_PACK_HEADER_OFF_INDEX_HASH);
	erx_blake3_update(hasher, zero_hash, sizeof(zero_hash));
	erx_blake3_update(hasher, bytes + ERX_PACK_HEADER_SIZE,
	    index_end - ERX_PACK_HEADER_SIZE);
	erx_blake3_final(hasher, digest);
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

/*
 * True when the program-header table, phnum entries from phdr_offset in the
 * image's memory, lies wholly in the stored file bytes of the plan's
 * segments, which are ascending and do not overlap.
 */
static bool
erx_phdr_covered(const erx_elf_plan_t *plan, uint64_t phdr_offset,
    uint32_t phnum)
{
	const erx_image_segment_t *segment;
	uint64_t cursor, end, segment_end, table_bytes;

	if (phnum == 0 ||
	    __builtin_mul_overflow((uint64_t)phnum,
	    (uint64_t)ERX_ELF64_PHDR_SIZE, &table_bytes) ||
	    __builtin_add_overflow(phdr_offset, table_bytes, &end))
		return (false);
	cursor = phdr_offset;
	for (uint32_t index = 0; index < plan->nloads && cursor < end; index++) {
		segment = &plan->loads[index].segment;
		if (__builtin_add_overflow(segment->mem_offset, segment->file_size,
		    &segment_end))
			return (false);
		if (cursor >= segment_end)
			continue;
		if (cursor < segment->mem_offset)
			return (false);
		cursor = segment_end < end ? segment_end : end;
	}
	return (cursor == end);
}

/*
 * An image entry as the boot image stores it (design-kernel.md, The boot
 * image). Its manifest and segments must first pass erx_image_plan, the
 * rules the loader reads the entry by, and a refusal there carries the
 * planner's reason. The rest is the layout only the pack tool's output has,
 * checked over the plan's loads.
 * The root carries no JIT flag. The first page is zero after the segment
 * table. Each segment's stored bytes start where the one before ended, the
 * first at the second page: a writable segment stores its file bytes, a
 * read-only or read-execute one its whole memory, and each is zero from its
 * file bytes to the end of its last stored page. The entry ends with the
 * last segment's stored bytes, the span ends with its memory, and the
 * program-header table lies in the segments' file bytes.
 */
static bool
erx_image_valid(const uint8_t *bytes, size_t length, bool root,
    erx_pack_error_t *error, uint32_t entry)
{
	erx_image_manifest_t image;
	erx_elf_plan_t plan;
	/* Every refusal of the planner sets its reason; this one is a fallback. */
	erx_elf_error_t refusal = { .reason = "image_plan" };
	const erx_image_segment_t *segment;
	uint64_t table_end, cursor, storage, data_end, memory_end, span_end;

	if (!erx_image_plan(bytes, length, &plan, &refusal))
		return (erx_pack_fail(error, entry, refusal.reason));
	if (root && (plan.flags & ERX_IMAGE_JIT) != 0)
		return (erx_pack_fail(error, entry, "image_root_jit"));
	/* The plan holds at most ERX_IMAGE_SEGMENTS_MAX loads in the page. */
	table_end = ERX_IMAGE_MANIFEST_SIZE +
	    (uint64_t)plan.nloads * ERX_IMAGE_SEGMENT_SIZE;
	if (!erx_zeroes(bytes, table_end, ERX_PAGE_SIZE, length))
		return (erx_pack_fail(error, entry, "image_index"));
	cursor = ERX_PAGE_SIZE;
	memory_end = 0;
	for (uint32_t index = 0; index < plan.nloads; index++) {
		segment = &plan.loads[index].segment;
		storage = segment->prot == ERX_PROT_RW ?
		    segment->file_size : segment->mem_size;
		/* The plan put file_offset + file_size inside length. */
		data_end = segment->file_offset + segment->file_size;
		if (segment->file_offset != cursor ||
		    !erx_round_page(storage, &storage) ||
		    !erx_extent(cursor, storage, length) ||
		    !erx_zeroes(bytes, data_end, cursor + storage, length))
			return (erx_pack_fail(error, entry, "image_payload"));
		cursor += storage;
		/* The plan proved mem_offset + mem_size rounds within the span. */
		memory_end = segment->mem_offset + segment->mem_size;
	}
	if (cursor != length)
		return (erx_pack_fail(error, entry, "image_length"));
	if (!erx_round_page(memory_end, &span_end) || span_end != plan.span)
		return (erx_pack_fail(error, entry, "image_span_end"));
	/*
	 * The plan carries no program-header table, so its fields come from the
	 * manifest the planner has already accepted.
	 */
	if (!erx_image_manifest_decode(bytes, length, &image) ||
	    !erx_phdr_covered(&plan, image.phdr_offset, image.phnum))
		return (erx_pack_fail(error, entry, "image_phdr"));
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

static bool
erx_is_manifest_path(const uint8_t *path, size_t length)
{
	static const uint8_t manifest_path[] = ERX_SYSTEM_MANIFEST_PATH_BYTES;

	return (length == sizeof(manifest_path) &&
	    erx_path_compare(path, length, manifest_path,
	    sizeof(manifest_path)) == 0);
}

/*
 * Checks 1 to 3 of the validator: the header's values and the extent of the
 * index run, whose end it returns, then the index hash before any entry or
 * path is read, then the padding after the strings.
 */
static bool
erx_index_check(const uint8_t *bytes, size_t length, erx_blake3_ctx_t *hasher,
    erx_pack_header_t *header, uint64_t *index_end, erx_pack_error_t *error)
{
	static const uint8_t magic[] = ERX_PACK_MAGIC_BYTES;
	uint8_t digest[ERX_PACK_HASH_SIZE];
	uint64_t table_bytes, strings_offset, strings_end;

	if (!erx_pack_header_decode(bytes, length, header))
		return (erx_pack_fail(error, UINT32_MAX, "header_extent"));
	for (size_t index = 0; index < sizeof(magic); index++) {
		if (header->magic[index] != magic[index])
			return (erx_pack_fail(error, UINT32_MAX, "magic"));
	}
	/* An archive of another version is refused before its layout is used. */
	if (header->version != ERX_PACK_VERSION)
		return (erx_pack_fail_found(error, UINT32_MAX,
		    ERX_PACK_REASON_VERSION, header->version));
	if (header->total_size != length ||
	    header->total_size % ERX_PAGE_SIZE != 0 || header->nentries == 0 ||
	    header->nentries > ERX_PACK_ENTRIES_MAX ||
	    header->entry_size != ERX_PACK_ENTRY_SIZE ||
	    header->entries_off != ERX_PACK_HEADER_SIZE ||
	    header->strings_size > ERX_PACK_STRINGS_MAX ||
	    header->root_entry >= header->nentries ||
	    (header->flags & ~ERX_PACK_FLAGS_KNOWN) != 0 ||
	    ((header->flags & ERX_PACK_TEST_CODE) != 0 &&
	    (header->flags & ERX_PACK_DEVELOPMENT) == 0))
		return (erx_pack_fail(error, UINT32_MAX, "header_values"));
	if (__builtin_mul_overflow((uint64_t)header->nentries,
	    (uint64_t)ERX_PACK_ENTRY_SIZE, &table_bytes) ||
	    __builtin_add_overflow((uint64_t)ERX_PACK_HEADER_SIZE,
	    table_bytes, &strings_offset) ||
	    header->strings_off != strings_offset ||
	    !erx_extent(header->strings_off, header->strings_size, length) ||
	    __builtin_add_overflow(header->strings_off,
	    (uint64_t)header->strings_size, &strings_end) ||
	    !erx_round_page(strings_end, index_end) || *index_end > length)
		return (erx_pack_fail(error, UINT32_MAX, "index_extent"));
	erx_index_digest(bytes, (size_t)*index_end, hasher, digest);
	if (!erx_hash_equal(digest, header->index_hash))
		return (erx_pack_fail(error, UINT32_MAX, "index_hash"));
	if (!erx_zeroes(bytes, strings_end, *index_end, length))
		return (erx_pack_fail(error, UINT32_MAX, "index_padding"));
	return (true);
}

/*
 * Check 5's file-prefix stack: no path begins with an earlier file's path
 * followed by '/'. A pending file can still precede a later descendant when
 * the next byte is below '/': a, a-foo, a/b. Retain that candidate; pop it
 * only after lexical order has passed its descendant run. Pending candidates
 * are strict prefixes, so depth is path-bounded.
 */
static bool
erx_prefix_step(const erx_pack_view_t *view, erx_pack_scratch_t *scratch,
    size_t *depth, uint32_t index, const uint8_t *path, size_t path_length,
    erx_pack_error_t *error)
{
	const uint8_t *candidate;
	size_t candidate_length;

	while (*depth != 0) {
		if (!erx_pack_path_at(view, scratch->pending[*depth - 1],
		    &candidate, &candidate_length))
			return (erx_pack_fail(error, index, "prefix_index"));
		if (candidate_length < path_length &&
		    erx_path_compare(candidate, candidate_length,
		    path, candidate_length) == 0) {
			if (path[candidate_length] == '/')
				return (erx_pack_fail(error, index, "file_prefix"));
			if (path[candidate_length] < '/')
				break;
		}
		(*depth)--;
	}
	if (*depth >= ERX_PACK_PATH_MAX)
		return (erx_pack_fail(error, index, "prefix_depth"));
	scratch->pending[(*depth)++] = index;
	return (true);
}

/*
 * Check 6: an entry's values and its place. Each file starts at the first
 * page boundary after the previous run, the first right after the index run,
 * so every byte of the archive lies in exactly one run. On success the cursor
 * moves to where the next run starts.
 */
static bool
erx_entry_place(const erx_pack_entry_t *entry, uint64_t *cursor, size_t length)
{
	uint64_t end, next;

	if ((entry->kind != ERX_ENTRY_FILE && entry->kind != ERX_ENTRY_IMAGE) ||
	    (entry->flags & ~(ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) != 0 ||
	    (entry->flags & (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL)) ==
	    (ERX_ENTRY_SYSTEM | ERX_ENTRY_SEAL) || entry->manifest_off != 0 ||
	    entry->data_off != *cursor ||
	    !erx_extent(entry->data_off, entry->data_size, length) ||
	    __builtin_add_overflow(entry->data_off, entry->data_size, &end) ||
	    !erx_round_page(end, &next) || next > length)
		return (false);
	*cursor = next;
	return (true);
}

/*
 * Check 7, one entry at a time: at most one contiguous run of each mark, the
 * root an image of the system run, the system configuration a file of it.
 * Returns the reason for a refusal, or NULL.
 */
static const char *
erx_release_step(erx_release_t *release, const erx_pack_entry_t *entry,
    bool root, bool manifest)
{
	bool is_system, is_seal;

	is_system = (entry->flags & ERX_ENTRY_SYSTEM) != 0;
	is_seal = (entry->flags & ERX_ENTRY_SEAL) != 0;
	if (is_system && !release->in_system)
		release->system_runs++;
	if (is_seal && !release->in_seal)
		release->seal_runs++;
	release->in_system = is_system;
	release->in_seal = is_seal;
	if (release->system_runs > 1 || release->seal_runs > 1 ||
	    (root && (entry->kind != ERX_ENTRY_IMAGE || !is_system)))
		return ("release_run");
	if (manifest) {
		if (entry->kind != ERX_ENTRY_FILE || !is_system)
			return ("manifest_binding");
		release->has_manifest = true;
	}
	return (NULL);
}

/*
 * The index run, in the design's order: the header and the index hash, then
 * each entry's path and place. File data is never read here;
 * erx_pack_file_check reads it at each file's first use.
 */
bool
erx_pack_open(const uint8_t *bytes, size_t length, erx_pack_scratch_t *scratch,
    erx_blake3_ctx_t *hasher, erx_pack_view_t *result, erx_pack_error_t *error)
{
	erx_pack_view_t view;
	erx_pack_entry_t entry;
	erx_release_t release;
	const uint8_t *path, *previous_path;
	const char *reason;
	uint64_t cursor, strings_cursor;
	size_t depth, path_length, previous_length;

	if (result != NULL)
		*result = (erx_pack_view_t){0};
	if (bytes == NULL || scratch == NULL || hasher == NULL || result == NULL)
		return (erx_pack_fail(error, UINT32_MAX, "header_extent"));
	view = (erx_pack_view_t){ .bytes = bytes, .length = length };
	if (!erx_index_check(bytes, length, hasher, &view.header, &cursor, error))
		return (false);
	depth = 0;
	strings_cursor = 0;
	release = (erx_release_t){0};
	previous_path = NULL;
	previous_length = 0;
	for (uint32_t index = 0; index < view.header.nentries; index++) {
		/* The paths fill the string table in entry order, no slack. */
		if (!erx_pack_entry_at(&view, index, &entry) ||
		    entry.path_off != strings_cursor ||
		    !erx_pack_path_at(&view, index, &path, &path_length))
			return (erx_pack_fail(error, index, "path_extent"));
		strings_cursor += path_length;
		if (!erx_path_valid(path, path_length))
			return (erx_pack_fail(error, index, "path"));
		if (index != 0 && erx_path_compare(previous_path, previous_length,
		    path, path_length) >= 0)
			return (erx_pack_fail(error, index, "path_order"));
		if (!erx_prefix_step(&view, scratch, &depth, index, path, path_length,
		    error))
			return (false);
		if (!erx_entry_place(&entry, &cursor, length))
			return (erx_pack_fail(error, index, "entry_values"));
		reason = erx_release_step(&release, &entry,
		    index == view.header.root_entry,
		    erx_is_manifest_path(path, path_length));
		if (reason != NULL)
			return (erx_pack_fail(error, index, reason));
		previous_path = path;
		previous_length = path_length;
	}
	if (strings_cursor != view.header.strings_size)
		return (erx_pack_fail(error, UINT32_MAX, "path_extent"));
	if (cursor != length || release.system_runs != 1 || !release.has_manifest)
		return (erx_pack_fail(error, UINT32_MAX, "archive_end"));
	*result = view;
	return (true);
}

/*
 * One file's run, against a view erx_pack_open accepted. The hash is compared
 * first, so a damaged file is refused as damaged; then the padding, which the
 * hash alone would accept nonzero; then the manifest the file carries, if it
 * is an executable image or the system configuration.
 */
bool
erx_pack_file_check(const erx_pack_view_t *view, uint32_t index,
    erx_blake3_ctx_t *hasher, erx_pack_error_t *error)
{
	erx_pack_entry_t entry;
	const uint8_t *data, *path;
	uint8_t digest[ERX_PACK_HASH_SIZE];
	uint64_t end, run_end;
	size_t path_length;

	if (view == NULL || hasher == NULL ||
	    !erx_pack_entry_at(view, index, &entry) ||
	    !erx_pack_path_at(view, index, &path, &path_length) ||
	    !erx_extent(entry.data_off, entry.data_size, view->length) ||
	    __builtin_add_overflow(entry.data_off, entry.data_size, &end) ||
	    !erx_round_page(end, &run_end) || run_end > view->length)
		return (erx_pack_fail(error, index, "file_extent"));
	data = view->bytes + (size_t)entry.data_off;
	erx_blake3_init(hasher);
	erx_blake3_update(hasher, data, (size_t)(run_end - entry.data_off));
	erx_blake3_final(hasher, digest);
	if (!erx_hash_equal(digest, entry.file_hash))
		return (erx_pack_fail(error, index, "file_hash"));
	if (!erx_zeroes(view->bytes, end, run_end, view->length))
		return (erx_pack_fail(error, index, "padding"));
	if (entry.kind == ERX_ENTRY_IMAGE &&
	    !erx_image_valid(data, (size_t)entry.data_size,
	    index == view->header.root_entry, error, index))
		return (false);
	if (erx_is_manifest_path(path, path_length) &&
	    !erx_pack_manifest_valid(data, (size_t)entry.data_size,
	    view->header.flags, error, index))
		return (false);
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

/* Neither range wraps, and they share no byte. */
static bool
erx_ranges_clear(erx_boot_range_t left, erx_boot_range_t right)
{
	uint64_t left_end, right_end;

	if (__builtin_add_overflow(left.start, left.size, &left_end) ||
	    __builtin_add_overflow(right.start, right.size, &right_end))
		return (false);
	return (left.size == 0 || right.size == 0 ||
	    left.start >= right_end || right.start >= left_end);
}

/* The archive a locator names, at or after the linked end, inside the file. */
static bool
erx_locator_range(const erx_boot_inputs_t *inputs,
    const erx_boot_locator_t *locator, erx_boot_range_t *archive)
{
	uint64_t end, start;

	if (locator->archive_off % ERX_PAGE_SIZE != 0 ||
	    locator->archive_off < inputs->linked_end)
		return (false);
	if (__builtin_add_overflow(locator->archive_off, locator->archive_size,
	    &end) || end > inputs->declared_size)
		return (false);
	if (__builtin_add_overflow(inputs->load, locator->archive_off, &start))
		return (false);
	*archive = (erx_boot_range_t){ .start = start,
	    .size = locator->archive_size };
	return (true);
}

/*
 * The archive, wherever it came from, starts on a page, lies inside one
 * memory range of the device tree, and meets neither the device tree, nor a
 * reserved range, nor the first stage's extent.
 */
static bool
erx_archive_place(const erx_boot_inputs_t *inputs, erx_boot_range_t archive,
    erx_pack_error_t *error)
{
	erx_boot_range_t memory, stage;
	uint64_t archive_end, memory_end;
	bool inside;

	if (archive.size == 0 || archive.start % ERX_PAGE_SIZE != 0 ||
	    __builtin_add_overflow(archive.start, archive.size, &archive_end))
		return (erx_pack_fail(error, UINT32_MAX, "archive_extent"));
	inside = false;
	for (size_t index = 0; index < inputs->nmemory; index++) {
		memory = inputs->memory[index];
		if (!__builtin_add_overflow(memory.start, memory.size, &memory_end) &&
		    archive.start >= memory.start && archive_end <= memory_end)
			inside = true;
	}
	if (!inside)
		return (erx_pack_fail(error, UINT32_MAX, "archive_memory"));
	stage = (erx_boot_range_t){ .start = inputs->load,
	    .size = inputs->linked_end };
	if (!erx_ranges_clear(archive, stage) ||
	    !erx_ranges_clear(archive, inputs->device_tree))
		return (erx_pack_fail(error, UINT32_MAX, "archive_overlap"));
	for (size_t index = 0; index < inputs->nreserved; index++) {
		if (!erx_ranges_clear(archive, inputs->reserved[index]))
			return (erx_pack_fail(error, UINT32_MAX,
			    "archive_overlap"));
	}
	return (true);
}

/*
 * Where the archive is: inside the first stage's own file when its locator
 * names it, else the initrd; never both. The locator's fields are read once,
 * here, into locals.
 */
bool
erx_boot_locate(const erx_boot_inputs_t *inputs, erx_boot_range_t *result,
    erx_pack_error_t *error)
{
	static const uint8_t magic[] = ERX_BOOT_LOCATOR_MAGIC_BYTES;
	erx_boot_locator_t locator;
	erx_boot_range_t archive;

	if (inputs == NULL || result == NULL || inputs->locator == NULL ||
	    (inputs->memory == NULL && inputs->nmemory != 0) ||
	    (inputs->reserved == NULL && inputs->nreserved != 0) ||
	    !erx_boot_locator_decode(inputs->locator, ERX_BOOT_LOCATOR_SIZE,
	    &locator))
		return (erx_pack_fail(error, UINT32_MAX, "locator"));
	for (size_t index = 0; index < sizeof(magic); index++) {
		if (locator.magic[index] != magic[index])
			return (erx_pack_fail(error, UINT32_MAX, "locator"));
	}
	if (locator.version != ERX_BOOT_LOCATOR_VERSION || locator.zero != 0 ||
	    (locator.archive_off == 0) != (locator.archive_size == 0))
		return (erx_pack_fail(error, UINT32_MAX, "locator"));
	if (locator.archive_off == 0) {
		if (!inputs->has_initrd)
			return (erx_pack_fail(error, UINT32_MAX, "no_boot_image"));
		archive = inputs->initrd;
	} else {
		if (inputs->has_initrd)
			return (erx_pack_fail(error, UINT32_MAX,
			    "two_boot_images"));
		if (!erx_locator_range(inputs, &locator, &archive))
			return (erx_pack_fail(error, UINT32_MAX, "locator_range"));
	}
	if (!erx_archive_place(inputs, archive, error))
		return (false);
	*result = archive;
	return (true);
}
