/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GENET's controller as the register ring sees it (erx_device_genet_model.h). Every read of
 * the device's state is a load of the window and every effect a store to it or a copy
 * through the caller's memory accessor, so the model holds no copy of a register that the
 * driver could change behind it. Offsets are the generated table's (hw/svd/genet/genet.svd),
 * which erx_device_genet_registers validates, so each register load and store is inside the
 * window; descriptor indexes are reduced modulo the ring's size before they become offsets.
 */

#include <stdatomic.h>

#include "erx_device_genet_model.h"

/* GENET v5's major revision, the one erx_genet_core:identify/1 drives (if_genetreg.h:39, 41-43). */
#define GENET_MAJOR	6u

/* ALIGN_2B's padding before a received frame. */
#define ALIGN_BYTES	2u

/*
 * The model's PHY: a BCM54213PE whose link is up at 1000 Mb/s full duplex, at every MDIO
 * address. Each clause 22 register reads as listed here, 0 if not listed, and a write is
 * taken and changes nothing, so a reset is over at once. The ID words are those
 * erx_phy_c22:identify/2 decodes as OUI 0x18c086, model 0x0a; the status register is link
 * and autonegotiation complete (BMSR_LINK and BMSR_ACOMP of FreeBSD's mii.h); the auxiliary
 * status is link with 1000BASE-T full duplex resolved (BRGPHY_AUXSTS_LINK and
 * BRGPHY_RES_1000FD of brgphyreg.h).
 */
static const uint16_t phy[32] = {
	[0x01] = 0x0024,	/* BMSR */
	[0x02] = 0x600d,	/* PHYIDR1 */
	[0x03] = 0x84a2,	/* PHYIDR2 */
	[0x19] = 0x0704,	/* AUXSTS */
};

static uint32_t
load(const erx_device_genet_model_t *model, uint32_t offset)
{
	return (*(volatile const uint32_t *)(const volatile void *)(model->window + offset));
}

static void
store(const erx_device_genet_model_t *model, uint32_t offset, uint32_t value)
{
	*(volatile uint32_t *)(volatile void *)(model->window + offset) = value;
}

/* A field's value in a word, and a value in place as the field; `mask` is never 0. */
static uint32_t
bits(uint32_t mask, uint32_t word)
{
	return ((word & mask) >> __builtin_ctz(mask));
}

static uint32_t
place(uint32_t mask, uint32_t value)
{
	return ((value << __builtin_ctz(mask)) & mask);
}

/* The mask of the named field of the named register, 0 for none. */
static uint32_t
field_mask(const erx_device_peripheral_t *genet, uint32_t reg, const char *name)
{
	const erx_device_register_t *const found = &genet->registers[reg];
	const uint32_t at = erx_device_field_named(genet, found, name);

	return (at < found->field_count ? (uint32_t)genet->fields[found->first_field + at].mask : 0);
}

bool
erx_device_genet_model_init(erx_device_genet_model_t *model, const erx_device_peripheral_t *genet,
    volatile uint8_t *window, uint32_t stop_reads)
{
	const uint32_t rev = erx_device_register_named(genet, "sys_rev_ctrl");
	const uint32_t mdio = erx_device_register_named(genet, "mdio_cmd");

	*model = (erx_device_genet_model_t){ .window = window, .stop_reads = stop_reads };
	if (!erx_device_genet_registers(genet, ERX_DEVICE_GENET_RX, &model->regs[ERX_DEVICE_GENET_RX]) ||
	    !erx_device_genet_registers(genet, ERX_DEVICE_GENET_TX, &model->regs[ERX_DEVICE_GENET_TX]) ||
	    rev >= genet->register_count || mdio >= genet->register_count)
		return (false);
	model->rev = genet->registers[rev].offset;
	model->rev_major = field_mask(genet, rev, "major");
	model->mdio = genet->registers[mdio].offset;
	model->mdio_busy = field_mask(genet, mdio, "start_busy");
	model->mdio_read = field_mask(genet, mdio, "read");
	model->mdio_reg = field_mask(genet, mdio, "reg");
	model->mdio_value = field_mask(genet, mdio, "value");
	return (model->rev_major != 0 && model->mdio_busy != 0 && model->mdio_read != 0 && model->mdio_reg != 0 &&
	    model->mdio_value != 0);
}

void
erx_device_genet_model_preset(erx_device_genet_model_t *model)
{
	store(model, model->rev, place(model->rev_major, GENET_MAJOR));
}

/* DMA status as the stop count leaves it: the block and every ring stopped once the stop has shown. */
static void
settle(erx_device_genet_model_t *model, erx_device_genet_direction_t direction)
{
	const erx_device_genet_registers_t *const regs = &model->regs[direction];
	const bool stopped = (load(model, regs->dma_ctrl) & regs->dma_enable) == 0 &&
	    model->reads[direction] >= model->stop_reads;

	store(model, regs->dma_status, stopped ? regs->dma_disabled | regs->dma_ring_disabled : 0);
}

/* An MDIO command, which a store with START_BUSY set starts, finishes: busy clears, a read's value becomes the PHY's register. */
static void
mdio_finish(erx_device_genet_model_t *model, uint32_t value)
{
	uint32_t word;

	if ((value & model->mdio_busy) == 0)
		return;
	word = value & ~model->mdio_busy;
	if ((value & model->mdio_read) != 0)
		word = (word & ~model->mdio_value) | place(model->mdio_value, phy[bits(model->mdio_reg, value) % 32u]);
	store(model, model->mdio, word);
}

void
erx_device_genet_model_stored(erx_device_genet_model_t *model, uint32_t offset, uint32_t value)
{
	if (offset == model->mdio)
		mdio_finish(model, value);
	for (uint32_t direction = ERX_DEVICE_GENET_RX; direction <= ERX_DEVICE_GENET_TX; direction++) {
		if (offset != model->regs[direction].dma_ctrl)
			continue;
		model->reads[direction] = 0;
		settle(model, (erx_device_genet_direction_t)direction);
	}
}

uint32_t
erx_device_genet_model_load(erx_device_genet_model_t *model, uint32_t offset)
{
	for (uint32_t direction = ERX_DEVICE_GENET_RX; direction <= ERX_DEVICE_GENET_TX; direction++) {
		if (offset != model->regs[direction].dma_status)
			continue;
		settle(model, (erx_device_genet_direction_t)direction);
		if (model->reads[direction] < model->stop_reads)
			model->reads[direction]++;
	}
	return (load(model, offset));
}

bool
erx_device_genet_model_running(const erx_device_genet_model_t *model, erx_device_genet_direction_t direction)
{
	const erx_device_genet_registers_t *const regs = &model->regs[direction];
	const uint32_t ring = UINT32_C(1) << ERX_DEVICE_GENET_RING;
	const uint32_t ctrl = load(model, regs->dma_ctrl);

	return ((ctrl & regs->dma_enable) != 0 && (ctrl & place(regs->dma_ring_enable, ring)) != 0 &&
	    (load(model, regs->ring_cfg) & place(regs->ring_enable, ring)) != 0);
}

uint32_t
erx_device_genet_model_buffer_bytes(const erx_device_genet_model_t *model, erx_device_genet_direction_t direction)
{
	const erx_device_genet_registers_t *const regs = &model->regs[direction];

	return (bits(regs->buf_length, load(model, regs->buf_size)));
}

/* The device address descriptor `desc` holds. */
static uint64_t
descriptor_addr(const erx_device_genet_model_t *model, const erx_device_genet_registers_t *regs, uint32_t desc)
{
	return (load(model, regs->desc_addr_lo + desc * regs->desc_stride) |
	    (uint64_t)load(model, regs->desc_addr_hi + desc * regs->desc_stride) << 32);
}

int
erx_device_genet_model_transmit(erx_device_genet_model_t *model, const erx_device_genet_memory_t *memory,
    erx_device_genet_model_sink_t *sink, void *context, uint32_t *sent)
{
	const erx_device_genet_registers_t *const regs = &model->regs[ERX_DEVICE_GENET_TX];
	/* Each frame in one descriptor, which the controller ends with the Ethernet CRC. */
	const uint32_t whole = regs->sop | regs->eop | regs->crc;
	const uint32_t reach = erx_device_genet_model_buffer_bytes(model, ERX_DEVICE_GENET_TX);
	uint32_t consumer, producer;
	bool refused = false;

	*sent = 0;
	if (!erx_device_genet_model_running(model, ERX_DEVICE_GENET_TX))
		return (ERX_OK);
	consumer = bits(regs->index, load(model, regs->hardware_index));
	producer = bits(regs->index, load(model, regs->software_index));
	/* A producer more than a ring ahead has written over descriptors not yet sent. */
	if (bits(regs->index, producer - consumer) > ERX_DEVICE_GENET_SIZE)
		return (ERX_ECORRUPT);
	atomic_thread_fence(memory_order_acquire);
	for (; consumer != producer; (*sent)++) {
		const uint32_t desc = consumer % ERX_DEVICE_GENET_SIZE;
		const uint32_t status = load(model, regs->desc_status + desc * regs->desc_stride);
		const uint32_t length = bits(regs->buflen, status);

		refused = (status & whole) != whole || length > reach ||
		    !memory->read(memory->context, descriptor_addr(model, regs, desc), sink(context, desc, length), length);
		if (refused)
			break;
		consumer = bits(regs->index, consumer + 1u);
	}
	atomic_thread_fence(memory_order_release);
	store(model, regs->hardware_index, place(regs->index, consumer));
	return (refused ? ERX_ECORRUPT : ERX_OK);
}

int
erx_device_genet_model_receive(erx_device_genet_model_t *model, const erx_device_genet_memory_t *memory,
    const erx_device_genet_model_frame_t *frame, bool *taken)
{
	static const uint8_t zeros[ALIGN_BYTES];
	const erx_device_genet_registers_t *const regs = &model->regs[ERX_DEVICE_GENET_RX];
	const uint32_t pad = frame->aligned ? ALIGN_BYTES : 0u;
	const uint32_t reach = erx_device_genet_model_buffer_bytes(model, ERX_DEVICE_GENET_RX);
	uint32_t producer, consumer, desc, length;
	uint64_t addr;

	*taken = false;
	if (!erx_device_genet_model_running(model, ERX_DEVICE_GENET_RX))
		return (ERX_OK);
	producer = bits(regs->index, load(model, regs->hardware_index));
	consumer = bits(regs->index, load(model, regs->software_index));
	/* The ring full is no fault: the frame waits for a buffer the driver hands back. */
	if (bits(regs->index, producer - consumer) >= ERX_DEVICE_GENET_SIZE)
		return (ERX_OK);
	/* BUF_SIZE is 16 bits, as BUFLEN is, so a frame within the buffer has a length its status holds. */
	if (frame->written > frame->length || frame->length > reach || reach - frame->length < pad ||
	    bits(regs->buflen, place(regs->buflen, frame->length + pad)) != frame->length + pad)
		return (ERX_EINVAL);
	atomic_thread_fence(memory_order_acquire);
	desc = producer % ERX_DEVICE_GENET_SIZE;
	addr = descriptor_addr(model, regs, desc);
	length = pad + frame->length;
	if (addr > UINT64_MAX - pad || !memory->write(memory->context, addr, zeros, pad) ||
	    !memory->write(memory->context, addr + pad, frame->bytes, frame->written))
		return (ERX_ECORRUPT);
	atomic_thread_fence(memory_order_release);
	store(model, regs->desc_status + desc * regs->desc_stride, place(regs->buflen, length) |
	    (frame->flags & ~regs->buflen));
	atomic_thread_fence(memory_order_release);
	store(model, regs->hardware_index,
	    place(regs->index, producer + 1u) | (load(model, regs->hardware_index) & ~regs->index));
	*taken = true;
	return (ERX_OK);
}
