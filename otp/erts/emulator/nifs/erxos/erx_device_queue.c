/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The queue's pure decisions. See erx_device_queue.h.
 */

#include "erx_device_queue.h"
#include "erx_device_dma.h"

#include "erx/abi.h"
#include "liberx/backend/core/mem.h"

bool
erx_device_queue_features(uint64_t wanted, uint64_t offered, uint64_t *accepted)
{
	const uint64_t version_1 = UINT64_C(1) << ERX_VIRTIO_F_VERSION_1;
	const uint64_t access_platform = UINT64_C(1) << ERX_VIRTIO_F_ACCESS_PLATFORM;

	*accepted = (wanted & offered & ERX_VIRTIO_F_DEVICE_TYPE_MASK) | version_1 | (offered & access_platform);
	return ((offered & version_1) != 0);
}

static bool
granule_valid(uint32_t granule)
{
	return (granule != 0 && granule <= ERX_DEVICE_GRANULE_MAX && (granule & (granule - 1)) == 0);
}

/* `value` rounded up to a power of two `to`; no caller's value comes near wrapping. */
static uint32_t
round_up(uint32_t value, uint32_t to)
{
	return ((value + to - 1) & ~(to - 1));
}

/*
 * The ring heads are u16 pairs and the trailing event word a u16. The used ring starts on a
 * granule and the rings end on one, so the CPU's region and the device's share none.
 */
bool
erx_device_queue_layout(uint32_t size, uint32_t granule, erx_device_queue_layout_t *layout)
{
	uint32_t avail_end, used;

	if (size == 0 || size > ERX_DEVICE_QUEUE_SIZE_MAX || (size & (size - 1)) != 0 || !granule_valid(granule))
		return (false);
	avail_end = size * ERX_VIRTQ_DESC_SIZE + ERX_VIRTQ_RING_HEAD_SIZE + size * 2 + 2;
	used = round_up(avail_end, granule > ERX_VIRTQ_USED_RING_ALIGN ? granule : ERX_VIRTQ_USED_RING_ALIGN);
	layout->desc = 0;
	layout->avail = size * ERX_VIRTQ_DESC_SIZE;
	layout->used = used;
	layout->bytes = round_up(used + ERX_VIRTQ_RING_HEAD_SIZE + size * ERX_VIRTQ_USED_ELEM_SIZE + 2, granule);
	return (true);
}

void
erx_device_queue_reset(erx_device_queue_t *queue)
{
	const uint32_t size = queue->size, buffer_size = queue->buffer_size, stride = queue->stride;
	const uint64_t pool = queue->pool;

	bzero(queue, sizeof(*queue));
	queue->size = size;
	queue->buffer_size = buffer_size;
	queue->stride = stride;
	queue->pool = pool;
	queue->free_count = size;
	for (uint32_t index = 0; index + 1 < size; index++)
		queue->next[index] = (uint16_t)(index + 1);
}

bool
erx_device_queue_init(erx_device_queue_t *queue, uint32_t size, uint32_t buffer_size, uint32_t granule, uint64_t pool)
{
	erx_device_queue_layout_t layout;
	uint64_t last;

	if (!erx_device_queue_layout(size, granule, &layout) || buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX ||
	    __builtin_add_overflow(pool, (uint64_t)size * round_up(buffer_size, granule) - 1, &last))
		return (false);
	queue->size = size;
	queue->buffer_size = buffer_size;
	queue->stride = round_up(buffer_size, granule);
	queue->pool = pool;
	erx_device_queue_reset(queue);
	return (true);
}

/*
 * Every segment non-empty and within the buffer, and
 * every segment the device writes after every one it reads, as virtio 1.2 section 2.7.4.2
 * requires: a device may answer any other order by asking for a reset.
 */
static bool
segments_fit(const erx_device_segment_t *segments, uint32_t count, uint32_t buffer_length)
{
	for (uint32_t index = 0; index < count; index++) {
		const erx_device_segment_t *segment = &segments[index];

		if (segment->length == 0 || (uint64_t)segment->offset + segment->length > buffer_length)
			return (false);
		if (index > 0 && segments[index - 1].device_writes && !segment->device_writes)
			return (false);
	}
	return (true);
}

bool
erx_device_queue_post(erx_device_queue_t *queue, const erx_device_segment_t *segments, uint32_t count,
    uint64_t tag, erx_device_post_plan_t *plan)
{
	erx_device_chain_t chain;
	uint64_t buffer_addr;
	uint32_t index;

	if (queue->broken || count == 0 || count > ERX_DEVICE_CHAIN_MAX || count > queue->free_count ||
	    !segments_fit(segments, count, queue->buffer_size))
		return (false);
	/* Field by field over zeroed records, so no padding of the caller's reaches a completion. */
	bzero(&chain, sizeof(chain));
	chain.posted = true;
	chain.count = count;
	chain.tag = tag;
	bzero(plan, sizeof(*plan));
	index = queue->free_head;
	/* Within the pool, whose last byte erx_device_queue_init checked is representable. */
	buffer_addr = queue->pool + (uint64_t)index * queue->stride;
	for (uint32_t step = 0; step < count; step++) {
		const erx_device_segment_t *segment = &segments[step];
		erx_device_desc_write_t *desc = &plan->descs[step];
		const bool last = step + 1 == count;

		desc->index = (uint16_t)index;
		desc->addr = buffer_addr + segment->offset;
		desc->len = segment->length;
		desc->flags = (uint16_t)((last ? 0 : ERX_VIRTQ_DESC_F_NEXT) |
		    (segment->device_writes ? ERX_VIRTQ_DESC_F_WRITE : 0));
		desc->next = last ? 0 : queue->next[index];
		chain.segments[step].offset = segment->offset;
		chain.segments[step].length = segment->length;
		chain.segments[step].device_writes = segment->device_writes;
		if (segment->device_writes)
			chain.writable += segment->length;
		index = queue->next[index];
	}
	plan->count = count;
	plan->head = plan->descs[0].index;
	plan->avail_slot = (uint16_t)(queue->avail_idx & (queue->size - 1));
	plan->avail_idx = (uint16_t)(queue->avail_idx + 1);
	queue->chains[plan->head] = chain;
	queue->free_head = index;
	queue->free_count -= count;
	queue->in_flight++;
	queue->avail_idx = plan->avail_idx;
	return (true);
}

bool
erx_device_queue_used(erx_device_queue_t *queue, uint16_t used_idx, uint32_t *count)
{
	const uint32_t fresh = (uint16_t)(used_idx - queue->last_used);

	if (queue->broken || fresh > queue->in_flight) {
		queue->broken = true;
		return (false);
	}
	queue->pending = fresh;
	*count = fresh;
	return (true);
}

uint32_t
erx_device_queue_used_slot(const erx_device_queue_t *queue)
{
	return (queue->last_used & (queue->size - 1));
}

/* Returns the chain's descriptors to the free list, walking the core's own links. */
static void
release_chain(erx_device_queue_t *queue, uint32_t head)
{
	erx_device_chain_t *chain = &queue->chains[head];
	uint32_t tail = head;

	for (uint32_t step = 1; step < chain->count; step++)
		tail = queue->next[tail];
	queue->next[tail] = (uint16_t)queue->free_head;
	queue->free_head = head;
	queue->free_count += chain->count;
	bzero(chain, sizeof(*chain));
}

bool
erx_device_queue_complete(erx_device_queue_t *queue, uint32_t id, uint32_t length,
    erx_device_completion_t *completion)
{
	const erx_device_chain_t *chain;
	uint32_t left = length;

	if (queue->broken || queue->pending == 0)
		return (false);
	if (id >= queue->size || !queue->chains[id].posted || length > queue->chains[id].writable) {
		queue->broken = true;
		return (false);
	}
	chain = &queue->chains[id];
	bzero(completion, sizeof(*completion));
	completion->tag = chain->tag;
	completion->buffer = id;
	completion->length = length;
	for (uint32_t step = 0; step < chain->count && left > 0; step++) {
		erx_device_segment_t range = chain->segments[step];

		if (!range.device_writes)
			continue;
		if (range.length > left)
			range.length = left;
		left -= range.length;
		completion->ranges[completion->range_count++] = range;
	}
	release_chain(queue, id);
	queue->in_flight--;
	queue->pending--;
	queue->last_used++;
	return (true);
}

/* -------------------------------------------------------------------------------------------
 * The split ring as a descriptor form
 */

void
erx_device_queue_form(const erx_device_queue_layout_t *layout, uint32_t size, erx_dma_context_t *context)
{
	context->address_bits = 64;
	context->publication = layout->avail + offsetof(erx_virtq_ring_head_t, idx);
	context->publication_width = sizeof(((erx_virtq_ring_head_t *)0)->idx);
	context->descriptors = layout->desc;
	context->descriptor_count = size;
	context->descriptor_size = ERX_VIRTQ_DESC_SIZE;
	context->address_field = offsetof(erx_virtq_desc_t, addr);
	context->address_width = sizeof(((erx_virtq_desc_t *)0)->addr);
	context->length_field = offsetof(erx_virtq_desc_t, len);
	context->length_width = sizeof(((erx_virtq_desc_t *)0)->len);
}

void
erx_device_queue_view(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, uint64_t pool_offset,
    bool installed, erx_dma_state_t *state)
{
	state->count = 0;
	state->regions[state->count++] = (erx_dma_region_t){ .offset = 0, .length = layout->used, .kind = ERX_DMA_RING,
	    .writer = ERX_DMA_CPU };
	state->regions[state->count++] = (erx_dma_region_t){ .offset = layout->used, .length = layout->bytes - layout->used,
	    .kind = ERX_DMA_RING, .writer = installed ? ERX_DMA_DEVICE : ERX_DMA_CPU };
	for (uint32_t buffer = 0; buffer < queue->size; buffer++)
		state->regions[state->count++] = (erx_dma_region_t){ .offset = pool_offset + (uint64_t)buffer * queue->stride,
		    .length = queue->stride, .kind = ERX_DMA_BUFFER,
		    .writer = queue->chains[buffer].posted ? ERX_DMA_DEVICE : ERX_DMA_CPU };
}

static erx_dma_step_t
ring_write(erx_dma_source_t source, uint64_t offset, uint32_t width, uint64_t value, uint64_t extent)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = source, .width = width,
	    .reg_high = ERX_DMA_NO_REGISTER, .offset = offset, .value = value, .extent = extent });
}

static erx_dma_step_t
register_publish(uint32_t reg, uint64_t value)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE, .width = 4,
	    .reg = reg, .reg_high = ERX_DMA_NO_REGISTER, .value = value });
}

static erx_dma_step_t
address_publish(const uint32_t words[2], uint64_t addr, uint64_t extent)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
	    .reg = words[0], .reg_high = words[1], .value = addr, .extent = extent });
}

static erx_dma_step_t
zeros(uint64_t offset, uint64_t length)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_ZEROS,
	    .reg_high = ERX_DMA_NO_REGISTER, .offset = offset, .length = length });
}

static erx_dma_step_t
report(uint64_t offset, uint32_t width)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_MEMORY, .width = width,
	    .reg_high = ERX_DMA_NO_REGISTER, .offset = offset });
}

uint32_t
erx_device_queue_install_steps(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
    const erx_device_queue_registers_t *regs, uint32_t index, uint64_t rings_addr, erx_dma_step_t *steps)
{
	const uint32_t size = queue->size;
	uint32_t count = 0;

	steps[count++] = zeros(0, layout->used);
	steps[count++] = zeros(layout->used, layout->bytes - layout->used);
	steps[count++] = register_publish(regs->sel, index);
	steps[count++] = register_publish(regs->num, size);
	steps[count++] = address_publish(regs->desc, rings_addr + layout->desc, (uint64_t)size * ERX_VIRTQ_DESC_SIZE);
	steps[count++] = address_publish(regs->driver, rings_addr + layout->avail, ERX_VIRTQ_RING_HEAD_SIZE + 2u * size + 2u);
	steps[count++] = address_publish(regs->device, rings_addr + layout->used,
	    ERX_VIRTQ_RING_HEAD_SIZE + (uint64_t)size * ERX_VIRTQ_USED_ELEM_SIZE + 2u);
	steps[count++] = register_publish(regs->ready, 1);
	return (count);
}

uint32_t
erx_device_queue_post_steps(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
    uint64_t device_base, uint64_t pool_offset,
    const erx_device_post_plan_t *plan, const erx_device_segment_t *segments, const uint8_t *const *bytes,
    const erx_device_queue_registers_t *regs, uint32_t index, erx_dma_step_t *steps)
{
	const uint64_t buffer = pool_offset + (uint64_t)plan->head * queue->stride;
	uint32_t count = 0;

	for (uint32_t segment = 0; segment < plan->count; segment++) {
		const erx_device_desc_write_t *const desc = &plan->descs[segment];
		const uint64_t at = layout->desc + (uint64_t)desc->index * ERX_VIRTQ_DESC_SIZE;

		if (!segments[segment].device_writes)
			steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_BYTES,
			    .reg_high = ERX_DMA_NO_REGISTER, .offset = buffer + segments[segment].offset,
			    .length = segments[segment].length, .bytes = bytes[segment] };
		/* The address from the device base and the buffer's offset, the same the view's region names. */
		steps[count++] = ring_write(ERX_DMA_ADDRESS, at + offsetof(erx_virtq_desc_t, addr), 8,
		    device_base + buffer + segments[segment].offset, desc->len);
		steps[count++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, len), 4, desc->len, 0);
		steps[count++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, flags), 2, desc->flags, 0);
		steps[count++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, next), 2, desc->next, 0);
	}
	steps[count++] = ring_write(ERX_DMA_VALUE, layout->avail + ERX_VIRTQ_RING_HEAD_SIZE + 2u * plan->avail_slot, 2,
	    plan->head, 0);
	steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_MEMORY, .source = ERX_DMA_VALUE,
	    .width = 2, .reg_high = ERX_DMA_NO_REGISTER, .offset = layout->avail + offsetof(erx_virtq_ring_head_t, idx),
	    .value = plan->avail_idx };
	steps[count++] = register_publish(regs->notify, index);
	return (count);
}

void
erx_device_queue_index_report(const erx_device_queue_layout_t *layout, erx_dma_step_t *step)
{
	*step = report(layout->used + offsetof(erx_virtq_ring_head_t, idx), 2);
}

uint32_t
erx_device_queue_entry_reports(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
    uint32_t fresh, erx_dma_step_t *steps)
{
	const uint32_t first = erx_device_queue_used_slot(queue);
	uint32_t count = 0;

	for (uint32_t entry = 0; entry < fresh && entry < queue->size; entry++) {
		const uint64_t at = layout->used + ERX_VIRTQ_RING_HEAD_SIZE +
		    (uint64_t)((first + entry) & (queue->size - 1)) * ERX_VIRTQ_USED_ELEM_SIZE;

		steps[count++] = report(at + offsetof(erx_virtq_used_elem_t, id), 4);
		steps[count++] = report(at + offsetof(erx_virtq_used_elem_t, len), 4);
	}
	return (count);
}

uint32_t
erx_device_queue_copy_steps(const erx_device_queue_t *queue, uint64_t pool_offset, const erx_device_completion_t *completions,
    uint32_t count, erx_dma_step_t *steps)
{
	uint32_t made = 0;

	for (uint32_t done = 0; done < count; done++) {
		const erx_device_completion_t *const completion = &completions[done];
		const uint64_t buffer = pool_offset + (uint64_t)completion->buffer * queue->stride;

		for (uint32_t range = 0; range < completion->range_count; range++)
			steps[made++] = (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY,
			    .reg_high = ERX_DMA_NO_REGISTER, .offset = buffer + completion->ranges[range].offset,
			    .length = completion->ranges[range].length };
	}
	return (made);
}
