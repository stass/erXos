/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GENET's register ring over the hosted model of a non-coherent cache
 * (test/host/erx_device_genet_test.rb; docs/design-device-dma.md, Verification).
 *
 * The harness is the effect layer: it keeps a receive and a transmit queue in erx_device_genet,
 * turns each reset, install, post and completion into plans over the queues' buffers, has
 * erx_device_dma_check and erx_device_dma_order validate and order them, and runs the effects
 * on erx_dma_model, the CPU's stores and loads through its cache and the maintenance on its
 * lines. GENET is not coherent, so every plan runs as a non-coherent device's. The register
 * offsets and field masks are the generated table's (hw/svd/genet/genet.svd).
 *
 * The stand-in controller holds its registers in a window of plain memory, the descriptors
 * among them, and reads and writes the model's memory alone. After any effect it may act: its
 * transmit engine takes each descriptor up to the producer index, reads the frame from the
 * address and length the registers hold and compares it with what the driver posted, and
 * advances the consumer index; its receive engine writes a frame into the buffer of the
 * descriptor its producer index names, sets the status's length and flags, and advances the
 * producer index. Its DMA status reports a stop only some reads after DMA control cleared it.
 *
 * Every schedule installs both queues, then runs posts, completions and resets, with the line
 * equal to the granule and a quarter of it. Every posted byte reaches the controller intact,
 * every received frame comes back with the controller's bytes and flags, no completion is
 * missed, and a controller that advances an index or a length past its bound breaks the queue.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "otp/erts/emulator/nifs/erxos/erx_device_dma.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_genet.h"
#include "otp/erts/emulator/nifs/erxos/erx_dma_model.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define GRANULE		64u
#define BUFFER		200u		/* each buffer's bytes; the stand-in's frames reach its end */
#define ROUNDS		600u
#define SCHEDULES	12u
#define DEVICE_BASE	UINT64_C(0x10000)
#define STOP_READS	3u		/* the DMA status reads a stop takes to show */
#define STEPS_MAX	(ERX_DEVICE_GENET_INSTALL_STEPS + 8u)
#define EFFECTS_MAX	ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, STEPS_MAX)
#define SIZE		ERX_DEVICE_GENET_SIZE
#define CRC_ERROR	0x2u		/* receive status bit 1 (docs/design-device-dma.md, The register ring) */

typedef struct direction {
	erx_device_genet_registers_t	regs;
	erx_device_genet_queue_t	queue;
	erx_dma_state_t			state;		/* who writes each buffer, as the last plan left it */
	uint64_t			pool_offset;
	uint32_t			stop_reads;	/* status reads since DMA control stopped the engine */
	uint32_t			ctrl;		/* the stand-in's view of DMA control */
} direction_t;

typedef struct harness {
	erx_dma_model_t		model;
	const erx_device_peripheral_t *genet;
	uint32_t		*window;
	direction_t		rx, tx;
	uint32_t		line;
	uint64_t		random;
	/* What the driver posted on each transmit buffer, compared when the controller sends it. */
	uint8_t			posted[SIZE][BUFFER];
	uint32_t		posted_length[SIZE];
	/* What the controller wrote into each receive buffer: its serial, length and flags. */
	uint32_t		frame_serial[SIZE];
	uint32_t		frame_length[SIZE];
	uint32_t		frame_flags[SIZE];
	uint32_t		serial;
	uint32_t		hostile;	/* 0, or which bound the next controller act breaks */
	uint8_t			copied[32 * BUFFER];
	uint32_t		copied_length;
	uint64_t		values[40];
	uint32_t		value_count;
	uint64_t		sent, received, flagged;
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

/* A frame's bytes are never zero, so a zero in a completion is the zeroing's. */
static uint8_t
pattern(uint32_t serial, uint32_t at)
{
	return ((uint8_t)(1u + (serial * 31u + at * 7u) % 255u));
}

static uint32_t
reg(const harness_t *h, uint32_t offset)
{
	return (h->window[offset / 4]);
}

static void
set_reg(harness_t *h, uint32_t offset, uint32_t value)
{
	h->window[offset / 4] = value;
}

static uint32_t
field(uint32_t mask, uint32_t word)
{
	return ((word & mask) >> __builtin_ctz(mask));
}

static uint32_t
place(uint32_t mask, uint32_t value)
{
	return ((value << __builtin_ctz(mask)) & mask);
}

static uint64_t
descriptor_addr(const harness_t *h, const direction_t *d, uint32_t desc)
{
	return (reg(h, d->regs.desc_addr_lo + desc * d->regs.desc_stride) |
	    (uint64_t)reg(h, d->regs.desc_addr_hi + desc * d->regs.desc_stride) << 32);
}

static bool
running(const direction_t *d)
{
	return ((d->ctrl & d->regs.dma_enable) != 0 &&
	    (d->ctrl & place(d->regs.dma_ring_enable, 1u << ERX_DEVICE_GENET_RING)) != 0);
}

/* -------------------------------------------------------------------------------------------
 * The stand-in controller
 */

/* The transmit engine sends every descriptor up to the producer index, each frame compared with the post. */
static void
transmit(harness_t *h)
{
	direction_t *const d = &h->tx;
	uint16_t cons = (uint16_t)field(d->regs.index, reg(h, d->regs.hardware_index));
	const uint16_t prod = (uint16_t)field(d->regs.index, reg(h, d->regs.software_index));

	for (; running(d) && cons != prod; cons++) {
		const uint32_t desc = cons % SIZE;
		const uint32_t status = reg(h, d->regs.desc_status + desc * d->regs.desc_stride);
		const uint32_t length = field(d->regs.buflen, status);
		uint8_t bytes[BUFFER];

		CHECK((status & d->regs.sop) && (status & d->regs.eop) && (status & d->regs.crc));
		CHECK(length == h->posted_length[desc] && length <= BUFFER);
		CHECK(erx_dma_model_device_read(&h->model, descriptor_addr(h, d, desc) - DEVICE_BASE, bytes, length));
		CHECK(memcmp(bytes, h->posted[desc], length) == 0);
		h->sent++;
	}
	set_reg(h, d->regs.hardware_index, place(d->regs.index, cons));
}

/* The receive engine fills the next free descriptor with a frame and its status, then advances the producer index. */
static void
receive(harness_t *h)
{
	direction_t *const d = &h->rx;
	const uint16_t prod = (uint16_t)field(d->regs.index, reg(h, d->regs.hardware_index));
	const uint16_t cons = (uint16_t)field(d->regs.index, reg(h, d->regs.software_index));
	const uint32_t desc = prod % SIZE;
	uint8_t bytes[BUFFER];
	uint32_t length, prefix, flags;

	if (!running(d) || (uint16_t)(prod - cons) == SIZE)
		return;
	length = draw(h, BUFFER + 1);
	prefix = draw(h, length + 1);		/* the bytes past the prefix it reports but leaves alone */
	flags = d->regs.sop | d->regs.eop;
	if (draw(h, 8) == 0)
		flags = draw(h, 2) == 0 ? flags | CRC_ERROR : d->regs.sop;
	h->serial++;
	for (uint32_t at = 0; at < prefix; at++)
		bytes[at] = pattern(h->serial, at);
	CHECK(erx_dma_model_device_write(&h->model, descriptor_addr(h, d, desc) - DEVICE_BASE, bytes, prefix));
	h->frame_serial[desc] = h->serial;
	h->frame_length[desc] = prefix;
	h->frame_flags[desc] = flags;
	set_reg(h, d->regs.desc_status + desc * d->regs.desc_stride, place(d->regs.buflen, length) | flags);
	set_reg(h, d->regs.hardware_index, place(d->regs.index, (uint16_t)(prod + 1)) |
	    (reg(h, d->regs.hardware_index) & ~d->regs.index));
}

/* A hostile act: an index or a length past its bound, which the next completion must refuse. */
static void
misbehave(harness_t *h)
{
	direction_t *const rx = &h->rx, *const tx = &h->tx;

	switch (h->hostile) {
	case 1:	/* the receive producer index more than the queue's size ahead */
		set_reg(h, rx->regs.hardware_index, place(rx->regs.index, (uint16_t)(rx->queue.software + SIZE + 1)));
		break;
	case 2:	/* the transmit consumer index past what is in flight */
		set_reg(h, tx->regs.hardware_index,
		    place(tx->regs.index, (uint16_t)(tx->queue.hardware + tx->queue.in_flight + 1)));
		break;
	case 3:		/* a received length past the buffer */
	case 4: {	/* a length whose high bit a 12-bit field would drop, leaving a length that fits */
		const uint16_t prod = (uint16_t)field(rx->regs.index, reg(h, rx->regs.hardware_index));
		const uint32_t length = h->hostile == 3 ? BUFFER + 1 : 0x1000u + 10u;

		h->frame_length[prod % SIZE] = 0;
		h->frame_flags[prod % SIZE] = rx->regs.sop | rx->regs.eop;
		set_reg(h, rx->regs.desc_status + (prod % SIZE) * rx->regs.desc_stride,
		    place(rx->regs.buflen, length) | rx->regs.sop | rx->regs.eop);
		set_reg(h, rx->regs.hardware_index, place(rx->regs.index, (uint16_t)(prod + 1)));
		break;
	}
	}
}

static void
device_act(harness_t *h)
{
	if (draw(h, 2) == 0)
		transmit(h);
	else
		receive(h);
}

/* A register write reaches the stand-in's window; DMA control also starts or stops its engine. */
static void
device_register(harness_t *h, const erx_dma_step_t *step)
{
	set_reg(h, step->reg, (uint32_t)step->value);
	if (step->reg_high != ERX_DMA_NO_REGISTER)
		set_reg(h, step->reg_high, (uint32_t)(step->value >> 32));
	for (direction_t *d = &h->rx; d <= &h->tx; d++) {
		if (step->reg != d->regs.dma_ctrl)
			continue;
		d->ctrl = (uint32_t)step->value;
		d->stop_reads = 0;
		set_reg(h, d->regs.dma_status, 0);
	}
}

/* A read of DMA status shows the stop only after STOP_READS reads. */
static uint32_t
device_status(harness_t *h, direction_t *d)
{
	if (!running(d) && ++d->stop_reads > STOP_READS)
		set_reg(h, d->regs.dma_status, d->regs.dma_disabled | d->regs.dma_ring_disabled);
	return (reg(h, d->regs.dma_status));
}

/* -------------------------------------------------------------------------------------------
 * The effect layer over the model
 */

static void
run_step(harness_t *h, const erx_dma_step_t *step)
{
	switch (step->kind) {
	case ERX_DMA_WRITE:
	case ERX_DMA_PUBLISH:
		if (step->target == ERX_DMA_REGISTER)
			device_register(h, step);
		else
			CHECK(step->source == ERX_DMA_BYTES &&
			    erx_dma_model_cpu_store(&h->model, step->offset, step->bytes, step->length));
		break;
	case ERX_DMA_COPY:
		CHECK(h->copied_length + step->length <= sizeof(h->copied));
		CHECK(erx_dma_model_cpu_load(&h->model, step->offset, h->copied + h->copied_length, step->length));
		h->copied_length += (uint32_t)step->length;
		break;
	case ERX_DMA_REPORT:
		CHECK(step->target == ERX_DMA_REGISTER && h->value_count < sizeof(h->values) / sizeof(h->values[0]));
		h->values[h->value_count++] = step->reg == h->rx.regs.dma_status ? device_status(h, &h->rx) :
		    step->reg == h->tx.regs.dma_status ? device_status(h, &h->tx) : reg(h, step->reg);
		break;
	}
}

static erx_dma_context_t
context_of(const harness_t *h, const direction_t *d, erx_dma_length_reg_t *length_reg)
{
	erx_dma_context_t context = { .memory_size = h->model.size, .device_base = DEVICE_BASE,
	    .window_size = h->genet->window_size, .granule = GRANULE };

	erx_device_genet_form(&d->queue, &d->regs, length_reg, &context);
	return (context);
}

/* A plan from the direction's last state to its view now, checked, ordered and run, the model and the controller free to act between effects. */
static void
apply(harness_t *h, direction_t *d, erx_dma_call_t call, const erx_dma_step_t *steps, uint32_t count)
{
	erx_dma_state_t after;
	erx_dma_length_reg_t length_reg;
	const erx_dma_context_t context = context_of(h, d, &length_reg);
	const erx_dma_plan_t plan = { .call = call, .count = count, .steps = steps };
	erx_dma_effects_t effects = { .capacity = EFFECTS_MAX, .effects = effect_storage };

	erx_device_genet_view(&d->queue, d->pool_offset, &after);
	CHECK(erx_device_dma_check(&context, &d->state, &after, &plan));
	CHECK(erx_device_dma_order(&d->state, &after, &plan, false, GRANULE, h->line, &effects));
	if (call == ERX_DMA_CALL_OBSERVE)
		h->value_count = 0;
	for (uint32_t index = 0; index < effects.count; index++) {
		const erx_dma_effect_t *const effect = &effects.effects[index];

		switch (effect->kind) {
		case ERX_DMA_EFFECT_ZERO:
			CHECK(erx_dma_model_cpu_zero(&h->model, effect->offset, effect->length));
			break;
		case ERX_DMA_EFFECT_STEP:
			run_step(h, &plan.steps[effect->step]);
			break;
		case ERX_DMA_EFFECT_CLEAN:
			CHECK(erx_dma_model_clean(&h->model, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_CLEAN_INVAL:
			CHECK(erx_dma_model_clean_inval(&h->model, effect->offset, effect->length, effect->line));
			break;
		case ERX_DMA_EFFECT_BARRIER:
			break;
		}
		erx_dma_model_tick(&h->model);
		if (h->hostile == 0 && call != ERX_DMA_CALL_OBSERVE && draw(h, 4) == 0)
			device_act(h);
	}
	d->state = after;
}

/* -------------------------------------------------------------------------------------------
 * The form's calls
 */

/* The reset: DMA control stopped, the idle report awaited (ebusy until it shows), every buffer taken back, then the install. */
static void
negotiate(harness_t *h, direction_t *d)
{
	erx_dma_step_t steps[STEPS_MAX];
	uint32_t count, busy = 0;

	device_register(h, &(erx_dma_step_t){ .reg = d->regs.dma_ctrl, .reg_high = ERX_DMA_NO_REGISTER,
	    .value = erx_device_genet_stop(&d->regs) });
	for (;;) {
		erx_device_genet_idle_report(&d->regs, &steps[0]);
		apply(h, d, ERX_DMA_CALL_OBSERVE, steps, 1);
		if (erx_device_genet_idle(&d->regs, h->values[0]))
			break;
		/* Not idle yet: the NIF answers ebusy, installs nothing and the driver retries. */
		CHECK(++busy <= STOP_READS && !running(d));
	}
	CHECK(busy == STOP_READS);
	CHECK(!erx_device_genet_reset(&d->queue, &d->regs, 0));
	CHECK(erx_device_genet_reset(&d->queue, &d->regs, h->values[0]));
	apply(h, d, ERX_DMA_CALL_RESET, steps, 0);
	count = erx_device_genet_install_steps(&d->queue, &d->regs, DEVICE_BASE + d->pool_offset, steps);
	CHECK(count != 0 && count <= STEPS_MAX);
	apply(h, d, ERX_DMA_CALL_INSTALL, steps, count);
	CHECK(erx_device_genet_install_steps(&d->queue, &d->regs, DEVICE_BASE + d->pool_offset, steps) == 0);
	CHECK(!running(d));
	/* The start hands nothing over, so it is a publish whose state is the install's. */
	erx_device_genet_start(&d->regs, &steps[0]);
	apply(h, d, ERX_DMA_CALL_POST, steps, 1);
	CHECK(running(d));
}

static void
post(harness_t *h)
{
	direction_t *const d = &h->tx;
	erx_dma_step_t steps[STEPS_MAX];
	erx_device_genet_piece_t pieces[2];
	uint8_t frame[BUFFER];
	const uint32_t length = 1 + draw(h, BUFFER), split = draw(h, length);
	const uint32_t buffer = d->queue.software % SIZE, serial = ++h->serial;
	uint32_t count;
	bool full;

	for (uint32_t at = 0; at < length; at++)
		frame[at] = pattern(serial, at);
	pieces[0] = (erx_device_genet_piece_t){ frame, split == 0 ? length : split };
	pieces[1] = (erx_device_genet_piece_t){ frame + split, length - split };
	if (!erx_device_genet_post(&d->queue, &d->regs, d->pool_offset, pieces, split == 0 ? 1 : 2, serial, steps, &count,
	    &full)) {
		CHECK(full && d->queue.in_flight == SIZE);
		return;
	}
	memcpy(h->posted[buffer], frame, length);
	h->posted_length[buffer] = length;
	apply(h, d, ERX_DMA_CALL_POST, steps, count);
}

/* A transmit completion: the consumer index, then the buffers taken back with no copy. */
static bool
tx_complete(harness_t *h)
{
	direction_t *const d = &h->tx;
	erx_dma_step_t steps[1];
	erx_device_genet_completion_t completions[32];
	uint32_t done;

	erx_device_genet_index_report(&d->regs, &steps[0]);
	apply(h, d, ERX_DMA_CALL_OBSERVE, steps, 1);
	if (!erx_device_genet_tx_complete(&d->queue, &d->regs, h->values[0], 32, completions, &done))
		return (false);
	if (done != 0)
		apply(h, d, ERX_DMA_CALL_COMPLETE, steps, 0);
	return (true);
}

/* A receive completion: the producer index, each new status, the frames copied, then the buffers handed back. */
static bool
rx_complete(harness_t *h)
{
	direction_t *const d = &h->rx;
	erx_dma_step_t steps[STEPS_MAX];
	erx_device_genet_completion_t completions[32];
	uint64_t statuses[32];
	uint32_t count, done;

	erx_device_genet_index_report(&d->regs, &steps[0]);
	apply(h, d, ERX_DMA_CALL_OBSERVE, steps, 1);
	if (!erx_device_genet_rx_reports(&d->queue, &d->regs, h->values[0], 32, steps, &count))
		return (false);
	if (count == 0)
		return (true);
	apply(h, d, ERX_DMA_CALL_OBSERVE, steps, count);
	memcpy(statuses, h->values, count * sizeof(statuses[0]));
	CHECK(!erx_device_genet_rx_complete(&d->queue, &d->regs, statuses, count + 1, completions, &done));
	CHECK(erx_device_genet_rx_complete(&d->queue, &d->regs, statuses, count, completions, &done));
	count = erx_device_genet_copy_steps(&d->queue, d->pool_offset, completions, done, steps);
	h->copied_length = 0;
	apply(h, d, ERX_DMA_CALL_COMPLETE, steps, count);
	for (uint32_t frame = 0, at = 0; frame < done; frame++) {
		const uint32_t buffer = completions[frame].buffer;
		const uint32_t good = d->regs.sop | d->regs.eop;

		CHECK(completions[frame].tag == h->frame_flags[buffer]);
		for (uint32_t byte = 0; byte < completions[frame].length; byte++, at++)
			CHECK(h->copied[at] == (byte < h->frame_length[buffer] ? pattern(h->frame_serial[buffer], byte) : 0));
		if ((completions[frame].tag & good) != good || (completions[frame].tag & CRC_ERROR) != 0)
			h->flagged++;
		h->received++;
	}
	count = erx_device_genet_rx_give(&d->queue, &d->regs, steps);
	if (count != 0)
		apply(h, d, ERX_DMA_CALL_POST, steps, count);
	return (!d->queue.broken);
}

/* -------------------------------------------------------------------------------------------
 * The check's view of register descriptors
 */

/* Plans a planted core might make, each of which the check refuses. */
static void
check_refusals(harness_t *h, direction_t *d)
{
	erx_dma_length_reg_t length_reg;
	const erx_dma_context_t context = context_of(h, d, &length_reg);
	const uint32_t desc = 3;
	const erx_dma_step_t refused[] = {
		/* a length past the reach in a descriptor's status */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE, .width = 4,
		  .reg = d->regs.desc_status + desc * d->regs.desc_stride, .reg_high = ERX_DMA_NO_REGISTER,
		  .value = place(d->regs.buflen, BUFFER + 1) },
		/* a buffer length past the reach in the ring's size register */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE, .width = 4,
		  .reg = d->regs.buf_size, .reg_high = ERX_DMA_NO_REGISTER, .value = place(d->regs.buf_length, BUFFER + 1) },
		/* an address as a plain value into a descriptor's low register */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE, .width = 4,
		  .reg = d->regs.desc_addr_lo + desc * d->regs.desc_stride, .reg_high = ERX_DMA_NO_REGISTER, .value = 0x1234 },
		/* an address with a reach other than the buffer size */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
		  .reg = d->regs.desc_addr_lo + desc * d->regs.desc_stride, .reg_high = d->regs.desc_addr_hi + desc * d->regs.desc_stride,
		  .value = DEVICE_BASE + d->pool_offset, .extent = 2 * BUFFER },
		/* an address over two descriptors' registers */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
		  .reg = d->regs.desc_addr_lo + desc * d->regs.desc_stride, .reg_high = d->regs.desc_addr_hi,
		  .value = DEVICE_BASE + d->pool_offset, .extent = BUFFER },
		/* an address past the form's 40 bits */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
		  .reg = d->regs.desc_addr_lo + desc * d->regs.desc_stride, .reg_high = d->regs.desc_addr_hi + desc * d->regs.desc_stride,
		  .value = UINT64_C(1) << 40, .extent = BUFFER },
		/* an address whose low half lands in the ring's buffer length */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
		  .reg = d->regs.buf_size, .reg_high = d->regs.start[1], .value = DEVICE_BASE + d->pool_offset + 0xfff0u,
		  .extent = 16 },
		/* an address whose high half lands in the ring's buffer length */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_ADDRESS, .width = 8,
		  .reg = d->regs.start[0], .reg_high = d->regs.buf_size, .value = DEVICE_BASE + d->pool_offset, .extent = 16 },
		/* a ring register the form does not own: ring 15's producer index */
		{ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE, .width = 4,
		  .reg = d->regs.software_index - 0x40u, .reg_high = ERX_DMA_NO_REGISTER, .value = 1 },
	};
	const erx_dma_step_t accepted = { .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE,
	    .width = 4, .reg = d->regs.desc_status + desc * d->regs.desc_stride, .reg_high = ERX_DMA_NO_REGISTER,
	    .value = place(d->regs.buflen, BUFFER) | d->regs.sop };

	for (uint32_t at = 0; at < sizeof(refused) / sizeof(refused[0]); at++) {
		const erx_dma_plan_t plan = { .call = ERX_DMA_CALL_POST, .count = 1, .steps = &refused[at] };

		if (erx_device_dma_check(&context, &d->state, &d->state, &plan)) {
			printf("FAILED %s:%d: refused plan %u accepted\n", __FILE__, __LINE__, at);
			exit(1);
		}
	}
	CHECK(erx_device_dma_check(&context, &d->state, &d->state,
	    &(erx_dma_plan_t){ .call = ERX_DMA_CALL_POST, .count = 1, .steps = &accepted }));
}

/* -------------------------------------------------------------------------------------------
 * Schedules
 */

static harness_t *
harness_new(uint32_t line, uint64_t seed)
{
	harness_t *const h = calloc(1, sizeof(*h));
	uint64_t rx_bytes;

	CHECK(h != NULL);
	h->genet = erx_device_peripheral_find("genet", sizeof("genet") - 1);
	CHECK(h->genet != NULL && h->genet->window_size % 4 == 0);
	h->window = calloc(h->genet->window_size / 4, sizeof(uint32_t));
	CHECK(h->window != NULL);
	CHECK(erx_device_genet_registers(h->genet, ERX_DEVICE_GENET_RX, &h->rx.regs));
	CHECK(erx_device_genet_registers(h->genet, ERX_DEVICE_GENET_TX, &h->tx.regs));
	/* One object holds both pools, receive first, as the device's one contiguous memory does. */
	CHECK(erx_device_genet_init(&h->rx.queue, &h->rx.regs, BUFFER, GRANULE, DEVICE_BASE));
	rx_bytes = erx_device_genet_bytes(&h->rx.queue);
	CHECK(erx_device_genet_init(&h->tx.queue, &h->tx.regs, BUFFER, GRANULE, DEVICE_BASE + rx_bytes));
	h->tx.pool_offset = rx_bytes;
	CHECK(erx_dma_model_init(&h->model, rx_bytes + erx_device_genet_bytes(&h->tx.queue), GRANULE, line, seed));
	h->line = line;
	h->random = seed * 0x9e3779b97f4a7c15u + 1;
	erx_device_genet_view(&h->rx.queue, h->rx.pool_offset, &h->rx.state);
	erx_device_genet_view(&h->tx.queue, h->tx.pool_offset, &h->tx.state);
	return (h);
}

static void
harness_free(harness_t *h)
{
	erx_dma_model_fini(&h->model);
	free(h->window);
	free(h);
}

/* One schedule: both queues installed, receive first, then posts, completions and resets. */
static void
schedule(uint32_t line, uint64_t seed, uint64_t *sent, uint64_t *received, uint64_t *flagged)
{
	harness_t *const h = harness_new(line, seed);

	negotiate(h, &h->rx);
	negotiate(h, &h->tx);
	check_refusals(h, &h->rx);
	check_refusals(h, &h->tx);
	for (uint32_t round = 0; round < ROUNDS; round++) {
		const uint32_t action = draw(h, 32);

		if (action < 12)
			post(h);
		else if (action < 20)
			CHECK(tx_complete(h));
		else if (action < 30)
			CHECK(rx_complete(h));
		else if (round > ROUNDS / 2)
			negotiate(h, action == 30 ? &h->rx : &h->tx);
	}
	/* Whatever was posted is sent and completes: nothing is lost. */
	while (h->tx.queue.in_flight != 0) {
		transmit(h);
		CHECK(tx_complete(h));
	}
	*sent += h->sent;
	*received += h->received;
	*flagged += h->flagged;
	harness_free(h);
}

/* Each hostile act breaks the queue it reaches, and the queue refuses every later call until its reset. */
static void
hostile(uint32_t act)
{
	harness_t *const h = harness_new(GRANULE, act);

	/* The controller acts only when the schedule says, so the hostile act is what the next completion reads. */
	h->hostile = act;
	negotiate(h, &h->rx);
	negotiate(h, &h->tx);
	for (uint32_t round = 0; round < 8; round++)
		post(h);
	transmit(h);
	misbehave(h);
	if (act == 2) {
		CHECK(!tx_complete(h) && h->tx.queue.broken);
		CHECK(!tx_complete(h));
		negotiate(h, &h->tx);
		CHECK(tx_complete(h) && !h->tx.queue.broken);
	} else {
		CHECK(!rx_complete(h) && h->rx.queue.broken);
		CHECK(!rx_complete(h));
		negotiate(h, &h->rx);
		CHECK(!h->rx.queue.broken && rx_complete(h));
	}
	harness_free(h);
}

int
main(void)
{
	const uint32_t lines[] = { GRANULE, GRANULE / 4 };

	for (uint32_t line = 0; line < 2; line++) {
		uint64_t sent = 0, received = 0, flagged = 0;

		for (uint64_t seed = 1; seed <= SCHEDULES; seed++)
			schedule(lines[line], seed, &sent, &received, &flagged);
		/* The controller did move frames both ways, flagged ones among them. */
		CHECK(sent > SCHEDULES * 10 && received > SCHEDULES * 10 && flagged > 0);
		printf("line %u: %llu sent, %llu received, %llu flagged\n", lines[line], (unsigned long long)sent,
		    (unsigned long long)received, (unsigned long long)flagged);
	}
	for (uint32_t act = 1; act <= 4; act++)
		hostile(act);
	printf("erx_device_genet_model done\n");
	return (0);
}
