/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A virtio split ring over the hosted model of a non-coherent cache
 * (test/host/erx_device_dma_test.rb; docs/design-device-dma.md, Verification).
 *
 * The harness is the effect layer over the split ring's pure core (erx_device_virtio_core.h):
 * it applies each sequence the core returns in erx_device_sequencer.h's order, as erx_device.c's
 * apply_sequence and split_ring_complete do, onto erx_dma_model, the CPU's stores and loads
 * through its cache and the maintenance on its lines. The stand-in device is virtio's side of
 * the ring and reads and writes the model's memory alone: after any effect it may take what the
 * available ring shows, read each chain's out bytes and compare them with what the driver
 * posted, and write a pattern over a prefix of each in segment while reporting a length up to
 * the segment's end. Between effects the model evicts dirty granules and refetches clean lines
 * as its seeded source draws.
 *
 * Every schedule starts with a used ring holding a former record's dirty lines, installs the
 * queue, and runs posts, completions and a reset with buffers still posted; with the line equal
 * to the granule and a quarter of it, evicting often in half the schedules and rarely in the
 * rest. Every out byte reaches the device intact, every completion returns the device's pattern
 * up to its prefix and zeros after it, never an earlier request's bytes, and no completion is
 * missed.
 *
 * The HARNESS_SEED_* macros plant faults in this effect layer that the test shows the harness
 * catches: a post's cleans skipped, its available index published before its cleans, and the
 * written range read back without its invalidate.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx_device_virtio_core.h"
#include "erx_dma_model.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#ifdef HARNESS_SEED_NO_POST_CLEANS
#define SEED_NO_POST_CLEANS		true
#else
#define SEED_NO_POST_CLEANS		false
#endif
#ifdef HARNESS_SEED_PUBLISH_BEFORE_CLEAN
#define SEED_PUBLISH_BEFORE_CLEAN	true
#else
#define SEED_PUBLISH_BEFORE_CLEAN	false
#endif
#ifdef HARNESS_SEED_NO_WRITTEN_INVALIDATE
#define SEED_NO_WRITTEN_INVALIDATE	true
#else
#define SEED_NO_WRITTEN_INVALIDATE	false
#endif

#define GRANULE		64u
#define SIZE		4u		/* the queue's entries and buffers */
#define BUFFER		200u		/* a buffer's bytes */
#define ROUNDS		80u
#define SCHEDULES	48u
#define DEVICE_BASE	UINT64_C(0x10000)
#define ADDRESS_BITS	32u

/* The device's region table: the split ring's chains here name none. */
static const erx_dma_regions_t no_regions;

/* What the driver posted in a buffer, and what the device is to write and report for it. */
typedef struct request {
	bool		live;
	uint32_t	serial;		/* the chain's tag */
	uint32_t	out_length;
	uint8_t		out[BUFFER];
	uint32_t	in_length;
	uint32_t	prefix;		/* the bytes of the in segment the device writes */
	uint32_t	reported;	/* the length it reports, prefix..in_length */
} request_t;

/* The stand-in device: its queue registers, as the install wrote them, and its own place in the rings. */
typedef struct device {
	bool		ready;
	uint64_t	num;
	uint64_t	desc, avail, used;	/* device addresses */
	uint16_t	last_avail;
	uint16_t	used_idx;
} device_t;

typedef struct harness {
	erx_dma_model_t		model;
	erx_split_ring_t	ring;
	device_t		device;
	request_t		requests[SIZE];		/* by buffer */
	uint32_t		serial;
	uint32_t		line;
	uint64_t		random;
	uint64_t		completions;
} harness_t;

static erx_dma_sequence_t sequence;

static uint32_t
draw(harness_t *h, uint32_t bound)
{
	h->random ^= h->random >> 12;
	h->random ^= h->random << 25;
	h->random ^= h->random >> 27;
	return ((uint32_t)((h->random * UINT64_C(0x2545f4914f6cdd1d)) >> 33) % bound);
}

/* A request's bytes are never zero, so a zero in a completion is the zeroing's. */
static uint8_t
pattern(uint32_t serial, uint32_t at)
{
	return ((uint8_t)((serial * 13u + at * 7u) % 251u + 1u));
}

static const erx_dma_layout_t *
layout_of(const harness_t *h)
{
	return (erx_dma_ledger_layout(erx_split_ring_ledger(&h->ring)));
}

static const erx_dma_table_t *
used_table(const harness_t *h)
{
	return (&layout_of(h)->tables[erx_dma_ledger_table(erx_split_ring_ledger(&h->ring), ERX_STRUCTURE_VIRTQ_USED)]);
}

static uint64_t
device_load(const harness_t *h, uint64_t addr, uint32_t width)
{
	uint8_t bytes[8];
	uint64_t value = 0;

	CHECK(addr >= DEVICE_BASE && erx_dma_model_device_read(&h->model, addr - DEVICE_BASE, bytes, width));
	for (uint32_t at = width; at > 0; at--)
		value = value << 8 | bytes[at - 1];
	return (value);
}

static void
device_store(harness_t *h, uint64_t addr, uint32_t width, uint64_t value)
{
	uint8_t bytes[8];

	for (uint32_t at = 0; at < width; at++)
		bytes[at] = (uint8_t)(value >> (8 * at));
	CHECK(addr >= DEVICE_BASE && erx_dma_model_device_write(&h->model, addr - DEVICE_BASE, bytes, width));
}

/* The live request whose buffer starts at device address `addr`, where a chain's head descriptor points. */
static request_t *
request_at(harness_t *h, uint64_t addr)
{
	const erx_dma_pool_t *const pool = &layout_of(h)->pools[0];
	uint64_t from;

	CHECK(addr >= DEVICE_BASE + pool->first);
	from = addr - DEVICE_BASE - pool->first;
	CHECK(from % pool->stride == 0 && from / pool->stride < SIZE && h->requests[from / pool->stride].live);
	return (&h->requests[from / pool->stride]);
}

/*
 * The device's side of the ring: every chain the available index shows, read from memory.
 * A descriptor outside the pool, a chain the driver did not post or out bytes other than the
 * driver's are a stale view of the rings, and fail.
 */
static void
device_act(harness_t *h)
{
	device_t *const d = &h->device;
	const uint64_t memory_end = DEVICE_BASE + h->model.size;
	uint16_t avail_idx;

	if (!d->ready)
		return;
	avail_idx = (uint16_t)device_load(h, d->avail + ERX_VIRTQ_RING_HEAD_OFF_IDX, 2);
	while (d->last_avail != avail_idx) {
		const uint16_t head = (uint16_t)device_load(h,
		    d->avail + ERX_VIRTQ_RING_HEAD_SIZE + 2u * (d->last_avail % d->num), 2);
		const uint64_t slot = d->used + ERX_VIRTQ_RING_HEAD_SIZE + ERX_VIRTQ_USED_ELEM_SIZE * (d->used_idx % d->num);
		request_t *request = NULL;
		uint32_t index = head, out_seen = 0, in_seen = 0;

		CHECK(head < d->num);
		for (uint32_t step = 0; step < d->num; step++) {
			const uint64_t at = d->desc + ERX_VIRTQ_DESC_SIZE * index;
			const uint64_t addr = device_load(h, at + ERX_VIRTQ_DESC_OFF_ADDR, 8);
			const uint32_t len = (uint32_t)device_load(h, at + ERX_VIRTQ_DESC_OFF_LEN, 4);
			const uint16_t flags = (uint16_t)device_load(h, at + ERX_VIRTQ_DESC_OFF_FLAGS, 2);
			uint8_t bytes[BUFFER];

			if (request == NULL)
				request = request_at(h, addr);
			CHECK(len <= BUFFER && addr + len <= memory_end);
			if ((flags & ERX_VIRTQ_DESC_F_WRITE) == 0) {
				CHECK(out_seen + len <= request->out_length);
				CHECK(erx_dma_model_device_read(&h->model, addr - DEVICE_BASE, bytes, len));
				CHECK(memcmp(bytes, request->out + out_seen, len) == 0);
				out_seen += len;
			} else {
				for (uint32_t at_byte = 0; at_byte < len; at_byte++) {
					if (in_seen + at_byte < request->prefix)
						device_store(h, addr + at_byte, 1, pattern(request->serial, in_seen + at_byte));
				}
				in_seen += len;
			}
			if ((flags & ERX_VIRTQ_DESC_F_NEXT) == 0)
				break;
			index = (uint32_t)device_load(h, at + ERX_VIRTQ_DESC_OFF_NEXT, 2);
			CHECK(index < d->num);
		}
		CHECK(out_seen == request->out_length && in_seen == request->in_length);
		device_store(h, slot + ERX_VIRTQ_USED_ELEM_OFF_ID, 4, head);
		device_store(h, slot + ERX_VIRTQ_USED_ELEM_OFF_LEN, 4, request->reported);
		d->used_idx++;
		device_store(h, d->used + ERX_VIRTQ_RING_HEAD_OFF_IDX, 2, d->used_idx);
		d->last_avail++;
	}
}

/* An install's register written to the device; the ready bit starts its walk of the rings over. */
static void
device_register(harness_t *h, erx_dma_register_write_t write)
{
	device_t *const d = &h->device;

	switch (write.reg) {
	case ERX_DMA_VIRTQ_NUM:
		CHECK(write.value == SIZE);
		d->num = write.value;
		break;
	case ERX_DMA_VIRTQ_DESC:
		d->desc = write.value;
		break;
	case ERX_DMA_VIRTQ_DRIVER:
		d->avail = write.value;
		break;
	case ERX_DMA_VIRTQ_DEVICE:
		d->used = write.value;
		break;
	case ERX_DMA_VIRTQ_READY:
		d->ready = write.value != 0;
		d->last_avail = d->used_idx = 0;
		break;
	case ERX_DMA_XHCI_SLOTS:
	case ERX_DMA_XHCI_DCBAA:
	case ERX_DMA_XHCI_EVENT_RING_SIZE:
	case ERX_DMA_XHCI_INTERRUPT_MODERATION:
	case ERX_DMA_XHCI_EVENT_DEQUEUE:
	case ERX_DMA_XHCI_SEGMENT_TABLE:
	case ERX_DMA_XHCI_INTERRUPTER_ENABLE:
	case ERX_DMA_XHCI_COMMAND_RING:
	case ERX_DMA_XHCI_RUN:
		CHECK(!"a split ring's install writes no xHCI register");
		break;
	}
}

/* -------------------------------------------------------------------------------------------
 * The effect layer over the model
 */

/* One effect done: the model may evict or refetch, and the device may act on what memory shows. */
static void
settle(harness_t *h)
{
	erx_dma_model_tick(&h->model);
	if (draw(h, 4) == 0)
		device_act(h);
}

/* The clean, or clean and invalidate, of every line `range` touches, as erx_device.c's maintain. */
static void
maintain(harness_t *h, erx_dma_range_t range, bool invalidate)
{
	const uint64_t mask = ~(uint64_t)(h->line - 1);
	const uint64_t start = range.offset & mask;
	const uint64_t end = (range.offset + range.length + h->line - 1) & mask;

	if (range.length == 0)
		return;
	if (invalidate)
		CHECK(erx_dma_model_clean_inval(&h->model, start, end - start, h->line));
	else
		CHECK(erx_dma_model_clean(&h->model, start, end - start, h->line));
	settle(h);
}

/* A run's activation: its available index, the clean of its line, the publish barrier and the doorbell. */
static void
activate_run(harness_t *h, const erx_dma_activation_t *activation)
{
	CHECK(erx_dma_model_cpu_store(&h->model, activation->store.offset, activation->store.bytes,
	    activation->store.length));
	settle(h);
	maintain(h, (erx_dma_range_t){ activation->store.offset, activation->store.length }, false);
	/* The doorbell: the device may act from here on, as it may after any effect. */
	settle(h);
}

/*
 * A sequence applied in erx_device_sequencer.h's order: the zeros, the readable pieces' bytes
 * (`pieces[i]` fills sequence->fills[i]), the stores, the clean of every range passing to the
 * device and the publish barrier; then an install's registers and its ready bit, or a run's
 * activation. The model runs one access at a time, so every barrier holds already; the queue
 * select is the stand-in's one queue.
 */
static void
apply_sequence(harness_t *h, const erx_dma_sequence_t *s, const erx_dma_piece_t *pieces)
{
	const bool run = s->activation.kind == ERX_DMA_ACTIVATE_STORE;

	for (uint32_t at = 0; at < s->zero_count; at++) {
		CHECK(erx_dma_model_cpu_zero(&h->model, s->zeros[at].offset, s->zeros[at].length));
		settle(h);
	}
	for (uint32_t at = 0; at < s->fill_count; at++) {
		if (s->fills[at].length == 0)
			continue;
		CHECK(erx_dma_model_cpu_store(&h->model, s->fills[at].offset, pieces[at].bytes, s->fills[at].length));
		settle(h);
	}
	for (uint32_t at = 0; at < s->store_count; at++) {
		CHECK(erx_dma_model_cpu_store(&h->model, s->stores[at].offset, s->stores[at].bytes, s->stores[at].length));
		settle(h);
	}
	if (run && SEED_PUBLISH_BEFORE_CLEAN)
		activate_run(h, &s->activation);
	for (uint32_t at = 0; at < s->clean_count; at++) {
		if (!(run && SEED_NO_POST_CLEANS))
			maintain(h, s->cleans[at], false);
	}
	if (!run) {
		for (uint32_t at = 0; at < s->register_count; at++) {
			device_register(h, s->registers[at]);
			settle(h);
		}
		device_register(h, s->activation.reg);
		settle(h);
	} else if (!SEED_PUBLISH_BEFORE_CLEAN) {
		activate_run(h, &s->activation);
	}
}

/* -------------------------------------------------------------------------------------------
 * The driver
 */

/* virtio's reset, the device's idle report, which the stand-in gives at once, and the install. */
static void
negotiate(harness_t *h)
{
	h->device.ready = false;
	erx_split_ring_reset(&h->ring);
	for (uint32_t buffer = 0; buffer < SIZE; buffer++)
		h->requests[buffer].live = false;
	CHECK(erx_split_ring_install(&h->ring, &sequence) == ERX_OK);
	apply_sequence(h, &sequence, NULL);
}

/* A request of an out piece, an in piece or both, whose device prefix and reported length the source draws. */
static void
post(harness_t *h)
{
	const erx_dma_ledger_t *const ledger = erx_split_ring_ledger(&h->ring);
	request_t request = { .live = true, .serial = ++h->serial };
	erx_dma_piece_t pieces[2];
	bool held[SIZE];
	uint32_t count = 0, buffer = SIZE;
	const uint32_t shape = draw(h, 3);
	int status;

	request.out_length = shape == 1 ? 0 : 1 + draw(h, BUFFER / 2);
	request.in_length = shape == 0 ? 0 : 1 + draw(h, BUFFER - request.out_length);
	if (shape == 2 && draw(h, 2) == 0)
		request.in_length = BUFFER - request.out_length;	/* to the buffer's end */
	request.prefix = request.in_length == 0 ? 0 : draw(h, request.in_length + 1);
	request.reported = request.prefix + (request.in_length == 0 ? 0 : draw(h, request.in_length - request.prefix + 1));
	for (uint32_t at = 0; at < request.out_length; at++)
		request.out[at] = pattern(request.serial, at);
	if (request.out_length != 0)
		pieces[count++] = (erx_dma_piece_t){ .bytes = request.out, .length = request.out_length };
	if (request.in_length != 0)
		pieces[count++] = (erx_dma_piece_t){ .length = request.in_length, .device_writes = true };

	for (uint32_t at = 0; at < SIZE; at++)
		held[at] = erx_dma_ledger_buffer_held(ledger, at);
	status = erx_split_ring_post(&h->ring, pieces, count, request.serial, &sequence);
	if (status == ERX_EWOULDBLOCK)
		return;
	CHECK(status == ERX_OK);
	/* The chain's buffer is the one the post made held; the device finds its request there. */
	for (uint32_t at = 0; at < SIZE; at++) {
		if (!held[at] && erx_dma_ledger_buffer_held(ledger, at))
			buffer = at;
	}
	CHECK(buffer < SIZE);
	h->requests[buffer] = request;
	apply_sequence(h, &sequence, pieces);
}

/* The live request posted with tag `tag`, and its buffer. */
static request_t *
request_tagged(harness_t *h, uint64_t tag, uint32_t *buffer)
{
	for (uint32_t at = 0; at < SIZE; at++) {
		if (h->requests[at].live && h->requests[at].serial == tag) {
			*buffer = at;
			return (&h->requests[at]);
		}
	}
	CHECK(!"a completion names a request the driver posted");
	return (NULL);
}

/*
 * virtio's completion, as erx_device.c's split_ring_complete: the used index's line invalidated
 * and the index loaded once, the elements it covers invalidated and read whole, then each
 * answer's written range invalidated and copied out. Each completion returns the device's
 * pattern up to its prefix and zeros to the length it reported.
 */
static uint32_t
complete(harness_t *h)
{
	const erx_dma_range_t index_at = { used_table(h)->region + ERX_VIRTQ_RING_HEAD_OFF_IDX, sizeof(uint16_t) };
	const erx_dma_pool_t *const pool = &layout_of(h)->pools[0];
	erx_report_record_t elements[SIZE];
	erx_split_ring_answer_t answers[SIZE];
	uint8_t index_bytes[2];
	uint32_t count, done;

	maintain(h, index_at, true);
	CHECK(erx_dma_model_cpu_load(&h->model, index_at.offset, index_bytes, sizeof(index_bytes)));
	CHECK(erx_split_ring_acquire(&h->ring, (uint16_t)(index_bytes[0] | index_bytes[1] << 8), SIZE, &count) == ERX_OK);
	for (uint32_t k = 0; k < count; k++)
		maintain(h, erx_split_ring_element(&h->ring, k), true);
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t element = erx_split_ring_element(&h->ring, k);

		CHECK(element.length <= sizeof(elements[k].bytes));
		memset(&elements[k], 0, sizeof(elements[k]));
		CHECK(erx_dma_model_cpu_load(&h->model, element.offset, elements[k].bytes, element.length));
		settle(h);
	}
	CHECK(erx_split_ring_complete(&h->ring, elements, count, UINT64_MAX, answers, &done) == ERX_OK && done == count);
	for (uint32_t at = 0; at < done && !SEED_NO_WRITTEN_INVALIDATE; at++)
		maintain(h, answers[at].written, true);
	for (uint32_t at = 0; at < done; at++) {
		const erx_dma_range_t written = answers[at].written;
		uint32_t buffer;
		request_t *const request = request_tagged(h, answers[at].tag, &buffer);
		uint8_t bytes[BUFFER];

		CHECK(written.offset == pool->first + (uint64_t)buffer * pool->stride + request->out_length &&
		    written.length == request->reported);
		CHECK(erx_dma_model_cpu_load(&h->model, written.offset, bytes, written.length));
		settle(h);
		for (uint32_t byte = 0; byte < request->reported; byte++)
			CHECK(bytes[byte] == (byte < request->prefix ? pattern(request->serial, byte) : 0));
		request->live = false;
		h->completions++;
	}
	return (done);
}

/* The memory the ring's layout needs, through its pool's end. */
static uint64_t
memory_size(void)
{
	erx_dma_layout_t layout;

	CHECK(erx_dma_layout_split_ring(SIZE, BUFFER, GRANULE, 0, DEVICE_BASE, ADDRESS_BITS, &layout));
	return (layout.pools[0].first + (uint64_t)layout.pools[0].count * layout.pools[0].stride);
}

/* One schedule: a former record's dirty used ring, an install, then posts, completions and a reset. */
static void
schedule(uint32_t line, uint64_t seed, uint64_t *evictions, uint64_t *refetches, uint64_t *completions)
{
	harness_t *const h = calloc(1, sizeof(*h));
	const uint64_t memory = memory_size();
	const erx_dma_table_t *used;
	uint8_t *former;

	CHECK(h != NULL && erx_dma_model_init(&h->model, memory, GRANULE, line, seed));
	CHECK(erx_split_ring_make(&h->ring, SIZE, BUFFER, GRANULE, memory, DEVICE_BASE, ADDRESS_BITS, &no_regions));
	h->line = line;
	/* Half the schedules evict rarely, so a dirty line can outlive the calls after it, as the install seeds need. */
	if (seed % 2 != 0)
		h->model.evict_rate = 4;
	h->random = seed * 0x9e3779b97f4a7c15u + 1;
	used = used_table(h);
	former = malloc(used->region_length);
	CHECK(former != NULL);
	memset(former, 0xa5, used->region_length);
	CHECK(erx_dma_model_cpu_store(&h->model, used->region, former, used->region_length));
	free(former);
	negotiate(h);
	for (uint32_t round = 0; round < ROUNDS; round++) {
		const uint32_t action = draw(h, 16);

		if (action < 7)
			post(h);
		else if (action < 15)
			complete(h);
		else if (round > ROUNDS / 2)
			negotiate(h);
	}
	/* Whatever the device has taken by now completes: nothing posted is lost. */
	device_act(h);
	while (erx_dma_ledger_live(erx_split_ring_ledger(&h->ring)) != 0 && h->device.ready) {
		CHECK(complete(h) != 0);
		device_act(h);
	}
	*evictions += h->model.evictions;
	*refetches += h->model.refetches;
	*completions += h->completions;
	erx_dma_model_fini(&h->model);
	free(h);
}

int
main(void)
{
	const uint32_t lines[] = { GRANULE, GRANULE / 4 };

	for (uint32_t line = 0; line < 2; line++) {
		uint64_t evictions = 0, refetches = 0, completions = 0;

		for (uint64_t seed = 1; seed <= SCHEDULES; seed++)
			schedule(lines[line], seed, &evictions, &refetches, &completions);
		/* The model did act: it evicted, refetched, and the device completed requests. */
		CHECK(evictions > 0 && refetches > 0 && completions > SCHEDULES);
		printf("line %u: %llu completions, %llu evictions, %llu refetches\n", lines[line],
		    (unsigned long long)completions, (unsigned long long)evictions, (unsigned long long)refetches);
	}
	printf("erx_device_dma_model done\n");
	return (0);
}
