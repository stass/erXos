/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BOOT_WORDS_H
#define ERX_BOOT_WORDS_H

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

/* -erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY, the system domain's. */
#define ERX_BOOT_DEVICE_WORDS_MAX	(sizeof("-erx") + sizeof("device") + \
	2u * ERX_BOOT_NAME_WORD_MAX + 4u * ERX_BOOT_NUMBER_WORD_MAX)

/* -erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MEM_H MEM_SIZE, a holder's per device. */
#define ERX_BOOT_GIVEN_WORDS_MAX	(sizeof("-erx") + sizeof("given") + \
	2u * ERX_BOOT_NAME_WORD_MAX + 6u * ERX_BOOT_NUMBER_WORD_MAX)

/* -erx boot VALUE SLOT: the longest names are "unknown" and "none" (include/erx/core/boot_pair.h). */
#define ERX_BOOT_PAIR_WORDS_MAX		(sizeof("-erx") + sizeof("boot") + \
	sizeof("unknown") + sizeof("none"))

#endif /* ERX_BOOT_WORDS_H */
