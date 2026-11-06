/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The queue core of erx_device (otp/erts/emulator/nifs/erxos/erx_device_queue.h) against a
 * hostile device. The input is a script: a byte of setup, the queue's size as a power of
 * two (its value mod 9); a u16, one less than its buffers' size; a byte whose bit 0 puts the
 * pool at the very top of the address space; then operations, each an opcode byte and its
 * operands:
 *
 *   0  post: a count byte, then per segment an offset u16, a length u16 and a byte whose
 *      bit 0 lets the device write it
 *   1  the used ring's index: any u16, as a device may write it
 *   2  the used ring's index: the core's next entry plus a byte, as an honest device would
 *   3  a used entry: any u32 id and any u32 length
 *   4  a used entry naming a posted head, picked by a byte, with a length u32 cut to the
 *      chain's writable bytes when bit 31 is clear
 *   5  reset
 *
 * The harness keeps its own record of every chain posted and checks after each step that a
 * post's descriptors are free ones, within its head's buffer and linked in order, with no flag but
 * NEXT and WRITE and none the device reads after one it writes; that a completion names a
 * chain posted and not completed, with its tag, and as ranges the chain's writable segments
 * in order, the last cut short, summing to the length; that descriptors are never lost or
 * shared; that a refusal of a post changes nothing; and that a broken queue refuses
 * everything until its reset.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_queue.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define FUZZ_BASE	UINT64_C(0x40000000)

typedef struct shadow_chain {
	bool		posted;
	uint64_t	tag;
	uint32_t	count;
	uint64_t	writable;
	uint32_t	buffer_length;
	erx_device_segment_t segments[ERX_DEVICE_CHAIN_MAX];
	uint16_t	descs[ERX_DEVICE_CHAIN_MAX];
} shadow_chain_t;

typedef struct script {
	const uint8_t	*bytes;
	size_t		left;
} script_t;

static erx_device_queue_t queue, before;
static shadow_chain_t shadow[ERX_DEVICE_QUEUE_SIZE_MAX];
static uint32_t owner[ERX_DEVICE_QUEUE_SIZE_MAX];	/* head + 1 of the chain holding a descriptor, or 0 */
static uint64_t next_tag;

static void
check(bool condition)
{
	if (!condition)
		abort();
}

static uint64_t
take(script_t *script, size_t bytes)
{
	uint64_t value = 0;

	for (size_t index = 0; index < bytes && script->left > 0; index++, script->left--, script->bytes++)
		value |= (uint64_t)script->bytes[0] << (8 * index);
	return (value);
}

static void
forget_all(void)
{
	memset(shadow, 0, sizeof(shadow));
	memset(owner, 0, sizeof(owner));
}

static void
check_accounting(void)
{
	uint32_t held = 0, chains = 0;

	for (uint32_t index = 0; index < queue.size; index++) {
		if (owner[index] != 0)
			held++;
		if (shadow[index].posted)
			chains++;
	}
	check(held + queue.free_count == queue.size);
	check(chains == queue.in_flight);
}

static void
post(script_t *script)
{
	const uint32_t count = (uint32_t)take(script, 1) % (ERX_DEVICE_CHAIN_MAX + 2);
	const uint32_t buffer_length = queue.buffer_size;
	uint64_t base;
	erx_device_segment_t segments[ERX_DEVICE_CHAIN_MAX + 1];
	erx_device_post_plan_t plan;
	shadow_chain_t *chain;
	uint64_t writable = 0;

	for (uint32_t index = 0; index < count; index++) {
		segments[index].offset = (uint32_t)take(script, 2);
		segments[index].length = (uint32_t)take(script, 2);
		segments[index].device_writes = (take(script, 1) & 1) != 0;
	}
	before = queue;
	if (!erx_device_queue_post(&queue, segments, count, next_tag, &plan)) {
		check(memcmp(&queue, &before, sizeof(queue)) == 0);
		return;
	}
	check(!before.broken && count >= 1 && count <= ERX_DEVICE_CHAIN_MAX && plan.count == count);
	check(plan.head == plan.descs[0].index && plan.avail_slot == (before.avail_idx & (queue.size - 1)));
	check(plan.avail_idx == (uint16_t)(before.avail_idx + 1));
	chain = &shadow[plan.head];
	base = queue.pool + (uint64_t)plan.head * queue.buffer_size;
	check(!chain->posted);
	for (uint32_t index = 0; index < count; index++) {
		const erx_device_desc_write_t *desc = &plan.descs[index];
		const bool last = index + 1 == count;
		const uint16_t expected = (uint16_t)((last ? 0 : ERX_VIRTQ_DESC_F_NEXT) |
		    (segments[index].device_writes ? ERX_VIRTQ_DESC_F_WRITE : 0));

		check(desc->index < queue.size && owner[desc->index] == 0);
		check(segments[index].length > 0 && (uint64_t)segments[index].offset + segments[index].length <= buffer_length);
		check(desc->addr == base + segments[index].offset && desc->len == segments[index].length);
		check(desc->flags == expected);
		check(last || desc->next == plan.descs[index + 1].index);
		check(index == 0 || !segments[index - 1].device_writes || segments[index].device_writes);
		owner[desc->index] = plan.head + 1u;
		chain->descs[index] = desc->index;
		chain->segments[index] = segments[index];
		if (segments[index].device_writes)
			writable += segments[index].length;
	}
	chain->posted = true;
	chain->tag = next_tag++;
	chain->count = count;
	chain->writable = writable;
	chain->buffer_length = buffer_length;
}

static void
used(uint16_t idx)
{
	const bool was_broken = queue.broken;
	uint32_t count;

	if (erx_device_queue_used(&queue, idx, &count)) {
		check(!was_broken && count == (uint16_t)(idx - queue.last_used) && count <= queue.in_flight);
		return;
	}
	check(queue.broken);
}

static void
complete(uint32_t id, uint32_t length)
{
	const bool was_broken = queue.broken;
	const uint32_t was_pending = queue.pending;
	erx_device_completion_t done;
	shadow_chain_t *chain;
	uint64_t sum = 0, left = length;
	uint32_t next_range = 0;

	if (!erx_device_queue_complete(&queue, id, length, &done)) {
		check(was_broken || was_pending == 0 || queue.broken);
		return;
	}
	check(!was_broken && was_pending > 0 && id < queue.size);
	chain = &shadow[id];
	check(chain->posted && done.tag == chain->tag && length <= chain->writable && done.length == length && done.buffer == id);
	/* The ranges are the chain's writable segments in order, the last cut to the length. */
	for (uint32_t index = 0; index < chain->count && left > 0; index++) {
		const erx_device_segment_t *segment = &chain->segments[index];
		const erx_device_segment_t *range;

		if (!segment->device_writes)
			continue;
		check(next_range < done.range_count);
		range = &done.ranges[next_range++];
		check(range->device_writes && range->offset == segment->offset);
		check(range->length == (left < segment->length ? left : segment->length));
		check((uint64_t)range->offset + range->length <= chain->buffer_length);
		left -= range->length;
		sum += range->length;
	}
	check(next_range == done.range_count && sum == length);
	for (uint32_t index = 0; index < chain->count; index++) {
		check(owner[chain->descs[index]] == id + 1u);
		owner[chain->descs[index]] = 0;
	}
	memset(chain, 0, sizeof(*chain));
}

static uint32_t
posted_head(uint32_t pick)
{
	for (uint32_t step = 0; step < queue.size; step++) {
		const uint32_t index = (pick + step) % queue.size;

		if (shadow[index].posted)
			return (index);
	}
	return (pick);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	script_t script = { .bytes = data, .left = size };
	uint32_t head, length;

	const uint32_t queue_size = 1u << (take(&script, 1) % 9);
	const uint32_t buffer_size = (uint32_t)take(&script, 2) + 1;
	const uint64_t pool = (take(&script, 1) & 1) != 0 ? UINT64_MAX - (uint64_t)queue_size * buffer_size + 1 : FUZZ_BASE;

	if (!erx_device_queue_init(&queue, queue_size, buffer_size, pool))
		abort();
	forget_all();
	next_tag = 0;
	while (script.left > 0) {
		switch (take(&script, 1) % 6) {
		case 0:
			post(&script);
			break;
		case 1:
			used((uint16_t)take(&script, 2));
			break;
		case 2:
			used((uint16_t)(queue.last_used + take(&script, 1)));
			break;
		case 3:
			head = (uint32_t)take(&script, 4);
			complete(head, (uint32_t)take(&script, 4));
			break;
		case 4:
			head = posted_head((uint32_t)take(&script, 1));
			length = (uint32_t)take(&script, 4);
			if ((length & 0x80000000u) == 0 && shadow[head].posted)
				length = (uint32_t)(length % (shadow[head].writable + 1));
			complete(head, length);
			break;
		default:
			erx_device_queue_reset(&queue);
			forget_all();
			check(!queue.broken && queue.free_count == queue.size && queue.in_flight == 0);
			break;
		}
		check_accounting();
	}
	return (0);
}
