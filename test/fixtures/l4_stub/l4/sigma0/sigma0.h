/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host's stand-in for the one sigma0 call a root's handoff code makes: mapping the
 * kernel information page. The test's driver defines it.
 */

#ifndef ERX_TEST_L4_STUB_SIGMA0_H
#define ERX_TEST_L4_STUB_SIGMA0_H

#include <l4/sys/kip.h>

#define L4_BASE_PAGER_CAP	0u

l4_kernel_info_t	*l4sigma0_map_kip(unsigned pager, void *address, unsigned log2_size);

#endif
