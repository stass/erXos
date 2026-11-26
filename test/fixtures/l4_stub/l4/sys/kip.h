/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host's stand-in for the one part of the kernel information page a root reads
 * (liberx/backend/fiasco/root_handoff.c): the handoff record's address. The host
 * tests that build the root's handoff code include it in place of Fiasco's.
 */

#ifndef ERX_TEST_L4_STUB_KIP_H
#define ERX_TEST_L4_STUB_KIP_H

#include <stdint.h>

typedef struct {
	uint64_t	user_ptr;
} l4_kernel_info_t;

#endif
