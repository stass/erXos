/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BOOT_WORDS_H
#define ERX_BOOT_WORDS_H

#include "erx/abi.h"

/*
 * The longest of each boot record the root and the domain library write into
 * a boot page's arguments (docs/design-fiasco.md, "Boot information"), each
 * word with its NUL. A writer sizes its buffer by its record's, and the domain
 * library's boot view reserves room for them in a configured row's strings
 * (liberx/system/dom_boot_view.c), so a length is never copied by hand.
 */

/*
 * The word that opens every boot record, "-erx_record": the dash and the flag's name
 * (abi/erx_abi.txt, boot_record_flag), which names no application, so the application
 * controller never reads a record's words as an application's environment.
 */
#define ERX_BOOT_RECORD_FLAG		"-" ERX_BOOT_RECORD_FLAG_STRING

/* A name of a device record: a role or a CMSIS-SVD peripheral, at most 15 bytes. */
#define ERX_BOOT_NAME_WORD_MAX		16u
/* A decimal number of at most UINT64_MAX's 20 digits. */
#define ERX_BOOT_NUMBER_WORD_MAX	21u
/* A line's mark, direct or shared (docs/design-shared-devices.md, "Lines inside a domain"). */
#define ERX_BOOT_MARK_WORD_MAX		7u
/* A device's device-tree path, at most ERX_DEVICE_PATH_MAX bytes (erx_boot_device_path_valid). */
#define ERX_BOOT_PATH_WORD_MAX		(ERX_DEVICE_PATH_MAX + 1u)

/*
 * -erx_record console PERIPHERAL BASE SIZE LINE MARK CLOCK, the system domain's console, whose
 * console and PERIPHERAL are names of its UART's row of erx_uart_kinds (erx/device_kinds.h).
 */
#define ERX_BOOT_CONSOLE_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + \
	2u * ERX_BOOT_NAME_WORD_MAX + 4u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_MARK_WORD_MAX)

/*
 * -erx_record device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK INDEX OFF ON, the system domain's physical
 * record, OFF and ON its device's power line times.
 */
#define ERX_BOOT_DEVICE_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("device") + \
	2u * ERX_BOOT_NAME_WORD_MAX + ERX_BOOT_PATH_WORD_MAX + 7u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_MARK_WORD_MAX)

/*
 * -erx_record given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT MAC INDEX,
 * per given device, a holder's or the root's own: COHERENT is one digit, every other number a u64.
 */
#define ERX_BOOT_GIVEN_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("given") + \
	2u * ERX_BOOT_NAME_WORD_MAX + ERX_BOOT_PATH_WORD_MAX + 9u * ERX_BOOT_NUMBER_WORD_MAX + sizeof("1") + ERX_BOOT_MARK_WORD_MAX)

/*
 * -erx_record function ROLE PERIPHERAL BRIDGE BUS DEVICE FUNCTION LINE_H MARK MEM_H MEM_SIZE COHERENT ROUTE
 * ADDRESS DATA TABLE_BAR TABLE_OFFSET TABLE_SIZE then WINDOW_H OFFSET SIZE_LOG2 for each of the six BARs, per
 * PCIe function given to a holder (docs/design-pcie.md, "The catalogue and gives"): ROUTE is a name of
 * ERX_BOOT_ROUTE_WORD_MAX bytes, COHERENT one digit, every other number a u64.
 */
#define ERX_BOOT_ROUTE_WORD_MAX		5u
#define ERX_BOOT_FUNCTION_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("function") + \
	2u * ERX_BOOT_NAME_WORD_MAX + 30u * ERX_BOOT_NUMBER_WORD_MAX + sizeof("1") + ERX_BOOT_MARK_WORD_MAX + \
	ERX_BOOT_ROUTE_WORD_MAX)

/*
 * -erx_record framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT, per framebuffer a domain
 * holds (docs/design-device-tree.md, "Facts into records"): FORMAT is a name of the device-tree
 * reader's table (erx_dt_fb_format_name), the longest "a2r10g10b10" and "x2r10g10b10".
 */
#define ERX_BOOT_FORMAT_WORD_MAX	12u
#define ERX_BOOT_FRAMEBUFFER_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("framebuffer") + \
	6u * ERX_BOOT_NUMBER_WORD_MAX + ERX_BOOT_FORMAT_WORD_MAX)

/* -erx_record boot VALUE SLOT: the longest names are "unknown" and "none" (include/erx/core/boot_pair.h). */
#define ERX_BOOT_PAIR_WORDS_MAX		(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("boot") + \
	sizeof("unknown") + sizeof("none"))

/* -erx_record build ID: the boot image's build identifier as one decimal number. */
#define ERX_BOOT_BUILD_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("build") + ERX_BOOT_NUMBER_WORD_MAX)

/*
 * -erx_record system_image LEN TREE_OFF TREE_LEN SALT ROOT [record_volume], the system
 * window's holder's (docs/design-fiasco.md, "The booted slot"): three u64s, then the salt,
 * at most the row's array, and the root hash, each byte two lowercase hex digits, and the
 * record_volume window role's name, erx_mf_window_role_name's "record_volume", when the
 * holder holds that window too.
 */
#define ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("system_image") + \
	3u * ERX_BOOT_NUMBER_WORD_MAX + 2u * sizeof(((erx_mf_system_image_t *)0)->salt) + 1u + \
	2u * sizeof(((erx_mf_system_image_t *)0)->root_hash) + 1u + sizeof("record_volume"))

/*
 * -erx_record drive ROLE N, per drive window on a device a configured domain holds
 * (docs/design-fiasco.md, "Drive records"): ROLE the longer of the two roles a drive lies on,
 * usb and block, and N a drive number below mf_none, at most ten digits.
 */
#define ERX_BOOT_DRIVE_WORDS_MAX	(sizeof(ERX_BOOT_RECORD_FLAG) + sizeof("drive") + sizeof("block") + \
	sizeof("4294967294"))

#endif /* ERX_BOOT_WORDS_H */
