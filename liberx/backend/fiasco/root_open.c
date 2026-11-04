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
#include "erx/core/boot_handoff.h"
#include "erx/pack.h"
#include "kernel/crypto/blake3/blake3.h"
#include "liberx/backend/fiasco/root_open.h"

/* Where the root sees the kernel information page: no RAM on QEMU virt is here. */
#define ERX_ROOT_KIP_WINDOW	UINT64_C(0x10000000)

/* No stack holds these: the archive's checks want them large and long-lived. */
static erx_blake3_ctx_t root_hasher;
static erx_pack_scratch_t root_scratch;

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
	const char *reason;

	kip = l4sigma0_map_kip(L4_BASE_PAGER_CAP, (void *)ERX_ROOT_KIP_WINDOW,
	    L4_PAGESHIFT);
	if (kip == NULL)
		return ("kernel information page: not mapped");

	/* A kernel started without bootstrap's handoff page has a user_ptr of 0. */
	reason = erx_boot_handoff_accept((const uint8_t *)(uintptr_t)kip->user_ptr,
	    ERX_BOOT_HANDOFF_SIZE, handoff);
	if (reason != NULL)
		return (reason);

	if (!erx_pack_open((const uint8_t *)(uintptr_t)handoff->image.start,
	    (size_t)handoff->image.size, &root_scratch, &root_hasher, pack,
	    &pack_error))
		return (pack_error.reason);
	if (!root_bytes_equal(pack->header.index_hash, handoff->index_hash,
	    sizeof(handoff->index_hash)))
		return ("archive is not the one the record names");

	/*
	 * Entries lie in the archive in index order, so the last one's run is the
	 * archive's end: reading it shows the whole range reached this task.
	 */
	if (!erx_pack_file_check(pack, pack->header.nentries - 1, &root_hasher,
	    &pack_error))
		return (pack_error.reason);
	return (NULL);
}
