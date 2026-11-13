/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A virtio split ring over the hosted model of a non-coherent cache
 * (test/host/erx_device_dma_test.rb; docs/design-device-dma.md, Verification).
 *
 * The harness is the split-ring form and the effect layer: it keeps the queue's bookkeeping in
 * erx_device_queue, turns each post, completion, reset and install into a plan over the queue's
 * regions, has erx_device_dma_check and erx_device_dma_order validate and order it, and runs
 * the effects on erx_dma_model, the CPU's stores and loads through its cache and the
 * maintenance on its lines. The stand-in device is virtio's side of the ring and reads and
 * writes the model's memory alone: after any effect it may take what the available ring
 * shows, read each chain's out bytes and compare them with what the driver posted, and write
 * a pattern over a prefix of each in segment while reporting a length up to the segment's
 * end. Between effects the model evicts dirty granules and refetches clean lines as its seeded
 * source draws.
 *
 * Every schedule starts with a used ring holding a former record's dirty lines, installs the
 * queue, and runs posts, completions and a reset with buffers still posted; with the line equal
 * to the granule and a quarter of it, evicting often in half the schedules and rarely in the
 * rest. Every out byte reaches the device intact, every
 * completion returns the device's pattern up to its prefix and zeros after it, never an earlier
 * request's bytes, and no completion is missed.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "otp/erts/emulator/nifs/erxos/erx_device_dma.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_queue.h"
#include "otp/erts/emulator/nifs/erxos/erx_dma_model.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define GRANULE		64u
#define SIZE		4u		/* the queue's entries and buffers */
#define BUFFER		200u		/* the bytes a request may use of a buffer */
#define ROUNDS		80u
#define SCHEDULES	48u
#define DEVICE_BASE	UINT64_C(0x10000)
#define ROUND_UP(n)	(((n) + GRANULE - 1) / GRANULE * GRANULE)

/* The split ring's layout: the descriptor table and the available ring, then the used ring, each on a granule. */
#define DESC		0u
#define AVAIL		(DESC + 16u * SIZE)
#define AVAIL_IDX	(AVAIL + 2u)
#define RINGS_LENGTH	ROUND_UP(AVAIL + 4u + 2u * SIZE + 2u)
#define USED		RINGS_LENGTH
#define USED_LENGTH	ROUND_UP(4u + 8u * SIZE + 2u)
#define POOL		(USED + USED_LENGTH)
#ifdef HARNESS_SEED_UNROUNDED_STRIDE
#define STRIDE		BUFFER
#else
#define STRIDE		ROUND_UP(BUFFER)
#endif
#define MEMORY		ROUND_UP(POOL + SIZE * STRIDE)

/* virtio-mmio's registers the NIF owns (abi/formats/virtio.txt), at their window offsets. */
enum {
	REG_SEL = 0x30, REG_NUM = 0x38, REG_READY = 0x44, REG_NOTIFY = 0x50,
	REG_DESC = 0x80, REG_DESC_HIGH = 0x84, REG_DRIVER = 0x90, REG_DRIVER_HIGH = 0x94,
	REG_DEVICE = 0xa0, REG_DEVICE_HIGH = 0xa4,
};
static const uint32_t owned_registers[] = { REG_SEL, REG_NUM, REG_READY, REG_NOTIFY, REG_DESC, REG_DESC_HIGH, REG_DRIVER,
	REG_DRIVER_HIGH, REG_DEVICE, REG_DEVICE_HIGH };

#define STEPS_MAX	64u
#ifndef HARNESS_SEED_UNROUNDED_STRIDE
#define QUEUE_GRANULE	GRANULE
#else
#define QUEUE_GRANULE	1u
#endif
static const erx_device_queue_registers_t queue_registers = { .sel = REG_SEL, .num = REG_NUM, .ready = REG_READY,
	.notify = REG_NOTIFY, .desc = { REG_DESC, REG_DESC_HIGH }, .driver = { REG_DRIVER, REG_DRIVER_HIGH },
	.device = { REG_DEVICE, REG_DEVICE_HIGH } };
/* The core's layout of the rings, which the form's builders and its view read. */
static erx_device_queue_layout_t layout;
#define EFFECTS_MAX	ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, STEPS_MAX)

/* What the driver posted on a head, and what the device is to write and report for it. */
typedef struct request {
	bool		live;
	uint32_t	serial;
	uint32_t	out_length;
	uint8_t		out[BUFFER];
	uint32_t	in_length;
	uint32_t	prefix;		/* the bytes of the in segment the device writes */
	uint32_t	reported;	/* the length it reports, prefix..in_length */
} request_t;

/* The stand-in device: its registers and its own place in the rings. */
typedef struct device {
	bool		ready;
	uint64_t	desc, avail, used;	/* device addresses, as published */
	uint16_t	last_avail;
	uint16_t	used_idx;
	uint32_t	actions;
} device_t;

typedef struct harness {
	erx_dma_model_t		model;
	erx_device_queue_t	queue;
	bool			installed;
	device_t		device;
	request_t		requests[SIZE];
	uint32_t		serial;
	uint32_t		line;
	uint64_t		random;
	uint8_t			copied[SIZE * BUFFER];
	uint32_t		copied_length;
	uint64_t		values[2 * SIZE + 1];
	uint32_t		value_count;
	uint64_t		completions;
} harness_t;

static erx_dma_effect_t effect_storage[EFFECTS_MAX];

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

static uint64_t
load_le(const uint8_t *bytes, uint32_t width)
{
	uint64_t value = 0;

	for (uint32_t at = width; at > 0; at--)
		value = value << 8 | bytes[at - 1];
	return (value);
}

static void
store_le(uint8_t *bytes, uint32_t width, uint64_t value)
{
	for (uint32_t at = 0; at < width; at++)
		bytes[at] = (uint8_t)(value >> (8 * at));
}

static uint64_t
device_load(const harness_t *h, uint64_t addr, uint32_t width)
{
	uint8_t bytes[8];

	CHECK(addr >= DEVICE_BASE && erx_dma_model_device_read(&h->model, addr - DEVICE_BASE, bytes, width));
	return (load_le(bytes, width));
}

static void
device_store(harness_t *h, uint64_t addr, uint32_t width, uint64_t value)
{
	uint8_t bytes[8];

	store_le(bytes, width, value);
	CHECK(addr >= DEVICE_BASE && erx_dma_model_device_write(&h->model, addr - DEVICE_BASE, bytes, width));
}

/*
 * The device's side of the ring: every chain the available index shows, read from memory.
 * A descriptor outside the memory, a chain the driver did not post or out bytes other than
 * the driver's are a stale view of the rings, and fail.
 */
static void
device_act(harness_t *h)
{
	device_t *const d = &h->device;
	uint16_t avail_idx;

	if (!d->ready)
		return;
	avail_idx = (uint16_t)device_load(h, d->avail + 2, 2);
	while (d->last_avail != avail_idx) {
		const uint16_t head = (uint16_t)device_load(h, d->avail + 4 + 2u * (d->last_avail % SIZE), 2);
		request_t *request;
		uint32_t index, out_seen = 0, in_seen = 0;

		CHECK(head < SIZE && h->requests[head].live);
		request = &h->requests[head];
		index = head;
		for (uint32_t step = 0; step < SIZE; step++) {
			const uint64_t at = d->desc + 16u * index;
			const uint64_t addr = device_load(h, at, 8);
			const uint32_t len = (uint32_t)device_load(h, at + 8, 4);
			const uint16_t flags = (uint16_t)device_load(h, at + 12, 2);
			uint8_t bytes[BUFFER];

			CHECK(addr >= DEVICE_BASE + POOL && len <= BUFFER && addr + len <= DEVICE_BASE + MEMORY);
			if ((flags & 2u) == 0) {
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
			if ((flags & 1u) == 0)
				break;
			index = (uint32_t)device_load(h, at + 14, 2);
			CHECK(index < SIZE);
		}
		CHECK(out_seen == request->out_length && in_seen == request->in_length);
		device_store(h, d->used + 4 + 8u * (d->used_idx % SIZE), 4, head);
		device_store(h, d->used + 8 + 8u * (d->used_idx % SIZE), 4, request->reported);
		d->used_idx++;
		device_store(h, d->used + 2, 2, d->used_idx);
		d->last_avail++;
		d->actions++;
	}
}

static void
device_register(harness_t *h, const erx_dma_step_t *step)
{
	device_t *const d = &h->device;

	switch (step->reg) {
	case REG_DESC:
		d->desc = step->value;
		break;
	case REG_DRIVER:
		d->avail = step->value;
		break;
	case REG_DEVICE:
		d->used = step->value;
		break;
	case REG_READY:
		d->ready = step->value != 0;
		d->last_avail = d->used_idx = 0;
		break;
	default:
		break;
	}
}

/* -------------------------------------------------------------------------------------------
 * The effect layer over the model
 */

static void
run_step(harness_t *h, const erx_dma_step_t *step)
{
	uint8_t bytes[8];

	switch (step->kind) {
	case ERX_DMA_WRITE:
	case ERX_DMA_PUBLISH:
		if (step->target == ERX_DMA_REGISTER) {
			device_register(h, step);
		} else if (step->source == ERX_DMA_BYTES) {
			CHECK(erx_dma_model_cpu_store(&h->model, step->offset, step->bytes, step->length));
		} else if (step->source == ERX_DMA_ZEROS) {
			CHECK(erx_dma_model_cpu_zero(&h->model, step->offset, step->length));
		} else {
			store_le(bytes, step->width, step->value);
			CHECK(erx_dma_model_cpu_store(&h->model, step->offset, bytes, step->width));
		}
		break;
	case ERX_DMA_COPY:
		CHECK(h->copied_length + step->length <= sizeof(h->copied));
		CHECK(erx_dma_model_cpu_load(&h->model, step->offset, h->copied + h->copied_length, step->length));
		h->copied_length += (uint32_t)step->length;
		break;
	case ERX_DMA_REPORT:
		CHECK(step->target == ERX_DMA_MEMORY && h->value_count < sizeof(h->values) / sizeof(h->values[0]));
		CHECK(erx_dma_model_cpu_load(&h->model, step->offset, bytes, step->width));
		h->values[h->value_count++] = load_le(bytes, step->width);
		break;
	}
}

/* The queue's regions in its current state: the used ring the device's while installed, a posted buffer the device's. */
static void
view(const harness_t *h, erx_dma_state_t *state)
{
	erx_device_queue_view(&h->queue, &layout, POOL, h->installed, state);
}

/* A plan checked, ordered and run, with the model and the device free to act between effects. */
static void
apply(harness_t *h, const erx_dma_state_t *before, const erx_dma_state_t *after, const erx_dma_plan_t *plan)
{
	const erx_dma_context_t context = { .memory_size = MEMORY, .device_base = DEVICE_BASE, .window_size = 0x100, .address_bits = 32,
	    .granule = GRANULE, .publication = AVAIL_IDX, .publication_width = 2,
	    .owned_count = sizeof(owned_registers) / sizeof(owned_registers[0]), .owned = owned_registers };
	erx_dma_context_t form = context;
	erx_dma_effects_t effects = { .capacity = EFFECTS_MAX, .effects = effect_storage };

	erx_device_queue_form(&layout, SIZE, &form);
	form.address_bits = 32;
#ifndef HARNESS_SEED_UNROUNDED_STRIDE
	CHECK(erx_device_dma_check(&form, before, after, plan));
#else
	(void)form;
#endif
	CHECK(erx_device_dma_order(before, after, plan, false, GRANULE, h->line, &effects));
	for (uint32_t index = 0; index < effects.count; index++) {
		const erx_dma_effect_t *const effect = &effects.effects[index];

		switch (effect->kind) {
		case ERX_DMA_EFFECT_ZERO:
			CHECK(erx_dma_model_cpu_zero(&h->model, effect->offset, effect->length));
			break;
		case ERX_DMA_EFFECT_STEP:
			run_step(h, &plan->steps[effect->step]);
			break;
		case ERX_DMA_EFFECT_CLEAN:
			CHECK(erx_dma_model_clean(&h->model, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_CLEAN_INVAL:
			CHECK(erx_dma_model_clean_inval(&h->model, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_BARRIER:
			/* The model runs one access at a time, so every access is ordered already. */
			break;
		}
		erx_dma_model_tick(&h->model);
		if (draw(h, 4) == 0)
			device_act(h);
	}
}

/* -------------------------------------------------------------------------------------------
 * The split-ring form
 */

/* virtio's reset and install: every region taken back, then the rings zeroed and the queue made ready. */
static void
negotiate(harness_t *h)
{
	erx_dma_state_t before, after;
	erx_dma_step_t steps[STEPS_MAX];
	erx_dma_plan_t plan = { .call = ERX_DMA_CALL_RESET, .count = 0, .steps = steps };
	uint32_t count = 0;

	/* The reset the NIF writes, and the device's idle report, which the stand-in gives at once. */
	h->device.ready = false;
	view(h, &before);
	erx_device_queue_reset(&h->queue);
	h->installed = false;
	for (uint32_t head = 0; head < SIZE; head++)
		h->requests[head].live = false;
	view(h, &after);
	apply(h, &before, &after, &plan);

	count = erx_device_queue_install_steps(&h->queue, &layout, &queue_registers, 0, DEVICE_BASE, steps);
	before = after;
	h->installed = true;
	view(h, &after);
	plan = (erx_dma_plan_t){ .call = ERX_DMA_CALL_INSTALL, .count = count, .steps = steps };
	apply(h, &before, &after, &plan);
}

/* A request of an out segment, an in segment or both, whose device prefix and reported length the source draws. */
static void
post(harness_t *h)
{
	erx_dma_state_t before, after;
	erx_dma_step_t steps[STEPS_MAX];
	erx_device_segment_t segments[2];
	const uint8_t *bytes[2];
	request_t request = { .live = true, .serial = ++h->serial };
	uint32_t count = 0, segment_count = 0;
	const uint32_t shape = draw(h, 3);
	/* The core takes a chain's head off its free list, so the head's slot holds the bytes it posts. */
	request_t *const slot = &h->requests[h->queue.free_head];

	request.out_length = shape == 1 ? 0 : 1 + draw(h, BUFFER / 2);
	request.in_length = shape == 0 ? 0 : 1 + draw(h, BUFFER - request.out_length);
	if (shape == 2 && draw(h, 2) == 0)
		request.in_length = BUFFER - request.out_length;	/* to the buffer's end */
	request.prefix = request.in_length == 0 ? 0 : draw(h, request.in_length + 1);
	request.reported = request.prefix + (request.in_length == 0 ? 0 : draw(h, request.in_length - request.prefix + 1));
	for (uint32_t at = 0; at < request.out_length; at++)
		request.out[at] = pattern(request.serial, at);
	if (request.out_length != 0)
		segments[segment_count++] = (erx_device_segment_t){ 0, request.out_length, false };
	if (request.in_length != 0)
		segments[segment_count++] = (erx_device_segment_t){ request.out_length, request.in_length, true };

	for (uint32_t segment = 0; segment < segment_count; segment++)
		bytes[segment] = segments[segment].device_writes ? NULL : slot->out;
	view(h, &before);
	count = erx_device_queue_post(&h->queue, &layout, DEVICE_BASE, POOL, segments, bytes, segment_count, request.serial,
	    &queue_registers, 0, steps);
	if (count == 0)
		return;
	view(h, &after);
	*slot = request;
	apply(h, &before, &after, &(erx_dma_plan_t){ .call = ERX_DMA_CALL_POST, .count = count, .steps = steps });
}

/* An observation of `count` reports, run alone; its values land in h->values. */
static void
observe(harness_t *h, const erx_dma_step_t *steps, uint32_t count)
{
	erx_dma_state_t state;

	view(h, &state);
	h->value_count = 0;
	apply(h, &state, &state, &(erx_dma_plan_t){ .call = ERX_DMA_CALL_OBSERVE, .count = count, .steps = steps });
}

/*
 * virtio's completion: the used index, then each entry it covers, then the buffers taken back
 * and copied. Each completion returns the device's pattern up to its prefix and zeros to the
 * length it reported.
 */
static uint32_t
complete(harness_t *h)
{
	erx_dma_state_t before, after;
	erx_dma_step_t steps[STEPS_MAX];
	erx_device_completion_t completions[SIZE];
	uint32_t fresh, count;

	erx_device_queue_index_report(&layout, &steps[0]);
	observe(h, steps, 1);
	CHECK(erx_device_queue_used(&h->queue, (uint16_t)h->values[0], &fresh));
	count = erx_device_queue_entry_reports(&h->queue, &layout, fresh, steps);
	if (fresh != 0)
		observe(h, steps, count);
	view(h, &before);
	for (uint32_t entry = 0; entry < fresh; entry++)
		CHECK(erx_device_queue_complete(&h->queue, (uint32_t)h->values[2 * entry], (uint32_t)h->values[2 * entry + 1],
		    &completions[entry]));
	view(h, &after);
	count = erx_device_queue_copy_steps(&h->queue, POOL, completions, fresh, steps);
	h->copied_length = 0;
	apply(h, &before, &after, &(erx_dma_plan_t){ .call = ERX_DMA_CALL_COMPLETE, .count = count, .steps = steps });
	for (uint32_t entry = 0, at = 0; entry < fresh; entry++) {
		request_t *const request = &h->requests[completions[entry].buffer];

		CHECK(request->live && completions[entry].length == request->reported);
		for (uint32_t byte = 0; byte < request->reported; byte++, at++)
			CHECK(h->copied[at] == (byte < request->prefix ? pattern(request->serial, byte) : 0));
		request->live = false;
		h->completions++;
	}
	return (fresh);
}

/* One schedule: a former record's dirty used ring, an install, then posts, completions and a reset. */
static void
schedule(uint32_t line, uint64_t seed, uint64_t *evictions, uint64_t *refetches, uint64_t *completions)
{
	harness_t *const h = calloc(1, sizeof(*h));
	uint8_t former[USED_LENGTH];

	CHECK(h != NULL && erx_dma_model_init(&h->model, MEMORY, GRANULE, line, seed));
	CHECK(erx_device_queue_layout(SIZE, QUEUE_GRANULE, &layout));
	CHECK(erx_device_queue_init(&h->queue, SIZE, BUFFER, QUEUE_GRANULE, DEVICE_BASE + POOL));
	h->line = line;
	/* Half the schedules evict rarely, so a dirty line can outlive the calls after it, as the install seed needs. */
	if (seed % 2 != 0)
		h->model.evict_rate = 4;
	h->random = seed * 0x9e3779b97f4a7c15u + 1;
	memset(former, 0xa5, sizeof(former));
	CHECK(erx_dma_model_cpu_store(&h->model, USED, former, sizeof(former)));
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
	while (h->queue.in_flight != 0 && h->device.ready) {
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
