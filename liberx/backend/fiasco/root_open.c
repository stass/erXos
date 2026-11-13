/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/kip.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/core/boot_handoff.h"
#include "erx/pack.h"
#include "liberx/backend/api.h"
#include "kernel/crypto/blake3/blake3.h"
#include "liberx/backend/fiasco/launcher.h"
#include "liberx/backend/fiasco/root_open.h"
#include "liberx/backend/fiasco/vm.h"

/* No stack holds these: the archive's checks want them large and long-lived. */
static erx_blake3_ctx_t root_hasher;
static erx_pack_scratch_t root_scratch;
/* The accepted handoff's device-tree copy, which erx_boot_tree returns; size 0 until then. */
static const void *root_tree;
static size_t root_tree_size;

static bool
root_bytes_equal(const uint8_t *first, const uint8_t *second, size_t length)
{
	for (size_t index = 0; index < length; index++)
		if (first[index] != second[index])
			return (false);
	return (true);
}

const char *
erx_fiasco_root_open(erx_boot_handoff_view_t *handoff, erx_pack_view_t *pack)
{
	const l4_kernel_info_t *kip;
	erx_pack_error_t pack_error = { 0 };
	erx_pack_entry_t entry;
	const char *reason;
	uint32_t last;

	kip = l4sigma0_map_kip(L4_BASE_PAGER_CAP, (void *)ERX_FIASCO_KIP_WINDOW,
	    L4_PAGESHIFT);
	if (kip == NULL)
		return ("kernel information page: not mapped");

	/* A kernel started without bootstrap's handoff page has a user_ptr of 0. */
	reason = erx_boot_handoff_accept((const uint8_t *)(uintptr_t)kip->user_ptr,
	    ERX_BOOT_HANDOFF_SIZE, handoff);
	if (reason != NULL)
		return (reason);
	root_tree = (const void *)(uintptr_t)handoff->tree.start;
	root_tree_size = (size_t)handoff->tree.size;
	/*
	 * Touching each page of the tree's copy now, while sigma0 is still the
	 * pager, maps it read-only by its sub-type (docs/design-stopgap.md, "Boot
	 * handoff", step 2): once the service is the root's pager, a fault on a
	 * page it was never given ends the root. The range is page-aligned and
	 * bounded, as erx_boot_handoff_accept checked.
	 */
	for (size_t offset = 0; offset < root_tree_size; offset += ERX_PAGE_SIZE)
		(void)*(const volatile uint8_t *)((const char *)root_tree + offset);

	if (!erx_pack_open((const uint8_t *)(uintptr_t)handoff->image.start,
	    (size_t)handoff->image.size, &root_scratch, &root_hasher, pack,
	    &pack_error))
		return (pack_error.reason);
	if (!root_bytes_equal(pack->header.index_hash, handoff->index_hash,
	    sizeof(handoff->index_hash)))
		return ("archive is not the one the record names");

	/*
	 * Entries lie in the archive in index order, so the last one with any
	 * bytes ends at the archive's end: reading it shows the whole range
	 * reached this task. An empty file or directory after it has an empty
	 * run.
	 */
	last = pack->header.nentries - 1;
	while (last > 0 && erx_pack_entry_at(pack, last, &entry) &&
	    entry.data_size == 0)
		last--;
	if (!erx_pack_file_check(pack, last, &root_hasher, &pack_error))
		return (pack_error.reason);
	return (NULL);
}

int
erx_boot_tree(const void **bytes, size_t *size)
{
	if (root_tree_size == 0)
		return (ERX_ENOTSUP);
	*bytes = root_tree;
	*size = root_tree_size;
	return (ERX_OK);
}

const char *
erx_fiasco_root_read_manifest(const erx_pack_view_t *pack, erx_manifest_view_t *manifest)
{
	erx_pack_error_t pack_error = { 0 };
	erx_abi_error_t error = { 0 };
	erx_pack_entry_t entry;
	uint32_t index;

	if (erx_fiasco_launcher_find(pack, ERX_SYSTEM_MANIFEST_PATH_STRING, &index) != ERX_OK ||
	    !erx_pack_entry_at(pack, index, &entry))
		return ("manifest: the archive holds none");
	if (!erx_pack_file_check(pack, index, &root_hasher, &pack_error))
		return (pack_error.reason);
	if (!erx_manifest_open(pack->bytes + (size_t)entry.data_off, (size_t)entry.data_size,
	    manifest, &error))
		return (error.reason);
	return (NULL);
}
