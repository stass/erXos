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
 * a row's role and compatible string gets a record with the row's names,
 * -erx given, in the system domain's boot page and in a holder domain's
 * (docs/design-stopgap.md, "Boot information"). ROLE is the
 * record's role word and PERIPHERAL the CMSIS-SVD peripheral the device
 * NIF opens. The root's reader (liberx/backend/core/boot_manifest.c) and
 * the domain library's boot view (liberx/system/dom_boot_view.c) both read
 * this table, so a further kind is one more row here.
 */
typedef struct erx_device_kind {
	uint32_t	 role;		/* ERX_MF_DEVICE_ROLE_* */
	const char	*compatible;	/* the platform record's compatible string */
	const char	*role_word;	/* the record's ROLE */
	const char	*peripheral;	/* its PERIPHERAL, as the CMSIS-SVD source names it */
} erx_device_kind_t;

static const erx_device_kind_t erx_device_kinds[] = {
	{ ERX_MF_DEVICE_ROLE_BLOCK, "virtio,mmio", "block", "virtio_mmio" },
	{ ERX_MF_DEVICE_ROLE_NETWORK, "virtio,mmio", "net", "virtio_mmio" },
	{ ERX_MF_DEVICE_ROLE_NETWORK, "brcm,bcm2711-genet-v5", "net", "genet" },
};

#define ERX_DEVICE_KINDS_COUNT	(sizeof(erx_device_kinds) / sizeof(erx_device_kinds[0]))

#endif /* ERX_DEVICE_KINDS_H */
