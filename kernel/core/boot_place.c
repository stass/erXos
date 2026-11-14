/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/boot_place.h"
#include "erx/elf_plan.h"
#include "erx/pack.h"
#include "blake3/blake3.h"

/*
 * What the plan holds apart: the first stage, the device tree, the loader's
 * reservations, the archive, the three images, then the loaded archive, the
 * device tree's copy and the handoff page. The loader's list is bounded here,
 * since a longer one could not be held apart and is refused.
 */
#define ERX_BOOT_RESERVED_MAX	32
#define ERX_BOOT_CLEAR_MAX	(ERX_BOOT_RESERVED_MAX + 9)
#define ERX_BOOT_ROLES		3

typedef struct erx_boot_clear erx_boot_clear_t;
typedef struct erx_boot_role erx_boot_role_t;
typedef struct erx_boot_work erx_boot_work_t;

/* One image bootstrap places, by the one path the ABI file fixes. */
struct erx_boot_role {
	const char	*path;
	size_t		 path_length;
	bool		 required;
	bool		 is_kernel;
};

struct erx_boot_clear {
	erx_boot_range_t ranges[ERX_BOOT_CLEAR_MAX];
	size_t		 count;
};

/*
 * The workspace's contents; only this file sees their layout. A placed role's
 * extent is its page-rounded range where it runs, and offset what was added to
 * its link addresses to get there.
 */
struct erx_boot_work {
	erx_pack_scratch_t scratch;
	erx_blake3_ctx_t hasher;
	erx_elf_kernel_plan_t plans[ERX_BOOT_ROLES];
	bool		 present[ERX_BOOT_ROLES];
	uint64_t	 data_off[ERX_BOOT_ROLES];
	erx_boot_range_t extent[ERX_BOOT_ROLES];
	uint64_t	 offset[ERX_BOOT_ROLES];
	erx_boot_clear_t clear;
};

_Static_assert(sizeof(erx_boot_work_t) <= ERX_BOOT_WORKSPACE_SIZE,
    "the bootstrap workspace holds the validator's scratch and the plans");
_Static_assert(_Alignof(erx_boot_work_t) <= _Alignof(erx_boot_workspace_t),
    "the bootstrap workspace is aligned for its contents");
_Static_assert(ERX_BOOT_PLACE_COPIES_MAX >= ERX_BOOT_ROLES * ERX_ELF_SEGMENTS_MAX,
    "every role's segments fit in the copy list");
_Static_assert(ERX_BOOT_HASH_SIZE == ERX_PACK_HASH_SIZE,
    "the seam's hash size is the format's");
_Static_assert(ERX_BOOT_ID_SIZE == sizeof(((erx_boot_handoff_t *)0)->build_id),
    "the seam's identifier size is the record's");
_Static_assert(ERX_BOOT_IMAGE_VERSION == ERX_PACK_VERSION,
    "the seam's image version is the format's");
_Static_assert(ERX_BOOT_STDOUT_MAX == ERX_BOOT_STDOUT_PATH_MAX,
    "the first stage's stdout path bound is the ABI's");
_Static_assert(ERX_BOOT_ARGS_MAX == ERX_BOOT_STRINGS_MAX,
    "the seam's command line bound is the ABI's");

/*
 * The roles, in the order each of erx_boot_load_plan's two placement passes
 * visits them: the pass over images at their link addresses, and the pass
 * over images that relocate, which runs once the archive's place is decided.
 */
enum { ERX_BOOT_ROLE_STAND_IN, ERX_BOOT_ROLE_KERNEL, ERX_BOOT_ROLE_SIGMA0 };

static const erx_boot_role_t erx_boot_roles[ERX_BOOT_ROLES] = {
	[ERX_BOOT_ROLE_STAND_IN] = { .path = ERX_BOOT_STAND_IN_ROOT_PATH_STRING,
	    .path_length = ERX_BOOT_STAND_IN_ROOT_PATH_SIZE },
	[ERX_BOOT_ROLE_KERNEL] = { .path = ERX_BOOT_KERNEL_PATH_STRING,
	    .path_length = ERX_BOOT_KERNEL_PATH_SIZE,
	    .required = true, .is_kernel = true },
	[ERX_BOOT_ROLE_SIGMA0] = { .path = ERX_BOOT_SIGMA0_PATH_STRING,
	    .path_length = ERX_BOOT_SIGMA0_PATH_SIZE, .required = true },
};

static bool erx_boot_fail(erx_boot_error_t *, const char *, const char *,
    uint32_t, uint64_t, uint64_t);
static bool erx_boot_round_up(uint64_t, uint64_t, uint64_t *);
static bool erx_boot_clear_add(erx_boot_clear_t *, erx_boot_range_t);
static const erx_boot_range_t *erx_boot_conflict(const erx_boot_clear_t *,
    uint64_t, uint64_t);
static bool erx_boot_find(const erx_pack_view_t *, const erx_boot_role_t *,
    uint32_t *);
static bool erx_boot_plan_role(const erx_pack_view_t *, size_t,
    const erx_boot_load_request_t *, erx_boot_work_t *, erx_boot_error_t *);
static bool erx_boot_extent(const erx_elf_kernel_plan_t *, uint64_t *,
    uint64_t *);
static bool erx_boot_choose(const erx_boot_load_request_t *,
    const erx_boot_clear_t *, uint64_t, uint64_t, uint64_t, uint64_t *);
static bool erx_boot_inside_memory(const erx_boot_load_request_t *, uint64_t,
    uint64_t);
static bool erx_boot_hold_apart(const erx_boot_load_request_t *,
    erx_boot_clear_t *, erx_boot_error_t *);
static bool erx_boot_place_fixed(const erx_boot_load_request_t *, size_t,
    erx_boot_work_t *, erx_boot_load_plan_t *, erx_boot_error_t *);
static bool erx_boot_place_relocatable(const erx_boot_load_request_t *,
    size_t, uint64_t, erx_boot_work_t *, erx_boot_load_plan_t *,
    erx_boot_error_t *);
static bool erx_boot_record(size_t, uint64_t, uint64_t, uint64_t,
    erx_boot_work_t *, erx_boot_load_plan_t *, erx_boot_error_t *);
static bool erx_boot_place_archive(const erx_boot_load_request_t *,
    erx_boot_work_t *, erx_boot_load_plan_t *, uint64_t *, erx_boot_error_t *);
static bool erx_boot_place_handoff_pages(const erx_boot_load_request_t *,
    erx_boot_work_t *, erx_boot_load_plan_t *, erx_boot_error_t *);
static void erx_boot_plan_copies(const erx_boot_work_t *,
    erx_boot_load_plan_t *);
static bool erx_boot_cell(const void *, size_t, uint32_t *);

static bool
erx_boot_fail(erx_boot_error_t *error, const char *reason, const char *path,
    uint32_t entry, uint64_t found, uint64_t offset)
{
	if (error != NULL)
		*error = (erx_boot_error_t){ .reason = reason, .path = path,
		    .entry = entry, .found = found, .offset = offset };
	return (false);
}

/* alignment is a power of two. */
static bool
erx_boot_round_up(uint64_t value, uint64_t alignment, uint64_t *result)
{
	if (__builtin_add_overflow(value, alignment - 1, result))
		return (false);
	*result &= ~(alignment - 1);
	return (true);
}

static bool
erx_boot_clear_add(erx_boot_clear_t *clear, erx_boot_range_t range)
{
	if (clear->count == ERX_BOOT_CLEAR_MAX)
		return (false);
	clear->ranges[clear->count++] = range;
	return (true);
}

/* The first range [start, end) meets; the list's ranges do not wrap. */
static const erx_boot_range_t *
erx_boot_conflict(const erx_boot_clear_t *clear, uint64_t start, uint64_t end)
{
	for (size_t index = 0; index < clear->count; index++) {
		const erx_boot_range_t *range = &clear->ranges[index];

		if (start < range->start + range->size && range->start < end)
			return (range);
	}
	return (NULL);
}

static bool
erx_boot_find(const erx_pack_view_t *view, const erx_boot_role_t *role,
    uint32_t *index)
{
	const uint8_t *path;
	size_t length;
	bool equal;

	for (uint32_t cursor = 0; cursor < view->header.nentries; cursor++) {
		if (!erx_pack_path_at(view, cursor, &path, &length) ||
		    length != role->path_length)
			continue;
		equal = true;
		for (size_t byte = 0; byte < length; byte++)
			equal = equal && path[byte] == (uint8_t)role->path[byte];
		if (equal) {
			*index = cursor;
			return (true);
		}
	}
	return (false);
}

/*
 * Finds a role's entry, checks its file and plans it. The file check comes
 * first, so the ELF reader sees only bytes whose hash matched.
 */
static bool
erx_boot_plan_role(const erx_pack_view_t *view, size_t slot,
    const erx_boot_load_request_t *request, erx_boot_work_t *work,
    erx_boot_error_t *error)
{
	const erx_boot_role_t *role = &erx_boot_roles[slot];
	const erx_elf_kernel_views_t views = { .kip_min = ERX_BOOT_KIP_VIEW_MIN,
	    .koptions_min = request->koptions_min };
	erx_pack_entry_t entry;
	erx_pack_error_t pack_error;
	erx_elf_error_t elf_error;
	uint32_t index;

	if (!erx_boot_find(view, role, &index)) {
		if (role->required)
			return (erx_boot_fail(error, "entry_missing", role->path,
			    ERX_BOOT_NO_ENTRY, 0, 0));
		return (true);
	}
	if (!erx_pack_entry_at(view, index, &entry) ||
	    entry.kind != ERX_ENTRY_FILE)
		return (erx_boot_fail(error, "entry_not_file", role->path, index, 0, 0));
	pack_error = (erx_pack_error_t){0};
	if (!erx_pack_file_check(view, index, &work->hasher, &pack_error))
		return (erx_boot_fail(error, pack_error.reason, role->path, index,
		    pack_error.found, 0));
	elf_error = (erx_elf_error_t){0};
	if (!erx_elf_plan_kernel(view->bytes + (size_t)entry.data_off,
	    (size_t)entry.data_size, role->is_kernel ? &views : NULL,
	    &work->plans[slot], &elf_error))
		return (erx_boot_fail(error, elf_error.reason, role->path, index, 0,
		    elf_error.offset));
	work->present[slot] = true;
	work->data_off[slot] = entry.data_off;
	return (true);
}

/* The image's page-rounded extent at its link addresses. */
static bool
erx_boot_extent(const erx_elf_kernel_plan_t *plan, uint64_t *start, uint64_t *end)
{
	const erx_elf_kernel_load_t *last = &plan->loads[plan->nloads - 1];

	*start = plan->loads[0].address & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	/* Each load's end was checked; the loads ascend, so the last is highest. */
	return (erx_boot_round_up(last->address + last->mem_size, ERX_PAGE_SIZE,
	    end));
}

/*
 * The first fit, in the order of the memory ranges: the lowest aligned address
 * at or above floor, in the first range that has one, where span bytes lie
 * inside that range and clear of everything held apart. Each conflict moves the
 * candidate past that range, so the search ends within the list's length for
 * every memory range.
 */
static bool
erx_boot_choose(const erx_boot_load_request_t *request,
    const erx_boot_clear_t *clear, uint64_t floor, uint64_t span,
    uint64_t alignment, uint64_t *result)
{
	const erx_boot_range_t *conflict;
	uint64_t candidate, candidate_end, memory_end;

	for (size_t index = 0; index < request->nmemory; index++) {
		const erx_boot_range_t *memory = &request->memory[index];

		if (__builtin_add_overflow(memory->start, memory->size, &memory_end) ||
		    !erx_boot_round_up(memory->start > floor ? memory->start : floor,
		    alignment, &candidate))
			continue;
		for (size_t step = 0; step <= clear->count; step++) {
			if (__builtin_add_overflow(candidate, span, &candidate_end) ||
			    candidate_end > memory_end)
				break;
			conflict = erx_boot_conflict(clear, candidate, candidate_end);
			if (conflict == NULL) {
				*result = candidate;
				return (true);
			}
			if (!erx_boot_round_up(conflict->start + conflict->size,
			    alignment, &candidate))
				break;
		}
	}
	return (false);
}

static bool
erx_boot_inside_memory(const erx_boot_load_request_t *request, uint64_t start,
    uint64_t end)
{
	uint64_t memory_end;

	for (size_t index = 0; index < request->nmemory; index++) {
		const erx_boot_range_t *memory = &request->memory[index];

		if (!__builtin_add_overflow(memory->start, memory->size, &memory_end) &&
		    memory->start <= start && end <= memory_end)
			return (true);
	}
	return (false);
}

/*
 * What no placement may touch, from the start: the first stage, which is
 * running, the device tree and the loader's reservations. Each placed image
 * joins the list as it is placed, and the archive once its place is decided
 * (erx_boot_place_archive).
 */
static bool
erx_boot_hold_apart(const erx_boot_load_request_t *request,
    erx_boot_clear_t *clear, erx_boot_error_t *error)
{
	uint64_t tree_end, tree_start, stage_end;

	if (__builtin_add_overflow(request->load, request->linked_end, &stage_end) ||
	    !erx_boot_round_up(stage_end, ERX_PAGE_SIZE, &stage_end) ||
	    __builtin_add_overflow(request->device_tree.start,
	    request->device_tree.size, &tree_end) ||
	    !erx_boot_round_up(tree_end, ERX_PAGE_SIZE, &tree_end))
		return (erx_boot_fail(error, "reservation_range", NULL,
		    ERX_BOOT_NO_ENTRY, 0, 0));
	tree_start = request->device_tree.start & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	clear->count = 0;
	(void)erx_boot_clear_add(clear, (erx_boot_range_t){ .start = request->load,
	    .size = stage_end - request->load });
	(void)erx_boot_clear_add(clear, (erx_boot_range_t){ .start = tree_start,
	    .size = tree_end - tree_start });
	for (size_t index = 0; index < request->nreserved; index++) {
		if (request->reserved[index].size >
		    UINT64_MAX - request->reserved[index].start)
			return (erx_boot_fail(error, "reservation_range", NULL,
			    ERX_BOOT_NO_ENTRY, 0, request->reserved[index].start));
		(void)erx_boot_clear_add(clear, request->reserved[index]);
	}
	return (true);
}

/*
 * Places an image without a dynamic section at its link addresses, which must
 * be inside memory and clear of everything held apart. The loaded archive is
 * not held apart from it: erx_boot_place_archive moves the archive off it.
 */
static bool
erx_boot_place_fixed(const erx_boot_load_request_t *request, size_t slot,
    erx_boot_work_t *work, erx_boot_load_plan_t *plan, erx_boot_error_t *error)
{
	const char *path = erx_boot_roles[slot].path;
	uint64_t end, start;

	if (!erx_boot_extent(&work->plans[slot], &start, &end))
		return (erx_boot_fail(error, "place_extent", path, ERX_BOOT_NO_ENTRY,
		    0, 0));
	if (erx_boot_roles[slot].is_kernel)
		return (erx_boot_fail(error, "kernel_not_relocatable", path,
		    ERX_BOOT_NO_ENTRY, 0, 0));
	if (!erx_boot_inside_memory(request, start, end))
		return (erx_boot_fail(error, "place_outside_memory", path,
		    ERX_BOOT_NO_ENTRY, 0, start));
	if (erx_boot_conflict(&work->clear, start, end) != NULL)
		return (erx_boot_fail(error, "place_overlap", path, ERX_BOOT_NO_ENTRY,
		    0, start));
	return (erx_boot_record(slot, start, end, 0, work, plan, error));
}

/*
 * Places an image with a dynamic section at the lowest free address of its
 * alignment at or above floor, which erx_boot_place_archive puts behind the
 * archive's extent rounded to the kernel's unit, so the kernel's region and
 * the archive's never share a unit of its free map. The fork's kernel
 * relocates itself, so it always goes here.
 */
static bool
erx_boot_place_relocatable(const erx_boot_load_request_t *request,
    size_t slot, uint64_t floor, erx_boot_work_t *work,
    erx_boot_load_plan_t *plan, erx_boot_error_t *error)
{
	const erx_elf_kernel_plan_t *image = &work->plans[slot];
	const char *path = erx_boot_roles[slot].path;
	uint64_t alignment, base, end, offset, origin, start;

	if (!erx_boot_extent(image, &start, &end))
		return (erx_boot_fail(error, "place_extent", path, ERX_BOOT_NO_ENTRY,
		    0, 0));
	alignment = erx_boot_roles[slot].is_kernel ? ERX_BOOT_KERNEL_ALIGN :
	    image->alignment;
	origin = start & ~(alignment - 1);
	if (!erx_boot_choose(request, &work->clear, floor, end - origin,
	    alignment, &base))
		return (erx_boot_fail(error, "place_no_room", path, ERX_BOOT_NO_ENTRY,
		    0, end - origin));
	/*
	 * offset may wrap when the image is linked above its place, and modular
	 * addition still lands inside the range chosen above, which is in memory.
	 */
	offset = base - origin;
	return (erx_boot_record(slot, start + offset, end + offset, offset, work,
	    plan, error));
}

/*
 * Records a placed image: its extent [start, end), held apart from what is
 * placed after it, and the offset added to its link addresses.
 */
static bool
erx_boot_record(size_t slot, uint64_t start, uint64_t end, uint64_t offset,
    erx_boot_work_t *work, erx_boot_load_plan_t *plan, erx_boot_error_t *error)
{
	const erx_elf_kernel_plan_t *image = &work->plans[slot];
	erx_boot_placed_t placed;

	work->extent[slot] = (erx_boot_range_t){ .start = start,
	    .size = end - start };
	work->offset[slot] = offset;
	if (!erx_boot_clear_add(&work->clear, work->extent[slot]))
		return (erx_boot_fail(error, "place_list", erx_boot_roles[slot].path,
		    ERX_BOOT_NO_ENTRY, 0, 0));
	placed = (erx_boot_placed_t){ .start = start, .size = end - start,
	    .entry = image->entry + offset };
	if (slot == ERX_BOOT_ROLE_STAND_IN) {
		plan->stand_in_root = placed;
		plan->has_stand_in_root = true;
	} else if (slot == ERX_BOOT_ROLE_KERNEL) {
		plan->kernel = placed;
		plan->kip = (erx_boot_range_t){ .start = image->kip.address + offset,
		    .size = image->kip.size };
		plan->koptions = (erx_boot_range_t){
		    .start = image->koptions.address + offset,
		    .size = image->koptions.size };
		/*
		 * The views lie inside the file, and the index checked the
		 * file inside the archive, so neither sum wraps.
		 */
		plan->kip_loaded = plan->archive_loaded.start +
		    work->data_off[slot] + image->kip.source_offset;
		plan->koptions_loaded = plan->archive_loaded.start +
		    work->data_off[slot] + image->koptions.source_offset;
	} else {
		plan->sigma0 = placed;
	}
	return (true);
}

/*
 * Where the archive lies once the plan is applied: where the loader left it,
 * unless an image placed at its link addresses lands on it. Then the archive
 * moves, whole, to the lowest page behind every such image that is inside
 * memory and clear of everything held apart, as stock Fiasco's bootstrap moves
 * its modules behind the ELF images it loads (Boot_modules::move_modules). The
 * new place may overlap the loaded range, never an image, the first stage, the
 * device tree or a reservation. A move that cannot fit is refused, naming the
 * image that forced it. *behind is where the relocatable images may start: the
 * archive's end rounded up to the kernel's unit.
 */
static bool
erx_boot_place_archive(const erx_boot_load_request_t *request,
    erx_boot_work_t *work, erx_boot_load_plan_t *plan, uint64_t *behind,
    erx_boot_error_t *error)
{
	const erx_boot_range_t loaded = plan->archive_loaded;
	const char *forced = NULL;
	uint64_t floor, image_end, loaded_end, start;

	/* erx_boot_locate placed the loaded archive in memory, page-aligned. */
	if (!erx_boot_round_up(loaded.start + loaded.size, ERX_PAGE_SIZE,
	    &loaded_end))
		return (erx_boot_fail(error, "archive_extent", NULL,
		    ERX_BOOT_NO_ENTRY, 0, loaded.start));
	floor = 0;
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++) {
		const erx_boot_range_t *image = &work->extent[slot];

		if (!work->present[slot] || work->plans[slot].relocatable)
			continue;
		/* The extent is inside memory, so its end does not wrap. */
		image_end = image->start + image->size;
		if (image->start < loaded_end && loaded.start < image_end &&
		    forced == NULL)
			forced = erx_boot_roles[slot].path;
		if (image_end > floor)
			floor = image_end;
	}
	start = loaded.start;
	if (forced != NULL && !erx_boot_choose(request, &work->clear, floor,
	    loaded_end - loaded.start, ERX_PAGE_SIZE, &start))
		return (erx_boot_fail(error, "archive_no_room", forced,
		    ERX_BOOT_NO_ENTRY, 0, loaded_end - loaded.start));
	plan->archive = (erx_boot_range_t){ .start = start, .size = loaded.size };
	if (!erx_boot_clear_add(&work->clear, (erx_boot_range_t){ .start = start,
	    .size = loaded_end - loaded.start }))
		return (erx_boot_fail(error, "place_list", NULL, ERX_BOOT_NO_ENTRY,
		    0, 0));
	if (!erx_boot_round_up(start + loaded.size, ERX_BOOT_KERNEL_ALIGN, behind))
		return (erx_boot_fail(error, "archive_extent", NULL,
		    ERX_BOOT_NO_ENTRY, 0, start));
	return (true);
}

/*
 * The device tree's copy and the handoff page, the last places the plan
 * chooses: the lowest free pages past the first, which bootstrap's own
 * allocator never gives and a null pointer names, clear of everything placed
 * so far and of the archive where the loader left it. bootstrap writes both
 * before it moves the archive or copies an image, so the loaded archive is held
 * apart here and not before: the images placed earlier may lie on it. The
 * copy's room is the tree's declared size in whole pages, which the packed copy
 * never exceeds.
 */
static bool
erx_boot_place_handoff_pages(const erx_boot_load_request_t *request,
    erx_boot_work_t *work, erx_boot_load_plan_t *plan, erx_boot_error_t *error)
{
	uint64_t page, room, start;

	if (request->device_tree.size == 0 ||
	    !erx_boot_round_up(request->device_tree.size, ERX_PAGE_SIZE, &room))
		return (erx_boot_fail(error, "size", "device tree", ERX_BOOT_NO_ENTRY,
		    request->device_tree.size, 0));
	/* The archive's size is a whole number of pages (erx_pack_open). */
	if (!erx_boot_clear_add(&work->clear, plan->archive_loaded))
		return (erx_boot_fail(error, "place_list", NULL, ERX_BOOT_NO_ENTRY,
		    0, 0));
	if (!erx_boot_choose(request, &work->clear, ERX_PAGE_SIZE, room,
	    ERX_PAGE_SIZE, &start))
		return (erx_boot_fail(error, "no_free_ram", "device tree",
		    ERX_BOOT_NO_ENTRY, 0, room));
	plan->tree_copy = (erx_boot_range_t){ .start = start, .size = room };
	if (!erx_boot_clear_add(&work->clear, plan->tree_copy))
		return (erx_boot_fail(error, "place_list", NULL, ERX_BOOT_NO_ENTRY,
		    0, 0));
	if (!erx_boot_choose(request, &work->clear, ERX_PAGE_SIZE, ERX_PAGE_SIZE,
	    ERX_PAGE_SIZE, &page))
		return (erx_boot_fail(error, "no_free_page", "handoff page",
		    ERX_BOOT_NO_ENTRY, 0, ERX_PAGE_SIZE));
	plan->handoff_page = page;
	if (!erx_boot_clear_add(&work->clear, (erx_boot_range_t){ .start = page,
	    .size = ERX_PAGE_SIZE }))
		return (erx_boot_fail(error, "place_list", NULL, ERX_BOOT_NO_ENTRY,
		    0, 0));
	return (true);
}

/*
 * Every placed image's segments, read from the archive where the plan leaves
 * it. The ELF plan checked each load inside its file and the index each file
 * inside the archive, so no source sum wraps.
 */
static void
erx_boot_plan_copies(const erx_boot_work_t *work, erx_boot_load_plan_t *plan)
{
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++) {
		const erx_elf_kernel_plan_t *image = &work->plans[slot];

		if (!work->present[slot])
			continue;
		for (uint32_t index = 0; index < image->nloads; index++) {
			const erx_elf_kernel_load_t *load = &image->loads[index];

			plan->copies[plan->ncopies++] = (erx_boot_copy_t){
				.source = plan->archive.start +
				    work->data_off[slot] + load->source_offset,
				.target = load->address + work->offset[slot],
				.file_size = load->file_size,
				.mem_size = load->mem_size,
			};
		}
	}
}

bool
erx_boot_load_plan(const erx_boot_load_request_t *request,
    erx_boot_workspace_t *workspace, erx_boot_load_plan_t *result,
    erx_boot_error_t *error)
{
	erx_boot_work_t *work;
	erx_boot_inputs_t inputs;
	erx_boot_range_t archive;
	erx_boot_load_plan_t plan;
	erx_pack_error_t pack_error;
	erx_pack_view_t view;
	uint64_t behind;

	if (request == NULL || workspace == NULL || result == NULL)
		return (erx_boot_fail(error, "request", NULL, ERX_BOOT_NO_ENTRY, 0, 0));
	if (request->nreserved > ERX_BOOT_RESERVED_MAX)
		return (erx_boot_fail(error, "reservations", NULL, ERX_BOOT_NO_ENTRY,
		    request->nreserved, 0));
	work = (erx_boot_work_t *)(void *)workspace->bytes;
	inputs = (erx_boot_inputs_t){
		.locator = request->locator,
		.load = request->load,
		.linked_end = request->linked_end,
		.declared_size = request->declared_size,
		.has_initrd = request->has_initrd,
		.initrd = request->initrd,
		.device_tree = request->device_tree,
		.memory = request->memory,
		.nmemory = request->nmemory,
		.reserved = request->reserved,
		.nreserved = request->nreserved,
	};
	pack_error = (erx_pack_error_t){0};
	if (!erx_boot_locate(&inputs, &archive, &pack_error))
		return (erx_boot_fail(error, pack_error.reason, NULL,
		    pack_error.entry, pack_error.found, 0));
	if (archive.start < request->window_start ||
	    archive.start - request->window_start > request->window_size ||
	    archive.size > request->window_size -
	    (archive.start - request->window_start))
		return (erx_boot_fail(error, "window", NULL, ERX_BOOT_NO_ENTRY, 0,
		    archive.start));
	if (!erx_pack_open((const uint8_t *)((uintptr_t)request->window +
	    (uintptr_t)(archive.start - request->window_start)), (size_t)archive.size,
	    &work->scratch, &work->hasher, &view, &pack_error))
		return (erx_boot_fail(error, pack_error.reason, NULL,
		    pack_error.entry, pack_error.found, 0));
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++)
		work->present[slot] = false;
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++) {
		if (!erx_boot_plan_role(&view, slot, request, work, error))
			return (false);
	}
	plan = (erx_boot_load_plan_t){ .archive = archive,
	    .archive_loaded = archive, .flags = view.header.flags,
	    .root_entry = view.header.root_entry };
	for (size_t index = 0; index < ERX_BOOT_ID_SIZE; index++)
		plan.build_id[index] = view.header.build_id[index];
	for (size_t index = 0; index < ERX_BOOT_HASH_SIZE; index++)
		plan.index_hash[index] = view.header.index_hash[index];
	if (!erx_boot_hold_apart(request, &work->clear, error))
		return (false);
	/*
	 * Images at their link addresses first, then the archive around them,
	 * then the images that move, behind the archive, then the tree's copy
	 * and the handoff page; the copies last, once every address is final.
	 */
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++) {
		if (work->present[slot] && !work->plans[slot].relocatable &&
		    !erx_boot_place_fixed(request, slot, work, &plan, error))
			return (false);
	}
	if (!erx_boot_place_archive(request, work, &plan, &behind, error))
		return (false);
	for (size_t slot = 0; slot < ERX_BOOT_ROLES; slot++) {
		if (work->present[slot] && work->plans[slot].relocatable &&
		    !erx_boot_place_relocatable(request, slot, behind, work, &plan,
		    error))
			return (false);
	}
	if (!erx_boot_place_handoff_pages(request, work, &plan, error))
		return (false);
	erx_boot_plan_copies(work, &plan);
	*result = plan;
	return (true);
}

size_t
erx_boot_args_cut(const char *args, size_t length, size_t limit)
{
	if (args == NULL)
		return (0);
	if (length <= limit)
		return (length);
	/* A space at limit means the bytes before it end a word. */
	for (size_t cut = limit; cut > 0; cut--) {
		if (args[cut] == ' ')
			return (cut);
	}
	return (0);
}

/* One big-endian 32-bit cell, read a byte at a time: a property is aligned only to 4. */
static bool
erx_boot_cell(const void *property, size_t length, uint32_t *cell)
{
	const uint8_t *bytes = property;

	if (property == NULL || length != sizeof(*cell))
		return (false);
	*cell = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 |
	    (uint32_t)bytes[2] << 8 | bytes[3];
	return (true);
}

erx_boot_pair_t
erx_boot_pair_derive(const void *partition, size_t partition_len,
    const void *tryboot, size_t tryboot_len)
{
	const erx_boot_pair_t unknown = { .value = ERX_BOOT_VALUE_UNKNOWN,
	    .slot = ERX_BOOT_SLOT_NONE };
	erx_boot_pair_t pair;
	uint32_t number, trial;

	if (!erx_boot_cell(partition, partition_len, &number) ||
	    !erx_boot_cell(tryboot, tryboot_len, &trial))
		return (unknown);
	switch (number) {
	case ERX_MEDIUM_SLOT_A_PARTITION:
		pair.slot = ERX_BOOT_SLOT_A;
		break;
	case ERX_MEDIUM_SLOT_B_PARTITION:
		pair.slot = ERX_BOOT_SLOT_B;
		break;
	default:
		return (unknown);
	}
	switch (trial) {
	case 0:
		pair.value = ERX_BOOT_VALUE_NORMAL;
		break;
	case 1:
		pair.value = ERX_BOOT_VALUE_TRIAL;
		break;
	default:
		return (unknown);
	}
	return (pair);
}

bool
erx_boot_handoff_write(const erx_boot_load_plan_t *plan, const char *bootargs,
    size_t bootargs_len, const char *stdout_path, size_t stdout_len,
    erx_boot_pair_t boot, erx_boot_range_t tree,
    const uint64_t cpu_id[ERX_BOOT_CPU_ID_COUNT], uint8_t *record, size_t size)
{
	erx_boot_handoff_t *handoff;

	if (plan == NULL || cpu_id == NULL || record == NULL || size < ERX_BOOT_HANDOFF_SIZE ||
	    bootargs_len > ERX_BOOT_STRINGS_MAX ||
	    (bootargs == NULL && bootargs_len != 0) ||
	    stdout_len > ERX_BOOT_STDOUT_PATH_MAX ||
	    (stdout_path == NULL && stdout_len != 0) ||
	    !erx_boot_pair_valid(boot.value, boot.slot) ||
	    !erx_boot_tree_range_valid(tree.start, tree.size) ||
	    ((uintptr_t)record % ERX_BOOT_HANDOFF_ALIGN) != 0)
		return (false);
	/* A node name outside the specification's characters: the tree names no console. */
	if (!erx_boot_node_path_valid((const uint8_t *)stdout_path, stdout_len))
		stdout_len = 0;
	handoff = (erx_boot_handoff_t *)(void *)record;
	*handoff = (erx_boot_handoff_t){
		.version = ERX_BOOT_HANDOFF_VERSION,
		.flags = plan->flags,
		.image_start = plan->archive.start,
		.image_size = plan->archive.size,
		.bootargs_len = (uint32_t)bootargs_len,
		.stdout_path_len = (uint32_t)stdout_len,
		.boot_value = boot.value,
		.boot_slot = boot.slot,
		.tree_start = tree.start,
		.tree_size = tree.size,
	};
	for (size_t index = 0; index < ERX_BOOT_ID_SIZE; index++)
		handoff->build_id[index] = plan->build_id[index];
	for (size_t index = 0; index < ERX_BOOT_HASH_SIZE; index++)
		handoff->index_hash[index] = plan->index_hash[index];
	for (size_t index = 0; index < bootargs_len; index++)
		handoff->bootargs[index] = (uint8_t)bootargs[index];
	for (size_t index = 0; index < stdout_len; index++)
		handoff->stdout_path[index] = (uint8_t)stdout_path[index];
	for (size_t index = 0; index < ERX_BOOT_CPU_ID_COUNT; index++)
		handoff->cpu_id[index] = cpu_id[index];
	return (true);
}
