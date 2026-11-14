/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The register ring's pure core (erx_device_genet.h).
 */

#include <string.h>

#include "erx_device_genet.h"

#define MASK	(ERX_GENET_RING_SIZE - 1u)
_Static_assert((ERX_GENET_RING_SIZE & MASK) == 0 && ERX_GENET_RING_SIZE <= 65536u,
    "the 16-bit free-running indexes wrap on a power-of-two ring");
_Static_assert(ERX_GENET_RING < 32u, "the ring's bit fits a 32-bit register");

/*
 * The faults test/host/erx_device_genet_test.rb plants: the receive length's bound removed, a
 * transmit descriptor posted without its append-CRC bit, and the start written without the
 * engine's enable.
 */
#ifdef ERX_DEVICE_GENET_SEED_NO_LENGTH_BOUND
#define SEED_NO_LENGTH_BOUND	true
#else
#define SEED_NO_LENGTH_BOUND	false
#endif
#ifdef ERX_DEVICE_GENET_SEED_NO_TX_CRC
#define SEED_NO_TX_CRC		true
#else
#define SEED_NO_TX_CRC		false
#endif
#ifdef ERX_DEVICE_GENET_SEED_NO_DMA_ENABLE
#define SEED_NO_DMA_ENABLE	true
#else
#define SEED_NO_DMA_ENABLE	false
#endif

/* -------------------------------------------------------------------------------------------
 * The table
 */

static const char *const register_names[2][15] = {
	[ERX_DEVICE_GENET_RX] = { "rx_desc_status", "rx_desc_addr_lo", "rx_desc_addr_hi", "rx_ring_prod_index",
	    "rx_ring_cons_index", "rx_ring_buf_size", "rx_ring_start_addr_lo", "rx_ring_start_addr_hi",
	    "rx_ring_end_addr_lo", "rx_ring_end_addr_hi", "rx_ring_write_ptr_lo", "rx_ring_write_ptr_hi",
	    "rx_ring_read_ptr_lo", "rx_ring_read_ptr_hi", "rx_dma_ring_cfg" },	/* the hardware's pointer, then the NIF's */
	[ERX_DEVICE_GENET_TX] = { "tx_desc_status", "tx_desc_addr_lo", "tx_desc_addr_hi", "tx_ring_cons_index",
	    "tx_ring_prod_index", "tx_ring_buf_size", "tx_ring_start_addr_lo", "tx_ring_start_addr_hi",
	    "tx_ring_end_addr_lo", "tx_ring_end_addr_hi", "tx_ring_read_ptr_lo", "tx_ring_read_ptr_hi",
	    "tx_ring_write_ptr_lo", "tx_ring_write_ptr_hi", "tx_dma_ring_cfg" },
};
static const char *const control_names[2][2] = {
	[ERX_DEVICE_GENET_RX] = { "rx_dma_ctrl", "rx_dma_status" },
	[ERX_DEVICE_GENET_TX] = { "tx_dma_ctrl", "tx_dma_status" },
};

/* A register by name, NULL for none. */
static const erx_device_register_t *
named(const erx_device_peripheral_t *genet, const char *name)
{
	const uint32_t found = erx_device_register_named(genet, name);

	return (found == genet->register_count ? NULL : &genet->registers[found]);
}

/* The window offset of a register, or of the one ring's element of a ring register, or of descriptor 0's. */
static bool
offset_of(const erx_device_register_t *reg, uint32_t element, uint32_t *offset)
{
	uint64_t at;

	if (reg == NULL || !erx_device_element_offset(reg, reg->count > 1, element, &at) || at > UINT32_MAX - 4u)
		return (false);
	*offset = (uint32_t)at;
	return (true);
}

/* A field's mask in place, 0 for none; every field the form uses fits the 32-bit register. */
static uint32_t
mask_of(const erx_device_peripheral_t *genet, const erx_device_register_t *reg, const char *name)
{
	uint32_t found;

	if (reg == NULL)
		return (0);
	found = erx_device_field_named(genet, reg, name);
	return (found == reg->field_count || genet->fields[reg->first_field + found].mask > UINT32_MAX ? 0 :
	    (uint32_t)genet->fields[reg->first_field + found].mask);
}

bool
erx_device_genet_registers(const erx_device_peripheral_t *genet, erx_device_genet_direction_t direction,
    erx_device_genet_registers_t *regs)
{
	const erx_device_register_t *found[15];
	uint32_t *const ring[] = { &regs->hardware_index, &regs->software_index, &regs->buf_size, &regs->start[0],
	    &regs->start[1], &regs->end[0], &regs->end[1], &regs->hardware_ptr[0], &regs->hardware_ptr[1], &regs->software_ptr[0],
	    &regs->software_ptr[1], &regs->ring_cfg };
	const erx_device_register_t *ctrl, *status;

	if (genet == NULL || (direction != ERX_DEVICE_GENET_RX && direction != ERX_DEVICE_GENET_TX))
		return (false);
	memset(regs, 0, sizeof(*regs));
	regs->direction = direction;
	for (uint32_t at = 0; at < 15; at++)
		found[at] = named(genet, register_names[direction][at]);
	ctrl = named(genet, control_names[direction][0]);
	status = named(genet, control_names[direction][1]);
	/* Descriptors: 256 elements of one stride, the three registers of one descriptor within it. */
	for (uint32_t at = 0; at < 3; at++) {
		if (found[at] == NULL || found[at]->count != ERX_GENET_RING_SIZE || found[at]->stride != found[0]->stride)
			return (false);
	}
	if (!offset_of(found[0], 0, &regs->desc_status) || !offset_of(found[1], 0, &regs->desc_addr_lo) ||
	    !offset_of(found[2], 0, &regs->desc_addr_hi))
		return (false);
	regs->desc_stride = found[0]->stride;
	if (regs->desc_addr_lo != regs->desc_status + 4u || regs->desc_addr_hi != regs->desc_status + 8u ||
	    regs->desc_stride != 12u)
		return (false);
	for (uint32_t at = 0; at < 12; at++) {
		if (!offset_of(found[3 + at], ERX_GENET_RING, ring[at]))
			return (false);
	}
	if (!offset_of(ctrl, 0, &regs->dma_ctrl) || !offset_of(status, 0, &regs->dma_status))
		return (false);
	for (uint32_t at = 0; at < 12; at++)
		regs->owned[at] = *ring[at];
	regs->owned[12] = regs->dma_ctrl;
	regs->index = mask_of(genet, found[3], "index");
	regs->buflen = mask_of(genet, found[0], "buflen");
	regs->sop = mask_of(genet, found[0], "sop");
	regs->eop = mask_of(genet, found[0], "eop");
	regs->crc = direction == ERX_DEVICE_GENET_TX ? mask_of(genet, found[0], "crc") : 0;
	regs->buf_length = mask_of(genet, found[5], "buf_length");
	regs->desc_count = mask_of(genet, found[5], "desc_count");
	regs->ring_enable = mask_of(genet, found[14], "enable");
	regs->dma_enable = mask_of(genet, ctrl, "en");
	regs->dma_ring_enable = mask_of(genet, ctrl, "rbuf_en");
	regs->dma_disabled = mask_of(genet, status, "disabled");
	regs->dma_ring_disabled = mask_of(genet, status, "ring_disabled");
	return (regs->index != 0 && regs->buflen != 0 && regs->sop != 0 && regs->eop != 0 &&
	    (direction == ERX_DEVICE_GENET_RX || regs->crc != 0) && regs->buf_length != 0 && regs->desc_count != 0 &&
	    regs->ring_enable != 0 && regs->dma_enable != 0 && regs->dma_ring_enable != 0 && regs->dma_disabled != 0 &&
	    regs->dma_ring_disabled != 0);
}

/* -------------------------------------------------------------------------------------------
 * Fields
 */

static uint32_t
shift_of(uint32_t mask)
{
	return ((uint32_t)__builtin_ctz(mask));
}

/* The largest value a field holds. */
static uint32_t
field_max(uint32_t mask)
{
	return (mask >> shift_of(mask));
}

/* `value` placed in the field; the caller keeps it within field_max. */
static uint32_t
field_put(uint32_t mask, uint32_t value)
{
	return ((value << shift_of(mask)) & mask);
}

static uint32_t
field_get(uint32_t mask, uint64_t word)
{
	return ((uint32_t)((word & mask) >> shift_of(mask)));
}

/* Bit `bit` of a per-ring field, ring q at the field's bit q. */
static uint32_t
ring_bit(uint32_t mask, uint32_t ring)
{
	return (field_put(mask, UINT32_C(1) << ring));
}

/* -------------------------------------------------------------------------------------------
 * The queue
 */

static bool
power_of_two(uint32_t value)
{
	return (value != 0 && (value & (value - 1)) == 0);
}

bool
erx_device_genet_init(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    uint32_t buffer_size, uint32_t granule, uint64_t pool_addr)
{
	uint64_t stride, bytes;

	if (!power_of_two(granule) || granule > ERX_DEVICE_GRANULE_MAX || buffer_size == 0 ||
	    buffer_size > ERX_DEVICE_BUFFER_MAX || buffer_size > field_max(regs->buflen) ||
	    buffer_size > field_max(regs->buf_length))
		return (false);
	stride = ((uint64_t)buffer_size + granule - 1) & ~(uint64_t)(granule - 1);
	bytes = stride * ERX_GENET_RING_SIZE;
	/* The last byte the device may reach lies below the width. */
	if (pool_addr >> ERX_DEVICE_GENET_ADDRESS_BITS != 0 ||
	    bytes > (UINT64_C(1) << ERX_DEVICE_GENET_ADDRESS_BITS) - pool_addr)
		return (false);
	memset(queue, 0, sizeof(*queue));
	queue->direction = regs->direction;
	queue->buffer_size = buffer_size;
	queue->stride = (uint32_t)stride;
	return (true);
}

uint64_t
erx_device_genet_bytes(const erx_device_genet_queue_t *queue)
{
	return ((uint64_t)queue->stride * ERX_GENET_RING_SIZE);
}

void
erx_device_genet_form(const erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    erx_dma_length_reg_t *length_reg, erx_dma_context_t *context)
{
	*length_reg = (erx_dma_length_reg_t){ .reg = regs->buf_size, .mask = regs->buf_length };
	context->address_bits = ERX_DEVICE_GENET_ADDRESS_BITS;
	context->publication = ERX_DMA_NO_PUBLICATION;
	context->publication_width = 0;
	context->owned_count = ERX_DEVICE_GENET_OWNED;
	context->owned = regs->owned;
	context->descriptor_count = 0;
	context->reg_descriptors = regs->desc_status;
	context->reg_descriptor_count = ERX_GENET_RING_SIZE;
	context->reg_descriptor_size = regs->desc_stride;
	context->reg_address_field = regs->desc_addr_lo - regs->desc_status;
	context->reg_address_high_field = regs->desc_addr_hi - regs->desc_status;
	context->reg_length_field = 0;
	context->reg_length_mask = regs->buflen;
	context->reg_reach = queue->buffer_size;
	context->length_reg_count = 1;
	context->length_regs = length_reg;
}

/* Whether buffer `buffer` lies in the `count` slots from `first`, all modulo the size. */
static bool
in_slots(uint32_t buffer, uint16_t first, uint32_t count)
{
	return (((buffer - first) & MASK) < count);
}

void
erx_device_genet_view(const erx_device_genet_queue_t *queue, uint64_t pool_offset, erx_dma_state_t *state)
{
	state->count = ERX_GENET_RING_SIZE;
	for (uint32_t buffer = 0; buffer < ERX_GENET_RING_SIZE; buffer++) {
		const bool device = queue->direction == ERX_DEVICE_GENET_RX ?
		    queue->installed && !in_slots(buffer, queue->software, queue->taken) :
		    in_slots(buffer, queue->hardware, queue->in_flight);

		state->regions[buffer] = (erx_dma_region_t){ .offset = pool_offset + (uint64_t)buffer * queue->stride,
		    .length = queue->stride, .kind = ERX_DMA_BUFFER, .writer = device ? ERX_DMA_DEVICE : ERX_DMA_CPU };
	}
}

/* -------------------------------------------------------------------------------------------
 * Reset and install
 */

uint32_t
erx_device_genet_stop(const erx_device_genet_registers_t *regs)
{
	(void)regs;
	/* The engine's and every ring's enable cleared in one write (FreeBSD's gen_dma_disable, if_genet.c:563-577). */
	return (0);
}

static erx_dma_step_t
register_report(uint32_t reg)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_REPORT, .target = ERX_DMA_REGISTER, .width = 4, .reg = reg,
	    .reg_high = ERX_DMA_NO_REGISTER });
}

void
erx_device_genet_idle_report(const erx_device_genet_registers_t *regs, erx_dma_step_t *step)
{
	*step = register_report(regs->dma_status);
}

bool
erx_device_genet_idle(const erx_device_genet_registers_t *regs, uint64_t status)
{
	const uint32_t idle = regs->dma_disabled | ring_bit(regs->dma_ring_disabled, ERX_GENET_RING);

	return ((status & idle) == idle);
}

bool
erx_device_genet_reset(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs, uint64_t status)
{
	if (!erx_device_genet_idle(regs, status))
		return (false);
	queue->software = 0;
	queue->hardware = 0;
	queue->in_flight = 0;
	queue->taken = 0;
	queue->reported = 0;
	queue->installed = false;
	queue->broken = false;
	return (true);
}

static erx_dma_step_t
register_value(uint32_t reg, uint32_t value)
{
	return ((erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER, .source = ERX_DMA_VALUE,
	    .width = 4, .reg = reg, .reg_high = ERX_DMA_NO_REGISTER, .value = value });
}

uint32_t
erx_device_genet_install_steps(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    uint64_t pool_addr, erx_dma_step_t *steps)
{
	/* Start, end and the pointers count 32-bit words into the descriptors (the facts record, "Layout of a DMA block"). */
	const uint32_t last_word = ERX_GENET_RING_SIZE * (regs->desc_stride / 4u) - 1u;
	const uint32_t ring_enable = ring_bit(regs->dma_ring_enable, ERX_GENET_RING);
	uint32_t count = 0;

	if (queue->installed)
		return (0);
	for (uint32_t desc = 0; desc < ERX_GENET_RING_SIZE; desc++) {
		steps[count++] = (erx_dma_step_t){ .kind = ERX_DMA_PUBLISH, .target = ERX_DMA_REGISTER,
		    .source = ERX_DMA_ADDRESS, .width = 8, .reg = regs->desc_addr_lo + desc * regs->desc_stride,
		    .reg_high = regs->desc_addr_hi + desc * regs->desc_stride,
		    .value = pool_addr + (uint64_t)desc * queue->stride, .extent = queue->buffer_size };
	}
	steps[count++] = register_value(regs->hardware_index, 0);
	steps[count++] = register_value(regs->software_index, 0);
	steps[count++] = register_value(regs->buf_size, field_put(regs->desc_count, ERX_GENET_RING_SIZE) |
	    field_put(regs->buf_length, queue->buffer_size));
	steps[count++] = register_value(regs->start[0], 0);
	steps[count++] = register_value(regs->start[1], 0);
	steps[count++] = register_value(regs->end[0], last_word);
	steps[count++] = register_value(regs->end[1], 0);
	steps[count++] = register_value(regs->hardware_ptr[0], 0);
	steps[count++] = register_value(regs->hardware_ptr[1], 0);
	steps[count++] = register_value(regs->software_ptr[0], 0);
	steps[count++] = register_value(regs->software_ptr[1], 0);
	steps[count++] = register_value(regs->ring_cfg, ring_bit(regs->ring_enable, ERX_GENET_RING));
	steps[count++] = register_value(regs->dma_ctrl, ring_enable);
	queue->installed = true;
	return (count);
}

void
erx_device_genet_start(const erx_device_genet_registers_t *regs, erx_dma_step_t *step)
{
	*step = register_value(regs->dma_ctrl, ring_bit(regs->dma_ring_enable, ERX_GENET_RING) |
	    (SEED_NO_DMA_ENABLE ? 0 : regs->dma_enable));
}

/* -------------------------------------------------------------------------------------------
 * Transmit
 */

bool
erx_device_genet_post(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    uint64_t pool_offset, const erx_dma_piece_t *pieces, uint32_t count, uint64_t tag,
    erx_dma_step_t *steps, uint32_t *step_count, bool *full)
{
	const uint32_t buffer = queue->software & MASK;
	const uint64_t base = pool_offset + (uint64_t)buffer * queue->stride;
	uint32_t length = 0, made = 0;

	*full = false;
	if (queue->direction != ERX_DEVICE_GENET_TX || queue->broken || !queue->installed || count == 0 ||
	    count > ERX_GENET_PIECES_MAX)
		return (false);
	for (uint32_t piece = 0; piece < count; piece++) {
		if (pieces[piece].length == 0 || pieces[piece].bytes == NULL ||
		    pieces[piece].length > queue->buffer_size - length)
			return (false);
		length += pieces[piece].length;
	}
	if (queue->in_flight == ERX_GENET_RING_SIZE) {
		*full = true;
		return (false);
	}
	for (uint32_t piece = 0, at = 0; piece < count; at += pieces[piece].length, piece++) {
		steps[made++] = (erx_dma_step_t){ .kind = ERX_DMA_WRITE, .target = ERX_DMA_MEMORY, .source = ERX_DMA_BYTES,
		    .offset = base + at, .length = pieces[piece].length, .bytes = pieces[piece].bytes,
		    .reg_high = ERX_DMA_NO_REGISTER };
	}
	steps[made++] = register_value(regs->desc_status + buffer * regs->desc_stride,
	    field_put(regs->buflen, length) | regs->sop | regs->eop | (SEED_NO_TX_CRC ? 0 : regs->crc));
	queue->tags[buffer] = tag;
	queue->software++;
	queue->in_flight++;
	steps[made++] = register_value(regs->software_index, field_put(regs->index, queue->software));
	*step_count = made;
	return (true);
}

void
erx_device_genet_index_report(const erx_device_genet_registers_t *regs, erx_dma_step_t *step)
{
	*step = register_report(regs->hardware_index);
}

/* How far a 16-bit index the controller advances has moved past `from`, as the INDEX field of one load reads it. */
static uint32_t
advance(const erx_device_genet_registers_t *regs, uint64_t index_register, uint16_t from)
{
	return ((uint16_t)(field_get(regs->index, index_register) - from));
}

bool
erx_device_genet_tx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    uint64_t index_register, uint32_t max, erx_device_genet_completion_t *completions, uint32_t *done)
{
	uint32_t moved;

	*done = 0;
	if (queue->direction != ERX_DEVICE_GENET_TX || queue->broken || !queue->installed)
		return (false);
	moved = advance(regs, index_register, queue->hardware);
	if (moved > queue->in_flight) {
		queue->broken = true;
		return (false);
	}
	if (moved > max)
		moved = max;
	for (uint32_t at = 0; at < moved; at++) {
		const uint32_t buffer = queue->hardware & MASK;

		completions[at] = (erx_device_genet_completion_t){ .buffer = buffer, .length = 0, .tag = queue->tags[buffer] };
		queue->hardware++;
	}
	queue->in_flight -= moved;
	*done = moved;
	return (true);
}

/* -------------------------------------------------------------------------------------------
 * Receive
 */

bool
erx_device_genet_rx_reports(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    uint64_t index_register, uint32_t max, erx_dma_step_t *steps, uint32_t *count)
{
	uint32_t fresh;

	*count = 0;
	if (queue->direction != ERX_DEVICE_GENET_RX || queue->broken || !queue->installed || queue->taken != 0)
		return (false);
	/* The register's upper half counts discarded frames (the facts record, "Layout of a DMA block"); INDEX is the low. */
	fresh = advance(regs, index_register, queue->software);
	if (fresh > ERX_GENET_RING_SIZE) {
		queue->broken = true;
		return (false);
	}
	if (fresh > max)
		fresh = max;
	queue->reported = fresh;
	for (uint32_t at = 0; at < fresh; at++)
		steps[at] = register_report(regs->desc_status + ((queue->software + at) & MASK) * regs->desc_stride);
	*count = fresh;
	return (true);
}

bool
erx_device_genet_rx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    const uint64_t *statuses, uint32_t count, erx_device_genet_completion_t *completions, uint32_t *done)
{
	/* The flags are the status bits below the length (docs/design-device-dma.md, The register ring). */
	const uint32_t flags = (UINT32_C(1) << shift_of(regs->buflen)) - 1u;
	uint32_t taken = 0;

	*done = 0;
	if (queue->direction != ERX_DEVICE_GENET_RX || queue->broken || !queue->installed || queue->taken != 0 ||
	    count != queue->reported)
		return (false);
	queue->reported = 0;
	for (; taken < count; taken++) {
		const uint32_t length = field_get(regs->buflen, statuses[taken]);

		if (length > queue->buffer_size && !SEED_NO_LENGTH_BOUND) {
			queue->broken = true;
			break;
		}
		completions[taken] = (erx_device_genet_completion_t){ .buffer = (queue->software + taken) & MASK,
		    .length = length, .tag = statuses[taken] & flags };
	}
	queue->taken = taken;
	*done = taken;
	return (true);
}

uint32_t
erx_device_genet_copy_steps(const erx_device_genet_queue_t *queue, uint64_t pool_offset,
    const erx_device_genet_completion_t *completions, uint32_t count, erx_dma_step_t *steps)
{
	uint32_t made = 0;

	for (uint32_t at = 0; at < count; at++) {
		if (completions[at].length == 0)
			continue;
		steps[made++] = (erx_dma_step_t){ .kind = ERX_DMA_COPY, .target = ERX_DMA_MEMORY,
		    .offset = pool_offset + (uint64_t)completions[at].buffer * queue->stride, .length = completions[at].length,
		    .reg_high = ERX_DMA_NO_REGISTER };
	}
	return (made);
}

uint32_t
erx_device_genet_rx_give(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    erx_dma_step_t *steps)
{
	if (queue->direction != ERX_DEVICE_GENET_RX || queue->broken || queue->taken == 0)
		return (0);
	queue->software = (uint16_t)(queue->software + queue->taken);
	queue->taken = 0;
	steps[0] = register_value(regs->software_index, field_put(regs->index, queue->software));
	return (1);
}

/* A plan of `count` steps of `call` from the round's steps, and the state after it from the queue's bookkeeping. */
static void
round_plan(const erx_device_genet_queue_t *queue, const erx_dma_request_t *request, erx_dma_call_t call, uint32_t count,
    erx_dma_round_t *round)
{
	round->call = call;
	round->count = count;
	erx_device_genet_view(queue, request->pool_offset, round->after);
}

/* The rounds of a register ring's calls, by the plan each makes; the round after the last plan ends the call. */
enum {
	IDLE_READ = 0,			/* the engine's idle bits observed */
};
enum {
	INSTALL_RESET = 0,		/* every buffer taken back */
	INSTALL_WRITE = 1,		/* each descriptor's address and the ring's registers */
};
enum {
	START_WRITE = 0,		/* the direction's engine enabled */
};
enum {
	POST_WRITE = 0,			/* the frame's descriptor and the producer index */
};
enum {
	TX_READ_INDEX = 0,		/* the consumer index observed */
	TX_TAKE_BACK = 1,		/* the descriptors it moved past taken back */
};
enum {
	RX_READ_INDEX = 0,		/* the producer index observed */
	RX_READ_STATUSES = 1,		/* each new descriptor's status observed */
	RX_TAKE_BACK = 2,		/* the frames taken back, a copy each */
	RX_HAND_BACK = 3,		/* the buffers handed back past the consumer index */
};

static void
genet_install(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    const erx_dma_request_t *request, erx_dma_round_t *round)
{
	switch (round->round) {
	case INSTALL_RESET:
		if (!erx_device_genet_reset(queue, regs, request->idle)) {
			queue->broken = true;
			erx_dma_round_end(round, ERX_EINVAL);
			return;
		}
		round_plan(queue, request, ERX_DMA_CALL_RESET, 0, round);
		return;
	case INSTALL_WRITE:
		round_plan(queue, request, ERX_DMA_CALL_INSTALL, erx_device_genet_install_steps(queue, regs,
		    request->device_base + request->pool_offset, round->steps), round);
		return;
	default:
		erx_dma_round_end(round, ERX_OK);
		return;
	}
}

/*
 * A transmit post: the pieces are the frame's bytes, which the device reads. A receive queue
 * is standing, so a post on it is ERX_EINVAL, as is a piece naming a region or bytes the
 * device writes.
 */
static void
genet_post(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs, const erx_dma_request_t *request,
    erx_dma_round_t *round)
{
	uint32_t count;
	bool full;

	if (round->round > POST_WRITE) {
		erx_dma_round_end(round, ERX_OK);
		return;
	}
	if (queue->direction != ERX_DEVICE_GENET_TX || request->count > ERX_GENET_PIECES_MAX) {
		erx_dma_round_end(round, ERX_EINVAL);
		return;
	}
	for (uint32_t piece = 0; piece < request->count; piece++) {
		if (request->pieces[piece].names_region || request->pieces[piece].device_writes) {
			erx_dma_round_end(round, ERX_EINVAL);
			return;
		}
	}
	if (!request->ready || queue->broken) {
		erx_dma_round_end(round, ERX_ECORRUPT);
		return;
	}
	if (!erx_device_genet_post(queue, regs, request->pool_offset, request->pieces, request->count, request->tag,
	    round->steps, &count, &full)) {
		erx_dma_round_end(round, full ? ERX_EWOULDBLOCK : ERX_EINVAL);
		return;
	}
	round_plan(queue, request, ERX_DMA_CALL_POST, count, round);
}

/* The consumer index observed, then the descriptors it moved past taken back, each tag answered with no bytes. */
static void
genet_tx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    const erx_dma_request_t *request, erx_dma_round_t *round)
{
	erx_device_genet_completion_t completions[ERX_DMA_ANSWERS_MAX];
	const uint32_t max = request->answers_max < ERX_DMA_ANSWERS_MAX ? request->answers_max : ERX_DMA_ANSWERS_MAX;
	uint32_t done;

	switch (round->round) {
	case TX_READ_INDEX:
		erx_device_genet_index_report(regs, &round->steps[0]);
		erx_dma_round_observe(round, 1);
		return;
	case TX_TAKE_BACK:
		if (!erx_device_genet_tx_complete(queue, regs, round->values[0], max, completions, &done)) {
			erx_dma_round_end(round, ERX_ECORRUPT);
			return;
		}
		if (done == 0) {
			erx_dma_round_end(round, ERX_OK);
			return;
		}
		for (uint32_t taken = 0; taken < done; taken++)
			round->answers[taken] = (erx_dma_answer_t){ .tag = completions[taken].tag };
		round->answer_count = done;
		round_plan(queue, request, ERX_DMA_CALL_COMPLETE, 0, round);
		return;
	default:
		erx_dma_round_end(round, ERX_OK);
		return;
	}
}

/*
 * The producer index observed, then each new descriptor's status, at most as many as keep the
 * copies within bytes_max; the frames before any length past the buffer taken back, each
 * copied out under its flags, which breaks the queue after them; then the buffers handed back
 * and the consumer index published past them, so no frame holds the ring. A frame of no bytes
 * has no copy.
 */
static void
genet_rx_complete(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    const erx_dma_request_t *request, erx_dma_round_t *round)
{
	erx_device_genet_completion_t completions[ERX_DMA_ANSWERS_MAX];
	/* buffer_size is at least 1; the effect layer's bytes_max is at least one buffer. */
	const uint64_t by_bytes = request->bytes_max / queue->buffer_size;
	uint32_t max = request->answers_max < ERX_DMA_ANSWERS_MAX ? request->answers_max : ERX_DMA_ANSWERS_MAX;
	uint32_t reports, done, count = 0;

	if (by_bytes < max)
		max = (uint32_t)by_bytes;
	switch (round->round) {
	case RX_READ_INDEX:
		erx_device_genet_index_report(regs, &round->steps[0]);
		erx_dma_round_observe(round, 1);
		return;
	case RX_READ_STATUSES:
		if (!erx_device_genet_rx_reports(queue, regs, round->values[0], max, round->steps, &reports)) {
			erx_dma_round_end(round, ERX_ECORRUPT);
			return;
		}
		if (reports == 0) {
			erx_dma_round_end(round, ERX_OK);
			return;
		}
		erx_dma_round_observe(round, reports);
		return;
	case RX_TAKE_BACK:
		if (!erx_device_genet_rx_complete(queue, regs, round->values, round->value_count, completions, &done)) {
			erx_dma_round_end(round, ERX_EINVAL);
			return;
		}
		if (done == 0) {
			erx_dma_round_end(round, ERX_ECORRUPT);
			return;
		}
		for (uint32_t taken = 0; taken < done; taken++) {
			const uint32_t copies = erx_device_genet_copy_steps(queue, request->pool_offset, &completions[taken], 1,
			    round->steps + count);

			round->answers[taken] = (erx_dma_answer_t){ .tag = completions[taken].tag,
			    .length = completions[taken].length, .copies = copies };
			count += copies;
		}
		round->answer_count = done;
		round_plan(queue, request, ERX_DMA_CALL_COMPLETE, count, round);
		return;
	case RX_HAND_BACK:
		count = erx_device_genet_rx_give(queue, regs, round->steps);
		if (count == 0) {
			erx_dma_round_end(round, ERX_OK);
			return;
		}
		round_plan(queue, request, ERX_DMA_CALL_POST, count, round);
		return;
	default:
		erx_dma_round_end(round, ERX_OK);
		return;
	}
}

void
erx_device_genet_round(erx_device_genet_queue_t *queue, const erx_device_genet_registers_t *regs,
    const erx_dma_request_t *request, erx_dma_round_t *round)
{
	switch (request->kind) {
	case ERX_DMA_REQUEST_IDLE:
		if (round->round == IDLE_READ) {
			erx_device_genet_idle_report(regs, &round->steps[0]);
			erx_dma_round_observe(round, 1);
			return;
		}
		round->value = round->values[0];
		erx_dma_round_end(round, erx_device_genet_idle(regs, round->values[0]) ? ERX_OK : ERX_EBUSY);
		return;
	case ERX_DMA_REQUEST_INSTALL:
		genet_install(queue, regs, request, round);
		return;
	case ERX_DMA_REQUEST_START:
		if (round->round > START_WRITE) {
			erx_dma_round_end(round, ERX_OK);
			return;
		}
		/* A start hands nothing over: a publish whose state is the install's. */
		erx_device_genet_start(regs, &round->steps[0]);
		round->call = ERX_DMA_CALL_POST;
		round->count = 1;
		round->keeps = true;
		return;
	case ERX_DMA_REQUEST_POST:
		genet_post(queue, regs, request, round);
		return;
	case ERX_DMA_REQUEST_COMPLETE:
		if (queue->direction == ERX_DEVICE_GENET_TX)
			genet_tx_complete(queue, regs, request, round);
		else
			genet_rx_complete(queue, regs, request, round);
		return;
	}
	erx_dma_round_end(round, ERX_EINVAL);
}
