/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The hosted cache model. See erx_dma_model.h.
 */

#include "erx_dma_model.h"

#include <stdlib.h>
#include <string.h>

static bool
power_of_two(uint64_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

static bool
inside(const erx_dma_model_t *model, uint64_t offset, uint64_t length)
{
	return (offset <= model->size && length <= model->size - offset);
}

/* xorshift64*, enough for schedules a test replays from its seed. */
static uint64_t
draw(erx_dma_model_t *model)
{
	model->random ^= model->random >> 12;
	model->random ^= model->random << 25;
	model->random ^= model->random >> 27;
	return (model->random * UINT64_C(0x2545f4914f6cdd1d));
}

bool
erx_dma_model_init(erx_dma_model_t *model, uint64_t size, uint32_t granule, uint32_t line, uint64_t seed)
{
	memset(model, 0, sizeof(*model));
	if (!power_of_two(granule) || !power_of_two(line) || line > granule || size == 0 || size % granule != 0)
		return (false);
	model->size = size;
	model->granule = granule;
	model->line = line;
	model->memory = calloc(1, size);
	model->cache = calloc(1, size);
	model->lines = calloc(size / line, 1);
	model->random = seed != 0 ? seed : 1;
	model->evict_rate = 64;
	model->refetch_rate = 64;
	if (model->memory == NULL || model->cache == NULL || model->lines == NULL) {
		erx_dma_model_fini(model);
		return (false);
	}
	return (true);
}

void
erx_dma_model_fini(erx_dma_model_t *model)
{
	free(model->memory);
	free(model->cache);
	free(model->lines);
	memset(model, 0, sizeof(*model));
}

/* Line `index` loaded from memory, present and clean. */
static void
fetch(erx_dma_model_t *model, uint64_t index)
{
	memcpy(model->cache + index * model->line, model->memory + index * model->line, model->line);
	model->lines[index] = ERX_DMA_MODEL_PRESENT;
}

static void
write_back(erx_dma_model_t *model, uint64_t index)
{
	memcpy(model->memory + index * model->line, model->cache + index * model->line, model->line);
	model->lines[index] &= ~ERX_DMA_MODEL_DIRTY;
}

/* The CPU's access to one byte's line: present afterwards, and dirty if it stores. */
static uint8_t *
cpu_byte(erx_dma_model_t *model, uint64_t offset, bool store)
{
	const uint64_t index = offset / model->line;

	if ((model->lines[index] & ERX_DMA_MODEL_PRESENT) == 0)
		fetch(model, index);
	if (store)
		model->lines[index] |= ERX_DMA_MODEL_DIRTY;
	return (&model->cache[offset]);
}

bool
erx_dma_model_cpu_store(erx_dma_model_t *model, uint64_t offset, const void *bytes, uint64_t length)
{
	const uint8_t *const from = bytes;

	if (!inside(model, offset, length))
		return (false);
	for (uint64_t at = 0; at < length; at++)
		*cpu_byte(model, offset + at, true) = from[at];
	return (true);
}

bool
erx_dma_model_cpu_zero(erx_dma_model_t *model, uint64_t offset, uint64_t length)
{
	if (!inside(model, offset, length))
		return (false);
	for (uint64_t at = 0; at < length; at++)
		*cpu_byte(model, offset + at, true) = 0;
	return (true);
}

bool
erx_dma_model_cpu_load(erx_dma_model_t *model, uint64_t offset, void *bytes, uint64_t length)
{
	uint8_t *const to = bytes;

	if (!inside(model, offset, length))
		return (false);
	for (uint64_t at = 0; at < length; at++)
		to[at] = *cpu_byte(model, offset + at, false);
	return (true);
}

bool
erx_dma_model_device_read(const erx_dma_model_t *model, uint64_t offset, void *bytes, uint64_t length)
{
	if (!inside(model, offset, length))
		return (false);
	memcpy(bytes, model->memory + offset, length);
	return (true);
}

bool
erx_dma_model_device_write(erx_dma_model_t *model, uint64_t offset, const void *bytes, uint64_t length)
{
	if (!inside(model, offset, length))
		return (false);
	memcpy(model->memory + offset, bytes, length);
	return (true);
}

static bool
maintain(erx_dma_model_t *model, uint64_t offset, uint64_t length, uint32_t step, bool invalidate)
{
	if (!inside(model, offset, length) || step == 0)
		return (false);
	for (uint64_t at = 0; at < length; at += step) {
		const uint64_t index = (offset + at) / model->line;

		if ((model->lines[index] & ERX_DMA_MODEL_DIRTY) != 0)
			write_back(model, index);
		if (invalidate)
			model->lines[index] = 0;
	}
	return (true);
}

bool
erx_dma_model_clean(erx_dma_model_t *model, uint64_t offset, uint64_t length, uint32_t step)
{
	return (maintain(model, offset, length, step, false));
}

bool
erx_dma_model_clean_inval(erx_dma_model_t *model, uint64_t offset, uint64_t length, uint32_t step)
{
	return (maintain(model, offset, length, step, true));
}

/*
 * The granule of the first dirty line at or after a drawn line, written back whole: every
 * present line of it, dirty or not, since one writeback may overwrite the whole granule with
 * what the cache holds. The lines leave the cache.
 */
static void
evict(erx_dma_model_t *model)
{
	const uint64_t count = model->size / model->line;
	const uint64_t start = draw(model) % count;
	const uint64_t per_granule = model->granule / model->line;

	for (uint64_t step = 0; step < count; step++) {
		const uint64_t index = (start + step) % count;
		const uint64_t first = index - index % per_granule;

		if ((model->lines[index] & ERX_DMA_MODEL_DIRTY) == 0)
			continue;
		for (uint64_t line = first; line < first + per_granule; line++) {
			if ((model->lines[line] & ERX_DMA_MODEL_PRESENT) != 0)
				write_back(model, line);
			model->lines[line] = 0;
		}
		model->evictions++;
		return;
	}
}

/* A drawn line that is not dirty, loaded from memory as a speculative fetch loads it. */
static void
refetch(erx_dma_model_t *model)
{
	const uint64_t index = draw(model) % (model->size / model->line);

	if ((model->lines[index] & ERX_DMA_MODEL_DIRTY) != 0)
		return;
	fetch(model, index);
	model->refetches++;
}

void
erx_dma_model_tick(erx_dma_model_t *model)
{
	if (draw(model) % 256 < model->evict_rate)
		evict(model);
	if (draw(model) % 256 < model->refetch_rate)
		refetch(model);
}
