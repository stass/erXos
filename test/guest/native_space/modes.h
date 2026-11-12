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
#define MODE_CREATOR	4	/* creates spaces below its own, runs one from the slice passed, ends with 0 */
#define MODE_FIRST	5	/* finds FIRST_TAG above its mode, ends with FIRST_STATUS */
#define MODE_GROUP	6	/* in its domain group: its take is its own, which a worker may not make: ends with 0 */
#define MODE_HOLDER	7	/* maps the object whose handle the root passed it, the next bytes, read-only: ends with 0 */
#define MODE_TIME	8	/* finds TIME_FIRST_NS, raises its signal, sees TIME_SECOND_NS: ends with 0 */
#define MODE_BELL	9	/* in its domain group: waits for its bell, then acks it and rings the root's: ends with 0 */
#define MODE_RELEASE	10	/* lists the slice whose handle the root passed, mapped at SLICE_ADDR: ends with 0 */
#define MODE_DATA	11	/* finds DATA_PATTERN in its own writable data and writes WRITER_PATTERN there: ends with 0 */
#define MODE_CODE_READ	12	/* ends with the first word of its own code as its status */
#define MODE_CODE_WRITE	13	/* writes the first word of its own code, which faults at its gate */
#define MODE_MAKER	14	/* in its domain group: makes and installs a program's handles, runs it: ends with 0 */
#define MODE_MASK	UINT64_C(0xff)
#define SLOT_SHIFT	8u

/* Where the root maps into each task: the shared object's pages, and the root's signal page. */
#define SHARED_ADDR	UINT64_C(0x4000400000)
#define SHARED_PAGES	2u
#define SIGNAL_ADDR	UINT64_C(0x4000600000)

/* Where the root maps a slice of the image's domain release into a task, and its pages. */
#define SLICE_ADDR	UINT64_C(0x4000800000)
#define SLICE_PAGES	2u
/*
 * The image's domains/sample/ release, which tools/lib/erx/native_space.rb writes: a
 * short file, and one whose path, without the prefix, is RELEASE_LONG_PARTS copies of
 * RELEASE_LONG_PART and then RELEASE_LONG_TAIL, longer than a public UTCB holds.
 */
#define RELEASE_FIRST_PATH	"domains/sample/alpha"
#define RELEASE_ALPHA		"alpha"
#define RELEASE_ALPHA_BYTES	"alpha file\n"
#define RELEASE_LONG_PART	"long-name/"
#define RELEASE_LONG_PARTS	60u
#define RELEASE_LONG_TAIL	"end"
#define RELEASE_LONG_BYTES	"long file\n"

#define ROOT_PATTERN	UINT64_C(0x5ea5ea5ea5ea5ea5)
#define WRITER_PATTERN	UINT64_C(0x0ddba11c0ffee000)
#define DATA_PATTERN	UINT64_C(0xda7ada7ada7ada7a)
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

/*
 * MODE_CREATOR's argument: the handle of the slice of the program's entry the root
 * passed it, and the root's handle of another task's first thread, which it may not start.
 * Its child reports under CREATOR_LABEL and the grandchild under the next label.
 */
#define CREATOR_SLICE_SHIFT	8u
#define CREATOR_THREAD_SHIFT	32u
#define CREATOR_THREAD_MASK	UINT64_C(0xffff)
/* The program's archive index, which the creator may not map without a slice. */
#define CREATOR_ENTRY_SHIFT	48u
#define CREATOR_LABEL	UINT64_C(1)
#define CREATOR_WAIT_NS	UINT64_C(10000000000)

/*
 * MODE_MAKER's argument: the handle of the slice of the program's entry the root passed
 * it. Its child reports under MAKER_LABEL, and the budget it carves from its own holds
 * MAKER_PAGES as guarantee and cap.
 */
#define MAKER_SLICE_SHIFT	8u
#define MAKER_LABEL	UINT64_C(7)
#define MAKER_PAGES	UINT64_C(64)

/*
 * The program MODE_MAKER starts, as a session starts one: its first thread finds
 * PROGRAM_TAG in its last argument register, which no mode's argument reaches, the
 * values the maker installed in the registers the ABI's program_arg names, and
 * PROGRAM_MARK with its index in each register the maker leaves without a value. The
 * program's doorbell rings under CHANNEL_LABEL, and the maker leaves the value of a
 * group the program may not bind into at CHANNEL_OTHER_WORD of the ring.
 */
#define PROGRAM_TAG_ARG	7u
#define PROGRAM_TAG	UINT64_C(0x9e0a9e0a9e0a9e0a)
#define PROGRAM_MARK	UINT64_C(0x3a3a3a3a00000000)
#define PROGRAM_STATUS	57
#define CHANNEL_ADDR	UINT64_C(0x4000a00000)
#define CHANNEL_LABEL	UINT64_C(0xc4a1000000000001)
#define CHANNEL_OTHER_WORD	1u

#endif /* ERX_NATIVE_SPACE_MODES_H */
