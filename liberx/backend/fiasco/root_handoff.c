/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A root task's one way to bootstrap's handoff record: the kernel information
 * page's user_ptr names it (docs/design-stopgap.md, "Boot handoff"). The system's
 * root reads it through erx_fiasco_root_open, a test's root directly, for the CPU
 * feature words of its C library's start.
 */

#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/kip.h>

#include "erx/abi.h"
#include "erx/core/boot_handoff.h"
#include "liberx/backend/fiasco/root_handoff.h"
#include "liberx/backend/fiasco/vm.h"

const char *
erx_fiasco_root_handoff(erx_boot_handoff_view_t *handoff)
{
	const l4_kernel_info_t *kip;

	kip = l4sigma0_map_kip(L4_BASE_PAGER_CAP, (void *)ERX_FIASCO_KIP_WINDOW,
	    L4_PAGESHIFT);
	if (kip == NULL)
		return ("kernel information page: not mapped");
	/* A kernel started without bootstrap's handoff page has a user_ptr of 0. */
	return (erx_boot_handoff_accept((const uint8_t *)(uintptr_t)kip->user_ptr,
	    ERX_BOOT_HANDOFF_SIZE, handoff));
}
