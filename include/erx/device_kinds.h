/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DEVICE_KINDS_H
#define ERX_DEVICE_KINDS_H

#include <stdint.h>

#include "erx/abi_reader.h"

/*
 * The kinds of device a runtime drives, one row each: a manifest device of
 * a row's role and compatible string is a row's kind, and its record carries
 * the row's names: ROLE_WORD, the record's role, and PERIPHERAL, the
 * CMSIS-SVD peripheral the device NIF opens. Every row names both, and the
 * host tools read the rows through tools/lib/erx/device_kinds.rb, which
 * refuses a row it cannot read or a name longer than a record holds
 * (ERX_BOOT_NAME_WORD_MAX, erx/boot_words.h).
 *
 * erx_device_kinds are the kinds a give drives: a device of one gets a
 * record, -erx_record given, in the system domain's boot page and in a holder
 * domain's (docs/design-stopgap.md, "Boot information"), and is driven
 * (erx_dom_entry_driven, erx/dom.h). The root's reader
 * (liberx/backend/core/boot_manifest.c) and the domain library's boot view
 * (liberx/system/dom_boot_view.c) both read this table, so a further kind
 * is one more row here. A framebuffer row has none: its record is the
 * root's framebuffer record (docs/design-device-tree.md, "Facts into
 * records"), and the row names /chosen and ERX_FRAMEBUFFER_COMPATIBLE, which
 * the manifest check proves.
 */
typedef struct erx_device_kind {
	uint32_t	 role;		/* ERX_MF_DEVICE_ROLE_* */
	const char	*compatible;	/* the platform record's compatible string */
	const char	*role_word;	/* a given record's ROLE; a UART's, its record */
	const char	*peripheral;	/* its PERIPHERAL, as the CMSIS-SVD source names it */
} erx_device_kind_t;

static const erx_device_kind_t erx_device_kinds[] = {
	{ ERX_MF_DEVICE_ROLE_BLOCK, "virtio,mmio", "block", "virtio_blk" },
	{ ERX_MF_DEVICE_ROLE_NETWORK, "virtio,mmio", "net", "virtio_net" },
	{ ERX_MF_DEVICE_ROLE_NETWORK, "brcm,bcm2711-genet-v5", "net", "genet" },
	{ ERX_MF_DEVICE_ROLE_BLOCK, "brcm,bcm2711-emmc2", "block", "sdhci" },
	{ ERX_MF_DEVICE_ROLE_GPU, "virtio,mmio", "gpu", "virtio_mmio" },
	{ ERX_MF_DEVICE_ROLE_INPUT, "virtio,mmio", "input", "virtio_input" },
};

/*
 * The UARTs a console may be (docs/design-stopgap.md, "The console"): the
 * root writes the record -erx_record ROLE_WORD PERIPHERAL ... for the UART
 * machine.console names from its row here, erx_console starts the driver of
 * that PERIPHERAL, and the manifest check refuses a console of a compatible
 * string no row names. A UART is not a kind a give drives: what record a UART
 * gets follows from whether machine.console or machine.hostlink names it, not
 * from its compatible string, so these rows are a table of their own, which
 * neither reader of erx_device_kinds reads.
 */
static const erx_device_kind_t erx_uart_kinds[] = {
	{ ERX_MF_DEVICE_ROLE_UART, "arm,pl011", "console", "pl011" },
	{ ERX_MF_DEVICE_ROLE_UART, "brcm,bcm2835-aux-uart", "console", "mini_uart" },
};

#define ERX_FRAMEBUFFER_COMPATIBLE	"simple-framebuffer"

#define ERX_DEVICE_KINDS_COUNT	(sizeof(erx_device_kinds) / sizeof(erx_device_kinds[0]))
#define ERX_UART_KINDS_COUNT	(sizeof(erx_uart_kinds) / sizeof(erx_uart_kinds[0]))

#endif /* ERX_DEVICE_KINDS_H */
