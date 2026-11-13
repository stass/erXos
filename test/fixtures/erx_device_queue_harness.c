/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The queue core's cases (otp/erts/emulator/nifs/erxos/erx_device_queue.h), run on the host
 * under the address and undefined sanitizers by test/host/erx_device_queue_test.rb. A block
 * request's chain is the running example: a 16-byte header the device reads, data it writes
 * and a status byte it writes.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_queue.h"

#define CHECK(condition) do {						\
	if (!(condition)) {						\
		fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
		exit(1);						\
	}								\
} while (0)

static const uint64_t buffer_addr = UINT64_C(0x40100000);
static const erx_device_segment_t read_chain[] = {
	{ .offset = 0, .length = 16, .device_writes = false },
	{ .offset = 16, .length = 512, .device_writes = true },
	{ .offset = 528, .length = 1, .device_writes = true },
};

static erx_device_queue_t queue, before;

static void
layouts(void)
{
	erx_device_queue_layout_t layout;

	CHECK(erx_device_queue_layout(8, 1, &layout));
	CHECK(layout.desc == 0 && layout.avail == 128 && layout.used == 152 && layout.bytes == 222);
	CHECK(layout.used % ERX_VIRTQ_USED_RING_ALIGN == 0);
	CHECK(erx_device_queue_layout(1, 1, &layout) && erx_device_queue_layout(ERX_DEVICE_QUEUE_SIZE_MAX, 1, &layout));
	CHECK(!erx_device_queue_layout(0, 1, &layout) && !erx_device_queue_layout(3, 1, &layout));
	CHECK(!erx_device_queue_layout(2 * ERX_DEVICE_QUEUE_SIZE_MAX, 1, &layout));
	CHECK(!erx_device_queue_init(&queue, 6, 1024, 1, buffer_addr));
	CHECK(!erx_device_queue_init(&queue, 8, 0, 1, buffer_addr));
	CHECK(!erx_device_queue_init(&queue, 8, ERX_DEVICE_BUFFER_MAX + 1, 1, buffer_addr));
	/* A pool whose last byte is the address space's last is whole; one byte further is not. */
	CHECK(erx_device_queue_init(&queue, 8, 1024, 1, UINT64_MAX - 8 * 1024 + 1));
	CHECK(!erx_device_queue_init(&queue, 8, 1024, 1, UINT64_MAX - 8 * 1024 + 2));
	/* On a granule of 64: the used ring starts on one, the rings end on one, and buffers of 200 bytes lie 256 apart. */
	CHECK(erx_device_queue_layout(8, 64, &layout));
	CHECK(layout.avail == 128 && layout.used == 192 && layout.bytes == 320);
	CHECK(!erx_device_queue_layout(8, 3, &layout) && !erx_device_queue_layout(8, 0, &layout));
	CHECK(!erx_device_queue_layout(8, 2 * ERX_DEVICE_GRANULE_MAX, &layout));
	CHECK(erx_device_queue_init(&queue, 8, 200, 64, buffer_addr) && queue.stride == 256 && queue.buffer_size == 200);
	CHECK(!erx_device_queue_init(&queue, 8, 200, 48, buffer_addr));
	/* The pool's end is counted at the stride: 8 buffers of 256 bytes. */
	CHECK(erx_device_queue_init(&queue, 8, 200, 64, UINT64_MAX - 8 * 256 + 1));
	CHECK(!erx_device_queue_init(&queue, 8, 200, 64, UINT64_MAX - 8 * 256 + 2));
	{
		const erx_device_segment_t one = { 0, 10, false };
		erx_device_post_plan_t plan;

		CHECK(erx_device_queue_post(&queue, &one, 1, 1, &plan) && erx_device_queue_post(&queue, &one, 1, 2, &plan));
		CHECK(plan.head == 1 && plan.descs[0].addr == UINT64_MAX - 8 * 256 + 1 + 256);
		erx_device_queue_reset(&queue);
		CHECK(queue.stride == 256);
	}
}

static void
post_and_complete(void)
{
	erx_device_post_plan_t plan, first;
	erx_device_completion_t done;
	uint32_t count;

	CHECK(erx_device_queue_init(&queue, 8, 1024, 1, buffer_addr));
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 77, &plan));
	CHECK(plan.count == 3 && plan.head == 0 && plan.avail_slot == 0 && plan.avail_idx == 1);
	CHECK(plan.descs[0].addr == buffer_addr && plan.descs[0].len == 16);
	CHECK(plan.descs[0].flags == ERX_VIRTQ_DESC_F_NEXT && plan.descs[0].next == plan.descs[1].index);
	CHECK(plan.descs[1].addr == buffer_addr + 16 && plan.descs[1].len == 512);
	CHECK(plan.descs[1].flags == (ERX_VIRTQ_DESC_F_NEXT | ERX_VIRTQ_DESC_F_WRITE));
	CHECK(plan.descs[1].next == plan.descs[2].index);
	CHECK(plan.descs[2].flags == ERX_VIRTQ_DESC_F_WRITE && plan.descs[2].next == 0);
	CHECK(queue.free_count == 5 && queue.in_flight == 1);

	/* Nothing announced: completing is refused without breaking the queue. */
	CHECK(!erx_device_queue_complete(&queue, 0, 513, &done) && !queue.broken);
	CHECK(erx_device_queue_used(&queue, 0, &count) && count == 0);
	CHECK(erx_device_queue_used(&queue, 1, &count) && count == 1);
	CHECK(erx_device_queue_used_slot(&queue) == 0);
	CHECK(erx_device_queue_complete(&queue, plan.head, 513, &done));
	CHECK(done.tag == 77 && done.buffer == 0 && done.length == 513 && done.range_count == 2);
	CHECK(done.ranges[0].offset == 16 && done.ranges[0].length == 512);
	CHECK(done.ranges[1].offset == 528 && done.ranges[1].length == 1);
	CHECK(queue.free_count == 8 && queue.in_flight == 0 && queue.last_used == 1);

	/* A device that wrote less: the ranges stop at its length. */
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 78, &plan));
	CHECK(plan.avail_slot == 1);
	/* Each chain addresses the buffer of its head: descriptor 0 came back first on the free list. */
	CHECK(plan.head == 0 && plan.descs[0].addr == buffer_addr && plan.descs[1].addr == buffer_addr + 16);
	CHECK(erx_device_queue_used(&queue, 2, &count) && count == 1);
	CHECK(erx_device_queue_complete(&queue, plan.head, 100, &done));
	CHECK(done.range_count == 1 && done.ranges[0].offset == 16 && done.ranges[0].length == 100);
	CHECK(erx_device_queue_used(&queue, 2, &count) && count == 0);

	/* Two chains in flight address distinct buffers, each its head's. */
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 79, &plan));
	first = plan;
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 80, &plan));
	CHECK(first.head != plan.head);
	CHECK(first.descs[0].addr == buffer_addr + (uint64_t)first.head * 1024);
	CHECK(plan.descs[0].addr == buffer_addr + (uint64_t)plan.head * 1024);
	CHECK(erx_device_queue_used(&queue, 3, &count) && count == 1);
	CHECK(erx_device_queue_complete(&queue, first.head, 1, &done) && done.buffer == first.head && done.tag == 79);
}

/* Each refused post changes nothing at all. */
static void
refused_posts(void)
{
	const erx_device_segment_t outside[] = { { .offset = 1000, .length = 25, .device_writes = true } };
	const erx_device_segment_t empty[] = { { .offset = 0, .length = 0, .device_writes = true } };
	const erx_device_segment_t one[] = { { .offset = 0, .length = 8, .device_writes = true } };
	const erx_device_segment_t backwards[] = { { .offset = 0, .length = 8, .device_writes = true },
	    { .offset = 8, .length = 8, .device_writes = false } };
	erx_device_segment_t many[ERX_DEVICE_CHAIN_MAX + 1];
	erx_device_post_plan_t plan;

	for (uint32_t index = 0; index < ERX_DEVICE_CHAIN_MAX + 1; index++)
		many[index] = one[0];
	CHECK(erx_device_queue_init(&queue, 4, 1024, 1, buffer_addr));
	before = queue;
	CHECK(!erx_device_queue_post(&queue, outside, 1, 1, &plan));
	CHECK(!erx_device_queue_post(&queue, empty, 1, 1, &plan));
	CHECK(!erx_device_queue_post(&queue, one, 0, 1, &plan));
	CHECK(!erx_device_queue_post(&queue, many, ERX_DEVICE_CHAIN_MAX + 1, 1, &plan));
	CHECK(!erx_device_queue_post(&queue, backwards, 2, 1, &plan));
	CHECK(memcmp(&queue, &before, sizeof(queue)) == 0);

	/* Four descriptors: a chain of three leaves one, too few for a second. */
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	before = queue;
	CHECK(!erx_device_queue_post(&queue, read_chain, 2, 2, &plan));
	CHECK(memcmp(&queue, &before, sizeof(queue)) == 0);
	CHECK(erx_device_queue_post(&queue, one, 1, 2, &plan) && queue.free_count == 0);
}

/* What a device writes that the core did not post breaks the queue until reset. */
static void
broken_queues(void)
{
	erx_device_post_plan_t plan;
	erx_device_completion_t done;
	uint32_t count;

	CHECK(erx_device_queue_init(&queue, 8, 1024, 1, buffer_addr));
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	CHECK(!erx_device_queue_used(&queue, 2, &count) && queue.broken);
	CHECK(!erx_device_queue_post(&queue, read_chain, 3, 2, &plan));
	erx_device_queue_reset(&queue);
	CHECK(!queue.broken && queue.free_count == 8 && queue.in_flight == 0 && queue.avail_idx == 0);

	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	CHECK(erx_device_queue_used(&queue, 1, &count) && count == 1);
	CHECK(!erx_device_queue_complete(&queue, plan.descs[1].index, 1, &done) && queue.broken);
	erx_device_queue_reset(&queue);

	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	CHECK(erx_device_queue_used(&queue, 1, &count) && count == 1);
	CHECK(!erx_device_queue_complete(&queue, plan.head, 514, &done) && queue.broken);
	CHECK(!erx_device_queue_complete(&queue, plan.head, 1, &done));
	erx_device_queue_reset(&queue);

	/* A head completed twice: the second entry names a chain no longer posted. */
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	CHECK(erx_device_queue_post(&queue, read_chain, 3, 2, &plan));
	CHECK(erx_device_queue_used(&queue, 2, &count) && count == 2);
	CHECK(erx_device_queue_complete(&queue, plan.head, 1, &done) && done.tag == 2);
	CHECK(!erx_device_queue_complete(&queue, plan.head, 1, &done) && queue.broken);
	erx_device_queue_reset(&queue);

	CHECK(erx_device_queue_post(&queue, read_chain, 3, 1, &plan));
	CHECK(erx_device_queue_used(&queue, 1, &count) && count == 1);
	CHECK(!erx_device_queue_complete(&queue, 8, 1, &done) && queue.broken);
	CHECK(!erx_device_queue_used(&queue, 1, &count));
}

/* The running indices wrap at 2^16 while the slots follow them around the ring. */
static void
wrapping(void)
{
	const erx_device_segment_t one[] = { { .offset = 0, .length = 8, .device_writes = true } };
	erx_device_post_plan_t plan;
	erx_device_completion_t done;
	uint32_t count;

	CHECK(erx_device_queue_init(&queue, 2, 8, 1, buffer_addr));
	for (uint32_t round = 0; round < 70000; round++) {
		CHECK(erx_device_queue_post(&queue, one, 1, round, &plan));
		CHECK(plan.avail_slot == round % 2 && plan.avail_idx == (uint16_t)(round + 1));
		CHECK(erx_device_queue_used_slot(&queue) == round % 2);
		CHECK(erx_device_queue_used(&queue, (uint16_t)(round + 1), &count) && count == 1);
		CHECK(erx_device_queue_complete(&queue, plan.head, 8, &done) && done.tag == round);
	}
	CHECK(queue.free_count == 2 && queue.in_flight == 0);
}

int
main(void)
{
	layouts();
	post_and_complete();
	refused_posts();
	broken_queues();
	wrapping();
	printf("erx_device_queue done\n");
	return (0);
}
