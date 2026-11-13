/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * GENET's register ring core (otp/erts/emulator/nifs/erxos/erx_device_genet.h) against a
 * hostile controller, every plan it makes put through erx_device_dma_check. The input is a
 * script: a u16, one less than the buffers' size, cut to what the length fields hold; then
 * operations, each an opcode byte and its operands:
 *
 *   0  a transmit post of a length u16, cut to the buffer
 *   1  a transmit completion from any u32 consumer index register, as the controller may write it
 *   2  a receive completion from any u32 producer index register, then a u32 status per
 *      descriptor it covers, as the controller may write them
 *   3  reset and install both queues
 *
 * After each step the harness checks that the check accepts every plan the core made, so no
 * copy leaves its buffer, no length passes the reach its address was published with and no
 * address leaves the memory or the 40 bits; that a completion's frame is at most the buffer
 * size; that the transmit bookkeeping never holds more than the queue's size; and that a
 * broken queue refuses everything until its reset.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx_device_dma.h"
#include "erx_device_genet.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

#define FUZZ_BASE	UINT64_C(0xfff0000000)	/* near the top of the 40 bits */
#define GRANULE		64u
#define SIZE		ERX_DEVICE_GENET_SIZE

typedef struct script {
	const uint8_t	*bytes;
	size_t		left;
} script_t;

typedef struct side {
	erx_device_genet_registers_t	regs;
	erx_device_genet_queue_t	queue;
	erx_dma_state_t			state;
	uint64_t			pool_offset;
} side_t;

static const erx_device_peripheral_t *genet;
static side_t rx, tx;
static uint64_t memory_size;
static erx_dma_step_t steps[ERX_DEVICE_GENET_INSTALL_STEPS];
static erx_device_genet_completion_t completions[32];
static uint64_t statuses[32];
static uint8_t frame[ERX_DEVICE_BUFFER_MAX];

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

/* A plan the core made from the side's last state to its view now: the check accepts it, and the side keeps the view. */
static void
plan(side_t *side, erx_dma_call_t call, uint32_t count)
{
	erx_dma_length_reg_t length_reg;
	erx_dma_context_t context = { .memory_size = memory_size, .device_base = FUZZ_BASE,
	    .window_size = genet->window_size, .granule = GRANULE };
	erx_dma_state_t after;

	erx_device_genet_form(&side->queue, &side->regs, &length_reg, &context);
	erx_device_genet_view(&side->queue, side->pool_offset, &after);
	check(erx_device_dma_check(&context, &side->state,  &after,
	    &(erx_dma_plan_t){ .call = call, .count = count, .steps = steps }));
	side->state = after;
}

static void
install(side_t *side)
{
	erx_device_genet_idle_report(&side->regs, &steps[0]);
	plan(side, ERX_DMA_CALL_OBSERVE, 1);
	check(erx_device_genet_reset(&side->queue, &side->regs, side->regs.dma_disabled | side->regs.dma_ring_disabled));
	plan(side, ERX_DMA_CALL_RESET, 0);
	plan(side, ERX_DMA_CALL_INSTALL,
	    erx_device_genet_install_steps(&side->queue, &side->regs, FUZZ_BASE + side->pool_offset, steps));
}

static void
post(script_t *script)
{
	const uint32_t length = 1 + (uint32_t)take(script, 2) % tx.queue.buffer_size;
	const erx_device_genet_piece_t piece = { frame, length };
	const erx_device_genet_queue_t before = tx.queue;
	uint32_t count;
	bool full;

	if (!erx_device_genet_post(&tx.queue, &tx.regs, tx.pool_offset, &piece, 1, length, steps, &count, &full)) {
		check(memcmp(&before, &tx.queue, sizeof(before)) == 0);
		check(full == (before.in_flight == SIZE && !before.broken));
		return;
	}
	check(tx.queue.in_flight == before.in_flight + 1);
	plan(&tx, ERX_DMA_CALL_POST, count);
}

static void
tx_complete(uint64_t index_register)
{
	const bool broken = tx.queue.broken;
	const uint32_t in_flight = tx.queue.in_flight;
	uint32_t done;

	if (!erx_device_genet_tx_complete(&tx.queue, &tx.regs, index_register, 32, completions, &done)) {
		check(done == 0 && tx.queue.broken);
		return;
	}
	check(!broken && done <= 32 && done <= in_flight && tx.queue.in_flight == in_flight - done);
	if (done != 0)
		plan(&tx, ERX_DMA_CALL_COMPLETE, 0);
}

static void
rx_complete(script_t *script, uint64_t index_register)
{
	const bool broken = rx.queue.broken;
	uint32_t count, done;

	if (!erx_device_genet_rx_reports(&rx.queue, &rx.regs, index_register, 32, steps, &count)) {
		check(count == 0 && rx.queue.broken);
		return;
	}
	check(!broken && count <= 32);
	plan(&rx, ERX_DMA_CALL_OBSERVE, count);
	for (uint32_t at = 0; at < count; at++)
		statuses[at] = take(script, 4);
	check(erx_device_genet_rx_complete(&rx.queue, &rx.regs, statuses, count, completions, &done));
	check(done <= count && (done == count) != rx.queue.broken);
	for (uint32_t at = 0; at < done; at++)
		check(completions[at].length <= rx.queue.buffer_size && completions[at].tag <= UINT16_MAX);
	plan(&rx, ERX_DMA_CALL_COMPLETE, erx_device_genet_copy_steps(&rx.queue, rx.pool_offset, completions, done, steps));
	count = erx_device_genet_rx_give(&rx.queue, &rx.regs, steps);
	check((count != 0) == (done != 0 && !rx.queue.broken));
	if (count != 0)
		plan(&rx, ERX_DMA_CALL_POST, count);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	script_t script = { data, size };
	uint32_t buffer_size;

	if (genet == NULL) {
		genet = erx_device_peripheral_find("genet", sizeof("genet") - 1);
		check(genet != NULL && erx_device_genet_registers(genet, ERX_DEVICE_GENET_RX, &rx.regs) &&
		    erx_device_genet_registers(genet, ERX_DEVICE_GENET_TX, &tx.regs));
	}
	buffer_size = 1 + (uint32_t)take(&script, 2) % 4095u;
	check(erx_device_genet_init(&rx.queue, &rx.regs, buffer_size, GRANULE, FUZZ_BASE));
	tx.pool_offset = erx_device_genet_bytes(&rx.queue);
	check(erx_device_genet_init(&tx.queue, &tx.regs, buffer_size, GRANULE, FUZZ_BASE + tx.pool_offset));
	memory_size = tx.pool_offset + erx_device_genet_bytes(&tx.queue);
	erx_device_genet_view(&rx.queue, rx.pool_offset, &rx.state);
	erx_device_genet_view(&tx.queue, tx.pool_offset, &tx.state);
	install(&rx);
	install(&tx);
	while (script.left > 0) {
		switch (take(&script, 1) % 4) {
		case 0:
			post(&script);
			break;
		case 1:
			tx_complete(take(&script, 4));
			break;
		case 2:
			rx_complete(&script, take(&script, 4));
			break;
		default:
			install(&rx);
			install(&tx);
			break;
		}
	}
	return (0);
}
