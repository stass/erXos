/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The architecture layer of DMA by devices that are not cache-coherent
 * (docs/design-device-dma.md, "The architecture layer"): the cache maintenance, the three
 * barriers and the two sizes the handoff sequencer needs, under generic names. Each
 * architecture gives them in its own file, arch/<arch>/erx_dma_arch.c, and the host build in
 * arch/host/erx_dma_arch.c. Only erx_device.c's effect layer calls them, with the ranges, steps
 * and barrier kinds erx_device_dma_order chose; nothing here decides which to issue.
 */

#ifndef ERX_DMA_ARCH_H
#define ERX_DMA_ARCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* G: the cache-writeback granule, a power of two of at most ERX_DEVICE_GRANULE_MAX bytes. */
uint32_t	erx_dma_granule(void);
/* L: the smallest data cache line, a power of two of at most G bytes. */
uint32_t	erx_dma_line(void);

/* One clean to the point of coherency at each multiple of `step` from `start` below start + length. */
void	erx_dma_clean(volatile uint8_t *start, uint64_t length, uint32_t step);
/* The same, cleaning and invalidating. */
void	erx_dma_clean_inval(volatile uint8_t *start, uint64_t length, uint32_t step);

/*
 * After the handing over, before a write that tells the device; `completes` waits for the
 * maintenance issued before it, which only a device that is not coherent needs.
 */
void	erx_dma_publish_barrier(bool completes);
/* After the read of a device's report, before what it allows: orders loads and stores. */
void	erx_dma_report_barrier(void);
/* After taking back, before the reads of what came back: completes the maintenance before it. */
void	erx_dma_completion_barrier(void);

#endif /* ERX_DMA_ARCH_H */
