/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_MANIFEST_DMA_H
#define ERX_BACKEND_MANIFEST_DMA_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi_reader.h"

/*
 * The total of every device's dma_memory in the manifest's device table into *total:
 * the memory the root makes for devices, once each, which sizes the stopgap's
 * contiguous pool. The packer counts the same total (the admission report's
 * dma_memory). Returns false when a device cannot be read or the total overflows.
 * boot_manifest.c defines it; this header stands alone because the root reads it
 * beside erx/pack.h, whose boot inputs boot_info.h names too.
 */
bool	erx_boot_manifest_dma_total(const erx_manifest_view_t *view, uint64_t *total);

#endif /* ERX_BACKEND_MANIFEST_DMA_H */
