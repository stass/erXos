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

	bzero(queue, sizeof(*queue));
	queue->size = size;
	queue->buffer_size = buffer_size;
	queue->stride = stride;
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
erx_device_queue_post(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, uint64_t device_base,
    uint64_t pool_offset, const erx_device_segment_t *segments, const uint8_t *const *bytes, uint32_t count, uint64_t tag,
    const erx_device_queue_registers_t *regs, uint32_t index, erx_dma_step_t *steps)
{
	erx_device_chain_t chain;
	uint64_t buffer;
	uint32_t head, desc, made = 0;
	uint16_t avail_slot;

	if (queue->broken || count == 0 || count > ERX_DEVICE_CHAIN_MAX || count > queue->free_count ||
	    !segments_fit(segments, count, queue->buffer_size))
		return (0);
	/* Field by field over a zeroed record, so no padding of the caller's reaches a completion. */
	bzero(&chain, sizeof(chain));
	chain.posted = true;
	chain.count = count;
	chain.tag = tag;
	head = desc = queue->free_head;
	buffer = pool_offset + (uint64_t)head * queue->stride;
	for (uint32_t segment = 0; segment < count; segment++) {
		const erx_device_segment_t *const taken = &segments[segment];
		const bool last = segment + 1 == count;
		const uint64_t at = layout->desc + (uint64_t)desc * ERX_VIRTQ_DESC_SIZE;
		const uint16_t flags = (uint16_t)((last ? 0 : ERX_VIRTQ_DESC_F_NEXT) |
		    (taken->device_writes ? ERX_VIRTQ_DESC_F_WRITE : 0));

		if (!taken->device_writes)
			steps[made++] = (erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_BYTES,
			    .reg_high = ERX_DMA_NO_REGISTER, .offset = buffer + taken->offset, .length = taken->length,
			    .bytes = bytes[segment] };
		/* The address from the device base and the buffer's offset, the same the view's region names. */
		steps[made++] = ring_write(ERX_DMA_ADDRESS, at + offsetof(erx_virtq_desc_t, addr), 8,
		    device_base + buffer + taken->offset, taken->length);
		steps[made++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, len), 4, taken->length, 0);
		steps[made++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, flags), 2, flags, 0);
		steps[made++] = ring_write(ERX_DMA_VALUE, at + offsetof(erx_virtq_desc_t, next), 2,
		    last ? 0 : queue->next[desc], 0);
		chain.segments[segment].offset = taken->offset;
		chain.segments[segment].length = taken->length;
		chain.segments[segment].device_writes = taken->device_writes;
		if (taken->device_writes)
			chain.writable += taken->length;
		desc = queue->next[desc];
	}
	avail_slot = (uint16_t)(queue->avail_idx & (queue->size - 1));
	queue->avail_idx = (uint16_t)(queue->avail_idx + 1);
	steps[made++] = ring_write(ERX_DMA_VALUE, layout->avail + ERX_VIRTQ_RING_HEAD_SIZE + 2u * avail_slot, 2, head, 0);
	steps[made++] = (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_MEMORY, .source = ERX_DMA_VALUE,
	    .width = 2, .reg_high = ERX_DMA_NO_REGISTER, .offset = layout->avail + offsetof(erx_virtq_ring_head_t, idx),
	    .value = queue->avail_idx };
	steps[made++] = register_publish(regs->notify, index);
	queue->chains[head] = chain;
	queue->free_head = desc;
	queue->free_count -= count;
	queue->in_flight++;
	return (made);
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

/* The rounds of the split ring's calls, by the plan each makes; the round after the last plan ends the call. */
enum {
	INSTALL_RESET = 0,		/* every region taken back */
	INSTALL_WRITE = 1,		/* the rings zeroed, their addresses published, the queue ready */
};
enum {
	POST_WRITE = 0,			/* the chain, its available entry, the index and the doorbell */
};
enum {
	COMPLETE_READ_INDEX = 0,	/* the used index observed */
	COMPLETE_READ_ENTRIES = 1,	/* the entries it announces observed */
	COMPLETE_TAKE_BACK = 2,		/* the completed chains' buffers taken back, a copy per range */
};

/* A plan of `count` steps of `call` from the round's steps, and the installed queue's state after it. */
static void
round_plan(const erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, const erx_dma_request_t *request,
    erx_dma_call_t call, uint32_t count, bool installed, erx_dma_round_t *round)
{
	round->call = call;
	round->count = count;
	erx_device_queue_view(queue, layout, request->pool_offset, installed, round->after);
}

static void
queue_post(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, const erx_device_queue_registers_t *regs,
    const erx_dma_request_t *request, erx_dma_round_t *round)
{
	erx_device_segment_t segments[ERX_DEVICE_CHAIN_MAX];
	const uint8_t *bytes[ERX_DEVICE_CHAIN_MAX];
	uint32_t offset = 0, count;

	if (request->count == 0 || request->count > ERX_DEVICE_CHAIN_MAX) {
		erx_dma_round_end(round, ERX_EINVAL);
		return;
	}
	for (uint32_t step = 0; step < request->count; step++) {
		const erx_dma_piece_t *const piece = &request->pieces[step];

		if (piece->length > queue->buffer_size - offset) {
			erx_dma_round_end(round, ERX_EINVAL);
			return;
		}
		segments[step] = (erx_device_segment_t){ .offset = offset, .length = piece->length,
		    .device_writes = piece->device_writes };
		bytes[step] = piece->bytes;
		offset += piece->length;
	}
	if (!request->ready || queue->broken) {
		erx_dma_round_end(round, ERX_ECORRUPT);
		return;
	}
	if (queue->free_count < request->count) {
		erx_dma_round_end(round, ERX_EWOULDBLOCK);
		return;
	}
	count = erx_device_queue_post(queue, layout, request->device_base, request->pool_offset, segments, bytes,
	    request->count, request->tag, regs, request->queue, round->steps);
	if (count == 0) {
		erx_dma_round_end(round, ERX_EINVAL);
		return;
	}
	/*
	 * The sequencer zeroes the head's buffer outside the bytes the device reads, so what a
	 * completion copies is the device's bytes or zeros, never an earlier request's (a region's
	 * entry among them).
	 */
	round_plan(queue, layout, request, ERX_DMA_CALL_POST, count, true, round);
}

static void
queue_complete(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout, const erx_dma_request_t *request,
    erx_dma_round_t *round)
{
	const uint32_t max = request->answers_max < ERX_DMA_ANSWERS_MAX ? request->answers_max : ERX_DMA_ANSWERS_MAX;
	erx_device_completion_t completion;
	uint32_t fresh, done = 0, count = 0;
	uint64_t copied = 0;

	switch (round->round) {
	case COMPLETE_READ_INDEX:
		erx_device_queue_index_report(layout, &round->steps[0]);
		erx_dma_round_observe(round, 1);
		return;
	case COMPLETE_READ_ENTRIES:
		if (!erx_device_queue_used(queue, (uint16_t)round->values[0], &fresh)) {
			erx_dma_round_end(round, ERX_ECORRUPT);
			return;
		}
		count = erx_device_queue_entry_reports(queue, layout, fresh < max ? fresh : max, round->steps);
		if (count == 0) {
			erx_dma_round_end(round, ERX_OK);
			return;
		}
		erx_dma_round_observe(round, count);
		return;
	case COMPLETE_TAKE_BACK:
		/*
		 * Each entry's two reports, its id then its length (erx_device_queue_entry_reports), at
		 * most max entries, whatever the round's value count says.
		 */
		fresh = round->value_count / ERX_DEVICE_QUEUE_ENTRY_REPORTS;
		if (fresh > max)
			fresh = max;
		while (done < fresh && copied < request->bytes_max && erx_device_queue_complete(queue,
		    (uint32_t)round->values[ERX_DEVICE_QUEUE_ENTRY_REPORTS * done],
		    (uint32_t)round->values[ERX_DEVICE_QUEUE_ENTRY_REPORTS * done + 1], &completion)) {
			const uint32_t copies = erx_device_queue_copy_steps(queue, request->pool_offset, &completion, 1,
			    round->steps + count);

			round->answers[done++] = (erx_dma_answer_t){ .tag = completion.tag, .length = completion.length,
			    .copies = copies };
			copied += completion.length;
			count += copies;
		}
		if (done == 0) {
			erx_dma_round_end(round, queue->broken ? ERX_ECORRUPT : ERX_OK);
			return;
		}
		round->answer_count = done;
		round_plan(queue, layout, request, ERX_DMA_CALL_COMPLETE, count, true, round);
		return;
	default:
		erx_dma_round_end(round, ERX_OK);
		return;
	}
}

void
erx_device_queue_round(erx_device_queue_t *queue, const erx_device_queue_layout_t *layout,
    const erx_device_queue_registers_t *regs, const erx_dma_request_t *request, erx_dma_round_t *round)
{
	switch (request->kind) {
	case ERX_DMA_REQUEST_INSTALL:
		if (round->round == INSTALL_RESET) {
			erx_device_queue_reset(queue);
			round_plan(queue, layout, request, ERX_DMA_CALL_RESET, 0, false, round);
		} else if (round->round == INSTALL_WRITE) {
			round_plan(queue, layout, request, ERX_DMA_CALL_INSTALL, erx_device_queue_install_steps(queue, layout,
			    regs, request->queue, request->device_base, round->steps), true, round);
		} else {
			erx_dma_round_end(round, ERX_OK);
		}
		return;
	case ERX_DMA_REQUEST_POST:
		if (round->round == POST_WRITE)
			queue_post(queue, layout, regs, request, round);
		else
			erx_dma_round_end(round, ERX_OK);
		return;
	case ERX_DMA_REQUEST_COMPLETE:
		queue_complete(queue, layout, request, round);
		return;
	case ERX_DMA_REQUEST_IDLE:
	case ERX_DMA_REQUEST_START:
		break;
	}
	/* The split ring's idle report and start are virtio's status handshake, not DMA. */
	erx_dma_round_end(round, ERX_ENOTSUP);
}
