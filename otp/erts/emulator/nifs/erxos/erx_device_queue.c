/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The queue's pure decisions. See erx_device_queue.h.
 */

#include "erx_device_queue.h"

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

/* The ring heads are u16 pairs and the trailing event word a u16; the used ring is aligned. */
bool
erx_device_queue_layout(uint32_t size, erx_device_queue_layout_t *layout)
{
	uint32_t avail_end, used;

	if (size == 0 || size > ERX_DEVICE_QUEUE_SIZE_MAX || (size & (size - 1)) != 0)
		return (false);
	avail_end = size * ERX_VIRTQ_DESC_SIZE + ERX_VIRTQ_RING_HEAD_SIZE + size * 2 + 2;
	used = (avail_end + ERX_VIRTQ_USED_RING_ALIGN - 1) & ~(ERX_VIRTQ_USED_RING_ALIGN - 1);
	layout->desc = 0;
	layout->avail = size * ERX_VIRTQ_DESC_SIZE;
	layout->used = used;
	layout->bytes = used + ERX_VIRTQ_RING_HEAD_SIZE + size * ERX_VIRTQ_USED_ELEM_SIZE + 2;
	return (true);
}

void
erx_device_queue_reset(erx_device_queue_t *queue)
{
	const uint32_t size = queue->size, buffer_size = queue->buffer_size;
	const uint64_t pool = queue->pool;

	bzero(queue, sizeof(*queue));
	queue->size = size;
	queue->buffer_size = buffer_size;
	queue->pool = pool;
	queue->free_count = size;
	for (uint32_t index = 0; index + 1 < size; index++)
		queue->next[index] = (uint16_t)(index + 1);
}

bool
erx_device_queue_init(erx_device_queue_t *queue, uint32_t size, uint32_t buffer_size, uint64_t pool)
{
	erx_device_queue_layout_t layout;
	uint64_t last;

	if (!erx_device_queue_layout(size, &layout) || buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX ||
	    __builtin_add_overflow(pool, (uint64_t)size * buffer_size - 1, &last))
		return (false);
	queue->size = size;
	queue->buffer_size = buffer_size;
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
	buffer_addr = queue->pool + (uint64_t)index * queue->buffer_size;
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
