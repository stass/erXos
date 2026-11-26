/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host's sigma0: its one call a root's handoff code makes maps a kernel
 * information page whose handoff address is 0. The test's driver stands in for
 * the handoff's reader, so the address is never read.
 */

#include <stddef.h>

#include <l4/sigma0/sigma0.h>

static l4_kernel_info_t stub_kip;

l4_kernel_info_t *
l4sigma0_map_kip(unsigned pager, void *address, unsigned log2_size)
{
	(void)pager, (void)address, (void)log2_size;
	return (&stub_kip);
}
