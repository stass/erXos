/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Slices of the boot archive, erx_mem_copy, and erx_release_entry asked of the
 * service (docs/design-stopgap.md, "The call table"). A slice is a memory object over
 * a run of whole archive entries whose pages are the archive's own, so a map of it
 * reads the archive's bytes (vm.c); its record keeps the run, from which a task's
 * erx_release_entry is answered, since a task holds no index. Only the service thread
 * runs these bodies, one at a time.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "blake3/blake3.h"
#include "erx/abi.h"
#include "erx/pack.h"
#include "liberx/backend/fiasco/cache.h"
#include "liberx/backend/fiasco/object.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/slice.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

#define SLICE_PAGE_MASK		((uint64_t)ERX_PAGE_SIZE - 1)
/* A domain release's files lie under domains/<name>/, which a task's paths come without. */
#define SLICE_DOMAINS		"domains/"
#define SLICE_DOMAINS_LENGTH	(sizeof(SLICE_DOMAINS) - 1)

/* What a slice's create hands the fill of its record. */
typedef struct slice_fill {
	uintptr_t	window;		/* the root's address of the run's first page */
	uint64_t	size;
	uint32_t	first, count;
} slice_fill_t;

static int	slice_run(const erx_fiasco_image_slice_request_t *, slice_fill_t *);
static bool	slice_holds_image(const slice_fill_t *);
static int	slice_fill(uint32_t, const void *);
static size_t	slice_prefix(const uint8_t *, size_t);

/* The file checks' hasher: large for the service's stack, and one body runs at a time. */
static erx_blake3_ctx_t slice_hasher;

int
erx_fiasco_slice_create_body(uint32_t caller, const erx_fiasco_image_slice_request_t *request, uint64_t *slice)
{
	slice_fill_t fill;
	int status;

	if (caller != ERX_FIASCO_TASK_ROOT || erx_fiasco_task_archive() == NULL)
		return (ERX_ENOTSUP);
	status = slice_run(request, &fill);
	/* An image entry's one slice is erx_image_map's, which no revoke of another may reach. */
	if (status == ERX_OK && slice_holds_image(&fill))
		status = ERX_ERANGE;
	if (status != ERX_OK)
		return (status);
	return (erx_fiasco_object_create(caller, ERX_BACKEND_OBJECT_MEMORY, request->budget, slice_fill, &fill, slice));
}

/*
 * The entry's file is checked first, its hash, its padding and the image layout
 * erx_pack_file_check reads, since the map shows its pages as they are. The slice is
 * the root's and its one handle goes at once: it is kept (erx_fiasco_object_keep), and
 * with no handle no destroy can name it. The keep comes before the close, which would
 * otherwise end an object with no reference. The root's budget is
 * never destroyed, so no budget's walk ends it either.
 */
int
erx_fiasco_slice_image(uint32_t entry, uint32_t *object)
{
	const erx_fiasco_image_slice_request_t request = { .caller = ERX_FIASCO_TASK_ROOT, .budget = ERX_CAP_SELF,
	    .first = entry, .count = 1 };
	erx_pack_error_t error;
	slice_fill_t fill;
	uint64_t handle;
	int status;

	if (!erx_pack_file_check(erx_fiasco_task_archive(), entry, &slice_hasher, &error))
		return (ERX_ECORRUPT);
	status = slice_run(&request, &fill);
	if (status == ERX_OK)
		status = erx_fiasco_object_create(ERX_FIASCO_TASK_ROOT, ERX_BACKEND_OBJECT_MEMORY, request.budget, slice_fill, &fill,
		    &handle);
	if (status == ERX_OK)
		status = erx_fiasco_object_find(ERX_FIASCO_TASK_ROOT, handle, ERX_BACKEND_OBJECT_MEMORY, object);
	if (status != ERX_OK)
		return (status);
	erx_fiasco_object_keep(*object);
	(void)erx_fiasco_cap_close_body(ERX_FIASCO_TASK_ROOT, handle);
	erx_fiasco_vm_slice_code(*object);
	erx_fiasco_cache_make_coherent(fill.window, (size_t)fill.size);
	return (ERX_OK);
}

/*
 * The run covers its entries' pages: erx_pack_open checked that each run starts on a
 * page inside the archive, whose size is whole pages, so the last run's end rounded up
 * stays inside it too.
 */
static int
slice_run(const erx_fiasco_image_slice_request_t *request, slice_fill_t *fill)
{
	const erx_pack_view_t *const archive = erx_fiasco_task_archive();
	erx_pack_entry_t first, last;
	uint64_t end;

	if (request->count == 0 || request->first >= archive->header.nentries ||
	    request->count > archive->header.nentries - request->first ||
	    !erx_pack_entry_at(archive, (uint32_t)request->first, &first) ||
	    !erx_pack_entry_at(archive, (uint32_t)(request->first + request->count - 1), &last))
		return (ERX_ERANGE);
	if (__builtin_add_overflow(last.data_off, last.data_size, &end) ||
	    __builtin_add_overflow(end, SLICE_PAGE_MASK, &end))
		return (ERX_ERANGE);
	end &= ~SLICE_PAGE_MASK;
	/* A run of empty files has no page of its own to map. */
	if (end <= first.data_off || (first.data_off & SLICE_PAGE_MASK) != 0 ||
	    ((uintptr_t)archive->bytes & SLICE_PAGE_MASK) != 0)
		return (ERX_ERANGE);
	*fill = (slice_fill_t){ .window = (uintptr_t)archive->bytes + (uintptr_t)first.data_off,
	    .size = end - first.data_off, .first = (uint32_t)request->first, .count = (uint32_t)request->count };
	return (ERX_OK);
}

/* Whether the run holds an image entry; slice_run read each end of it, so each entry is there. */
static bool
slice_holds_image(const slice_fill_t *fill)
{
	erx_pack_entry_t entry;

	for (uint32_t index = fill->first; index - fill->first < fill->count; index++)
		if (erx_pack_entry_at(erx_fiasco_task_archive(), index, &entry) && entry.kind == ERX_ENTRY_IMAGE)
			return (true);
	return (false);
}

static int
slice_fill(uint32_t object, const void *request)
{
	const slice_fill_t *const fill = request;

	return (erx_fiasco_vm_slice_create(object, fill->window, fill->size, fill->first, fill->count));
}

int
erx_fiasco_mem_copy_body(uint32_t caller, const erx_fiasco_mem_copy_request_t *request, uint64_t *done)
{
	uint32_t dst, src;
	int status = erx_fiasco_object_find(caller, request->dst, ERX_BACKEND_OBJECT_MEMORY, &dst);

	if (status == ERX_OK)
		status = erx_fiasco_object_find(caller, request->src, ERX_BACKEND_OBJECT_MEMORY, &src);
	if (status != ERX_OK)
		return (status);
	*done = request->done;
	return (erx_fiasco_vm_object_copy(dst, request->dst_offset, src, request->src_offset, request->len, done));
}

/*
 * The entry's numbers in the reply and its path's piece in the caller's public UTCB.
 * The offset counts from the slice's first byte, where the task mapped it; the file
 * check is erx_pack_file_check's, the one the root's erx_release_check makes.
 */
int
erx_fiasco_release_entry_body(uint32_t task, const erx_fiasco_release_entry_request_t *request, erx_fiasco_reply_t *reply)
{
	const erx_pack_view_t *const archive = erx_fiasco_task_archive();
	erx_fiasco_thread_record_t *const record = erx_fiasco_task_record(task, (uint32_t)request->caller);
	erx_pack_error_t error = { .reason = "file", .entry = UINT32_MAX };
	erx_pack_entry_t base, entry;
	const uint8_t *path;
	size_t length, prefix, relative;
	uint32_t object, first, count, index;
	int status;

	if (record == NULL || archive == NULL || request->check > 1)
		return (ERX_EINVAL);
	status = erx_fiasco_object_find(task, request->release, ERX_BACKEND_OBJECT_MEMORY, &object);
	if (status == ERX_OK)
		status = erx_fiasco_vm_slice_entries(object, &first, &count);
	if (status != ERX_OK)
		return (status);
	if (request->index >= count)
		return (ERX_ERANGE);
	index = first + (uint32_t)request->index;
	if (!erx_pack_entry_at(archive, first, &base) || !erx_pack_entry_at(archive, index, &entry) ||
	    !erx_pack_path_at(archive, index, &path, &length))
		return (ERX_ERANGE);
	prefix = slice_prefix(path, length);
	relative = length - prefix;
	if (request->piece > relative)
		return (ERX_ERANGE);
	if (request->check == 1 && !erx_pack_file_check(archive, index, &slice_hasher, &error))
		return (ERX_ECORRUPT);
	for (size_t done = 0; done < ERX_UTCB_BYTES_MAX && request->piece + done < relative;
	    done += sizeof(uint64_t)) {
		const size_t left = relative - (size_t)request->piece - done;
		uint64_t word = 0;

		__builtin_memcpy(&word, path + prefix + request->piece + done, left < sizeof(word) ? left : sizeof(word));
		(void)erx_utcb_mr_store(&record->utcb, done / sizeof(word), word);
	}
	reply->first = entry.data_size;
	reply->second = entry.data_off - base.data_off;
	reply->third = relative;
	reply->fourth = entry.kind;
	return (ERX_OK);
}

/*
 * The length of a path's domains/<name>/ prefix, or 0 for a path under no such name:
 * the name has at least one byte, and something follows its slash.
 */
static size_t
slice_prefix(const uint8_t *path, size_t length)
{
	if (length <= SLICE_DOMAINS_LENGTH)
		return (0);
	for (size_t cursor = 0; cursor < SLICE_DOMAINS_LENGTH; cursor++)
		if (path[cursor] != (uint8_t)SLICE_DOMAINS[cursor])
			return (0);
	for (size_t cursor = SLICE_DOMAINS_LENGTH + 1; cursor + 1 < length; cursor++)
		if (path[cursor] == '/')
			return (cursor + 1);
	return (0);
}
