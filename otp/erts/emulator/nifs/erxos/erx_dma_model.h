/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The hosted model of a CPU cache in front of a device that is not cache-coherent
 * (docs/design-device-dma.md, Verification, "The non-coherent stand-in"). The hosted build's
 * DMA memory is kept twice: a cache of lines of L bytes, each present or not and dirty or
 * not, and the memory behind it. The CPU's stores and loads go through the cache; the
 * stand-in device reads and writes the memory alone. Maintenance acts on the one line holding
 * its address: a clean writes a dirty line back, a clean and invalidate also drops it.
 *
 * From a seeded random source, erx_dma_model_tick evicts dirty granules and refetches clean
 * lines, as a CPU may at any point: an eviction writes back every present line of a whole
 * granule of G bytes, the most one writeback can overwrite (the cache-writeback granule), and
 * a refetch loads a line from memory as a speculative fetch does. So a missing clean leaves
 * the device reading stale bytes, a missing clean and invalidate leaves the CPU reading a
 * stale line, and a dirty line left in memory the device writes can overwrite what it wrote.
 *
 * Offsets are bytes from the start of the memory. Every call is false, changing nothing, for
 * a range outside it.
 */

#ifndef ERX_DMA_MODEL_H
#define ERX_DMA_MODEL_H

#include <stdbool.h>
#include <stdint.h>

typedef struct erx_dma_model {
	uint64_t	size;
	uint32_t	granule;	/* G */
	uint32_t	line;		/* L, at most G */
	uint8_t		*memory;	/* what the device sees */
	uint8_t		*cache;		/* each line's bytes as the CPU sees them while present */
	uint8_t		*lines;		/* each line's ERX_DMA_MODEL_PRESENT and ERX_DMA_MODEL_DIRTY */
	uint64_t	random;		/* the seeded source's state, never 0 */
	uint32_t	evict_rate;	/* chance in 256 that a tick evicts a dirty granule */
	uint32_t	refetch_rate;	/* chance in 256 that a tick refetches a clean line */
	uint64_t	evictions;	/* granules written back by ticks */
	uint64_t	refetches;	/* lines loaded by ticks */
} erx_dma_model_t;

#define ERX_DMA_MODEL_PRESENT	0x1u
#define ERX_DMA_MODEL_DIRTY	0x2u

/*
 * A model of `size` zero bytes, nothing cached, for a granule and a line that are powers of
 * two with line <= granule and size a positive multiple of granule. False for anything else
 * or when memory runs out.
 */
bool	erx_dma_model_init(erx_dma_model_t *model, uint64_t size, uint32_t granule, uint32_t line, uint64_t seed);
void	erx_dma_model_fini(erx_dma_model_t *model);

/* The CPU's side: through the cache, fetching a line that is not present. */
bool	erx_dma_model_cpu_store(erx_dma_model_t *model, uint64_t offset, const void *bytes, uint64_t length);
bool	erx_dma_model_cpu_zero(erx_dma_model_t *model, uint64_t offset, uint64_t length);
bool	erx_dma_model_cpu_load(erx_dma_model_t *model, uint64_t offset, void *bytes, uint64_t length);

/* The device's side: the memory alone. */
bool	erx_dma_model_device_read(const erx_dma_model_t *model, uint64_t offset, void *bytes, uint64_t length);
bool	erx_dma_model_device_write(erx_dma_model_t *model, uint64_t offset, const void *bytes, uint64_t length);

/*
 * One maintenance instruction at each of offset, offset + step, ... below offset + length,
 * each acting on the line that holds its address. A step larger than the line misses lines.
 */
bool	erx_dma_model_clean(erx_dma_model_t *model, uint64_t offset, uint64_t length, uint32_t step);
bool	erx_dma_model_clean_inval(erx_dma_model_t *model, uint64_t offset, uint64_t length, uint32_t step);

/* Perhaps an eviction of a dirty granule, perhaps a refetch of a clean line, as the source draws. */
void	erx_dma_model_tick(erx_dma_model_t *model);

#endif /* ERX_DMA_MODEL_H */
