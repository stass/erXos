/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BOOT_WORDS_H
#define ERX_BOOT_WORDS_H

#include "erx/abi.h"

/*
 * The longest of each -erx record the root and the domain library write into
 * a boot page's arguments (docs/design-stopgap.md, "Boot information"), each
 * word with its NUL. A writer sizes its buffer by its record's, and the domain
 * library's boot view reserves room for them in a configured row's strings
 * (liberx/system/dom_boot_view.c), so a length is never copied by hand.
 */

/* A name of a device record: a role or a CMSIS-SVD peripheral, at most 15 bytes. */
#define ERX_BOOT_NAME_WORD_MAX		16u
/* A decimal number of at most UINT64_MAX's 20 digits. */
#define ERX_BOOT_NUMBER_WORD_MAX	21u
/* A line's mark, direct or shared (docs/design-shared-devices.md, "Lines inside a domain"). */
#define ERX_BOOT_MARK_WORD_MAX		7u
/* A device's device-tree path, at most ERX_DEVICE_PATH_MAX bytes (erx_boot_device_path_valid). */
#define ERX_BOOT_PATH_WORD_MAX		(ERX_DEVICE_PATH_MAX + 1u)

/* -erx console_uart BASE SIZE LINE MARK CLOCK, the system domain's console. */
#define ERX_BOOT_CONSOLE_WORDS_MAX	(sizeof("-erx") + sizeof("console_uart") + \
	4u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_MARK_WORD_MAX)

/* -erx device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK, the system domain's physical record. */
#define ERX_BOOT_DEVICE_WORDS_MAX	(sizeof("-erx") + sizeof("device") + \
	2u * ERX_BOOT_NAME_WORD_MAX + ERX_BOOT_PATH_WORD_MAX + 4u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_MARK_WORD_MAX)

/*
 * -erx given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT MAC, per given
 * device, a holder's or the root's own: COHERENT is one digit, every other number a u64.
 */
#define ERX_BOOT_GIVEN_WORDS_MAX	(sizeof("-erx") + sizeof("given") + \
	2u * ERX_BOOT_NAME_WORD_MAX + ERX_BOOT_PATH_WORD_MAX + 8u * ERX_BOOT_NUMBER_WORD_MAX + sizeof("1") + ERX_BOOT_MARK_WORD_MAX)

/*
 * -erx framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT, per framebuffer a domain
 * holds (docs/design-device-tree.md, "Facts into records"): FORMAT is a name of the device-tree
 * reader's table (erx_dt_fb_format_name), the longest "a2r10g10b10" and "x2r10g10b10".
 */
#define ERX_BOOT_FORMAT_WORD_MAX	12u
#define ERX_BOOT_FRAMEBUFFER_WORDS_MAX	(sizeof("-erx") + sizeof("framebuffer") + \
	6u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_FORMAT_WORD_MAX)

/* -erx boot VALUE SLOT: the longest names are "unknown" and "none" (include/erx/core/boot_pair.h). */
#define ERX_BOOT_PAIR_WORDS_MAX		(sizeof("-erx") + sizeof("boot") + \
	sizeof("unknown") + sizeof("none"))

/* -erx build ID: the boot image's build identifier as one decimal number. */
#define ERX_BOOT_BUILD_WORDS_MAX	(sizeof("-erx") + sizeof("build") + ERX_BOOT_NUMBER_WORD_MAX)

#endif /* ERX_BOOT_WORDS_H */
