/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The fid a draw of a runtime's fid counter yields (docs/design-files.md, Version and
 * attach). Pure: it needs nothing of ERTS and builds for the host, where
 * test/host/release_fs_test.rb checks it.
 */

#ifndef ERX_FID_H
#define ERX_FID_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * A runtime draws fids from one 64-bit counter: a draw adds one and keeps the low 32
 * bits, drawing again for 9P's NOFID, which no fid takes. This gives the fid a draw
 * that gave `value` yields, or false for NOFID: draw again.
 */
static inline bool
erx_fid_of(uint64_t value, uint32_t *fid)
{
	if ((uint32_t)value == ERX_P9_NOFID)
		return (false);
	*fid = (uint32_t)value;
	return (true);
}

#endif /* ERX_FID_H */
