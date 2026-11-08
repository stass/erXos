/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_NATIVE_SPACE_MODES_H
#define ERX_NATIVE_SPACE_MODES_H

#include <stdint.h>

/* What the program does: the low byte of the root's argument to it; the next byte is its signal slot. */
#define MODE_WRITER	1	/* finds the root's pattern, writes its own, releases the range: ends with 0 */
#define MODE_READER	2	/* finds the writer's pattern read-only, releases the range: ends with 0 */
#define MODE_REVOKED	3	/* finds the root's pattern, raises its signal, reads until a fault ends it */
#define MODE_CREATOR	4	/* creates spaces below its own and a refused one, ends with 0 */
#define MODE_MASK	UINT64_C(0xff)
#define SLOT_SHIFT	8u

/* Where the root maps into each task: the shared object's pages, and the root's signal page. */
#define SHARED_ADDR	UINT64_C(0x4000400000)
#define SHARED_PAGES	2u
#define SIGNAL_ADDR	UINT64_C(0x4000600000)

#define ROOT_PATTERN	UINT64_C(0x5ea5ea5ea5ea5ea5)
#define WRITER_PATTERN	UINT64_C(0x0ddba11c0ffee000)

#endif /* ERX_NATIVE_SPACE_MODES_H */
