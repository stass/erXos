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
#define MODE_FIRST	5	/* finds FIRST_TAG above its mode, ends with FIRST_STATUS */
#define MODE_GROUP	6	/* in its domain group: its take is its own, which a worker may not make: ends with 0 */
#define MODE_HOLDER	7	/* maps the object whose handle the root passed it, the next bytes, read-only: ends with 0 */
#define MODE_TIME	8	/* finds TIME_FIRST_NS, raises its signal, sees TIME_SECOND_NS: ends with 0 */
#define MODE_BELL	9	/* in its domain group: waits for its bell, then acks it and rings the root's: ends with 0 */
#define MODE_MASK	UINT64_C(0xff)
#define SLOT_SHIFT	8u

/* Where the root maps into each task: the shared object's pages, and the root's signal page. */
#define SHARED_ADDR	UINT64_C(0x4000400000)
#define SHARED_PAGES	2u
#define SIGNAL_ADDR	UINT64_C(0x4000600000)

#define ROOT_PATTERN	UINT64_C(0x5ea5ea5ea5ea5ea5)
#define WRITER_PATTERN	UINT64_C(0x0ddba11c0ffee000)
/* What the root passes a first thread it starts above MODE_FIRST, and what that thread ends with. */
#define FIRST_TAG	UINT64_C(0x5eed)
#define FIRST_STATUS	55
/* The wall clock the root sets before it makes a MODE_TIME task, and once the task has read it. */
#define TIME_FIRST_NS	UINT64_C(0x1000000000000000)
#define TIME_SECOND_NS	UINT64_C(0x2000000000000000)
/* How far past either setting a read may land: the case's whole wait. */
#define TIME_SLACK_NS	UINT64_C(10000000000)

/* The doorbells case: where MODE_BELL finds its two handles, and the labels their binds give. */
#define BELL_SHIFT	8u
#define BACK_SHIFT	32u
#define HANDLE_MASK	UINT64_C(0xffffff)
#define BELL_LABEL	UINT64_C(0xbe11000000000001)
#define BACK_LABEL	UINT64_C(0xbe11000000000002)

#endif /* ERX_NATIVE_SPACE_MODES_H */
