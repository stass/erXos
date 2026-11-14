/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's register ring on the host (test/host/erx_device_queue_test.rb): a given GENET
 * whose register window is plain memory, played by this harness through the access functions
 * test/fixtures/device_model gives erx_device.c, and whose memory object has device addresses
 * the harness translates, below the form's 40 bits unless a case asks for higher ones.
 *
 * The controller's two DMA engines stop only some reads of DMA status after the stop is
 * written, the transmit engine later than the receive one, and every write to a direction's
 * descriptors or ring registers is checked to come while both engines are stopped
 * (docs/design-device-dma.md, Verification, "GENET's stop"), and each engine's start to come
 * after both rings are installed, receive first. The cases drive erx_device_queue_create,
 * erx_device_negotiate, erx_device_post and erx_device_complete end to end: the geometry the
 * form takes, ebusy until both directions are idle, a transmit post's bytes as the controller
 * reads them, received frames with their flags as tags and the consumer index advanced past
 * each, a frame of no bytes, a full ring, a hostile index that breaks the queue until the next
 * negotiation, and a pool past 40 bits refused.
 */

#include <sys/mman.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/backend/api.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_genet.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define MEMORIES_MAX	8u
#define WINDOW_BYTES	65536u
#define BUFFER		2048u
#define SIZE		ERX_GENET_RING_SIZE
/* Both pools of a device, each 256 buffers of BUFFER. */
#define DEVICE_MEMORY	(2u * SIZE * BUFFER)
/* Each memory object's device addresses: its own 256 MiB slot, from 1 << 28 or from 1 << 40. */
#define SLOT_SHIFT	28u
#define HIGH_BASE	(UINT64_C(1) << 40)
#define CRC_ERROR	0x2u		/* receive status bit 1 (docs/design-device-dma.md, The register ring) */

static uint8_t *memories[MEMORIES_MAX];
static uint64_t memory_sizes[MEMORIES_MAX];
static uint32_t memory_count;
static bool high_addresses;		/* erx_mem_dma_addr answers past 40 bits */

static uint64_t
make_memory(uint64_t size)
{
	void *bytes;

	CHECK(memory_count < MEMORIES_MAX && size % ERX_PAGE_SIZE == 0);
	bytes = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
	CHECK(bytes != MAP_FAILED);
	memories[memory_count] = bytes;
	memory_sizes[memory_count] = size;
	return (memory_count++);
}

int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	(void)budget;
	(void)resource;
	(void)base;
	(void)size;
	(void)attr;
	(void)mem;
	CHECK(false);
	return (ERX_ENOTSUP);
}

int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	if (mem >= memory_count)
		return (ERX_EINVAL);
	if (offset >= memory_sizes[mem])
		return (ERX_ERANGE);
	*addr = (high_addresses ? HIGH_BASE : 0) + ((mem + 1) << SLOT_SHIFT) + offset;
	return (ERX_OK);
}

/* The objects an open maps, in order, each whole at its own mapping. */
static uint64_t maps[2];
static uint32_t maps_pushed, maps_done;

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	CHECK(space == ERX_CAP_SELF && addr == 0 && flags == 0 && maps_done < maps_pushed &&
	    size <= memory_sizes[maps[maps_done]]);
	*reserved = (uint64_t)(uintptr_t)memories[maps[maps_done]];
	return (ERX_OK);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	CHECK(space == ERX_CAP_SELF && maps_done < maps_pushed && mem == maps[maps_done] && addr == (uint64_t)(uintptr_t)memories[mem] &&
	    size <= memory_sizes[mem] && offset == 0 && prot == ERX_PROT_RW);
	maps_done++;
	return (ERX_OK);
}

/* Every map here succeeds, so no reservation is ever given back. */
int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	(void)space;
	(void)addr;
	(void)size;
	CHECK(!"a map was refused");
	return (ERX_EINVAL);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	(void)budget;
	(void)resource;
	(void)kind;
	(void)selector;
	(void)irq;
	CHECK(false);
	return (ERX_ENOTSUP);
}

/* -------------------------------------------------------------------------------------------
 * The controller
 */

static const erx_device_peripheral_t *genet;
static uint8_t *window;

typedef struct engine {
	erx_device_genet_registers_t	regs;
	uint32_t	stop_reads;	/* DMA status reads a stop takes to show */
	uint32_t	reads;		/* since the stop was written */
	bool		stopped;
	bool		installed;	/* ring configuration written since the stop */
	bool		started;
} engine_t;

static engine_t engines[2];	/* by erx_device_genet_direction_t */
static uint32_t starts;		/* engines started, in order */

static uint32_t *
reg(uint32_t offset)
{
	return ((uint32_t *)(void *)(window + offset));
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

/* Whether a write at `offset` reaches the direction's descriptors or ring, DMA control aside. */
static bool
ring_register(const erx_device_genet_registers_t *regs, uint64_t offset)
{
	if (offset >= regs->desc_status && offset < regs->desc_status + (uint64_t)SIZE * regs->desc_stride)
		return (true);
	for (uint32_t at = 0; at < ERX_DEVICE_GENET_OWNED; at++) {
		if (regs->owned[at] == offset && offset != regs->dma_ctrl)
			return (true);
	}
	return (false);
}

static void
device_write(uint64_t offset, uint32_t value)
{
	for (uint32_t side = 0; side < 2; side++) {
		engine_t *const e = &engines[side];

		/* Between its stop and its start, a direction's ring is written only while both engines are stopped. */
		if (!e->started && ring_register(&e->regs, offset))
			CHECK(engines[0].stopped && engines[1].stopped);
		if (offset == e->regs.ring_cfg)
			e->installed = true;
		if (offset != e->regs.dma_ctrl)
			continue;
		if ((value & e->regs.dma_enable) == 0) {
			if (e->started) {
				e->reads = 0;
				e->installed = false;
			}
			e->started = false;
			continue;
		}
		/* A start: both rings installed, and receive's engine first. */
		CHECK(engines[0].installed && engines[1].installed && starts == side);
		e->stopped = false;
		e->started = true;
		starts++;
	}
}

/* GENET has no 8- or 16-bit register. */
uint8_t
erx_device_access_load8(volatile uint8_t *at, uint64_t offset)
{
	(void)at;
	(void)offset;
	CHECK(false);
	return (0);
}

void
erx_device_access_store8(volatile uint8_t *at, uint64_t offset, uint8_t value)
{
	(void)at;
	(void)offset;
	(void)value;
	CHECK(false);
}

uint16_t
erx_device_access_load16(volatile uint8_t *at, uint64_t offset)
{
	(void)at;
	(void)offset;
	CHECK(false);
	return (0);
}

void
erx_device_access_store16(volatile uint8_t *at, uint64_t offset, uint16_t value)
{
	(void)at;
	(void)offset;
	(void)value;
	CHECK(false);
}

uint32_t
erx_device_access_load32(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES);
	for (uint32_t side = 0; side < 2; side++) {
		engine_t *const e = &engines[side];

		if (offset != e->regs.dma_status)
			continue;
		if (!e->started && ++e->reads >= e->stop_reads)
			e->stopped = true;
		*reg(e->regs.dma_status) = e->stopped ? e->regs.dma_disabled | e->regs.dma_ring_disabled : 0;
	}
	return (*(volatile uint32_t *)(void *)(at + offset));
}

void
erx_device_access_store32(volatile uint8_t *at, uint64_t offset, uint32_t value)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES);
	*(volatile uint32_t *)(void *)(at + offset) = value;
	device_write(offset, value);
}

/* GENET has no 64-bit register. */
uint64_t
erx_device_access_load64(volatile uint8_t *at, uint64_t offset)
{
	(void)at;
	(void)offset;
	CHECK(false);
	return (0);
}

void
erx_device_access_store64(volatile uint8_t *at, uint64_t offset, uint64_t value)
{
	(void)at;
	(void)offset;
	(void)value;
	CHECK(false);
}

/* The bytes at a device address the descriptor holds, through the memory object's slot. */
static uint8_t *
descriptor_bytes(const engine_t *e, uint32_t desc)
{
	const uint64_t addr = *reg(e->regs.desc_addr_lo + desc * e->regs.desc_stride) |
	    (uint64_t)*reg(e->regs.desc_addr_hi + desc * e->regs.desc_stride) << 32;
	const uint64_t slot = (addr >> SLOT_SHIFT) - 1, offset = addr & ((UINT64_C(1) << SLOT_SHIFT) - 1);

	CHECK(slot < memory_count && offset + BUFFER <= memory_sizes[slot]);
	return (memories[slot] + offset);
}

/* The transmit engine sends every descriptor up to the producer index; each frame must be `expected`. */
static uint32_t
transmit(const uint8_t *expected, uint32_t length)
{
	engine_t *const e = &engines[ERX_DEVICE_GENET_TX];
	uint16_t cons = (uint16_t)field(e->regs.index, *reg(e->regs.hardware_index));
	const uint16_t prod = (uint16_t)field(e->regs.index, *reg(e->regs.software_index));
	uint32_t sent = 0;

	for (; e->started && cons != prod; cons++, sent++) {
		const uint32_t status = *reg(e->regs.desc_status + (cons % SIZE) * e->regs.desc_stride);

		CHECK((status & e->regs.sop) && (status & e->regs.eop) && (status & e->regs.crc));
		CHECK(field(e->regs.buflen, status) == length);
		CHECK(memcmp(descriptor_bytes(e, cons % SIZE), expected, length) == 0);
	}
	*reg(e->regs.hardware_index) = place(e->regs.index, cons);
	return (sent);
}

/* The receive engine fills the next descriptor with a frame and its status, then advances the producer index. */
static void
receive(const uint8_t *bytes, uint32_t length, uint32_t flags)
{
	engine_t *const e = &engines[ERX_DEVICE_GENET_RX];
	const uint16_t prod = (uint16_t)field(e->regs.index, *reg(e->regs.hardware_index));

	CHECK(e->started);
	memcpy(descriptor_bytes(e, prod % SIZE), bytes, length);
	*reg(e->regs.desc_status + (prod % SIZE) * e->regs.desc_stride) = place(e->regs.buflen, length) | flags;
	*reg(e->regs.hardware_index) = place(e->regs.index, (uint16_t)(prod + 1));
}

/* -------------------------------------------------------------------------------------------
 * The driver's side
 */

static uint64_t sunk_tags[ERX_DEVICE_COMPLETE_ENTRIES];
static uint32_t sunk_lengths[ERX_DEVICE_COMPLETE_ENTRIES];
static uint8_t sunk_bytes[ERX_DEVICE_COMPLETE_ENTRIES][BUFFER];
static uint32_t sunk;

static uint8_t *
sink(void *context, uint64_t tag, uint32_t length)
{
	CHECK(context == &sunk && sunk < ERX_DEVICE_COMPLETE_ENTRIES && length <= BUFFER);
	sunk_tags[sunk] = tag;
	sunk_lengths[sunk] = length;
	return (sunk_bytes[sunk++]);
}

static int
complete(const erx_device_t *device, uint32_t queue, uint32_t *done)
{
	sunk = 0;
	return (erx_device_complete(device, queue, sink, &sunk, done));
}

/* A given GENET at offset 0 of its window object, with `memory`. */
static const erx_device_t *
open_genet(uint64_t memory)
{
	const uint64_t window_object = make_memory(WINDOW_BYTES);
	const erx_device_spec_t spec = { .peripheral = "genet", .peripheral_length = 5, .form = ERX_DEVICE_FORM_GIVEN,
	    .window = window_object, .base = 0, .size = WINDOW_BYTES, .memory = memory,
	    .memory_size = memory_sizes[memory] };
	uint32_t device;

	maps[0] = window_object;
	maps[1] = memory;
	maps_pushed = 2;
	maps_done = 0;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_OK && maps_done == 2);
	window = memories[window_object];
	return (erx_device_get(device));
}

/* Negotiates until both engines show the stop: ebusy while the transmit engine has not, then ok. */
static void
negotiate(const erx_device_t *device)
{
	uint64_t accepted = 1;
	uint32_t busy = 0;
	int status;

	starts = 0;
	while ((status = erx_device_negotiate(device, UINT64_MAX, &accepted)) == ERX_EBUSY)
		CHECK(++busy < engines[ERX_DEVICE_GENET_TX].stop_reads);
	CHECK(status == ERX_OK && accepted == 0 && busy == engines[ERX_DEVICE_GENET_TX].stop_reads - 1);
	CHECK(engines[0].started && engines[1].started && starts == 2);
}

static void
check_register_ring(void)
{
	const uint64_t memory = make_memory(DEVICE_MEMORY);
	const erx_device_t *const device = open_genet(memory);
	const engine_t *const rx = &engines[ERX_DEVICE_GENET_RX];
	const engine_t *const tx = &engines[ERX_DEVICE_GENET_TX];
	uint8_t header[14], payload[100], frame[sizeof(header) + sizeof(payload)];
	const erx_device_piece_t pieces[] = { { .data = header, .length = sizeof(header) },
	    { .data = payload, .length = sizeof(payload) } };
	const erx_device_piece_t written[] = { { .device_writes = true, .length = 64 } };
	uint32_t rq, tq, again, done;

	for (uint32_t at = 0; at < sizeof(frame); at++)
		frame[at] = (uint8_t)(at * 7 + 1);
	memcpy(header, frame, sizeof(header));
	memcpy(payload, frame + sizeof(header), sizeof(payload));

	/* The form's geometry: queue 0 receives, 1 transmits, each 256 buffers. */
	CHECK(erx_device_queue_create(device, 2, SIZE, BUFFER, &rq) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, SIZE / 2, BUFFER, &rq) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, SIZE, 0, &rq) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, SIZE, BUFFER, &rq) == ERX_OK);
	CHECK(erx_device_negotiate(device, 0, &(uint64_t){ 0 }) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 1, SIZE, 4096, &tq) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 1, SIZE, BUFFER, &tq) == ERX_OK);
	CHECK(erx_device_queue_create(device, 1, SIZE, BUFFER, &again) == ERX_OK && again == tq);
	CHECK(erx_device_queue_create(device, 1, SIZE, BUFFER / 2, &again) == ERX_EBUSY);
	CHECK(erx_device_post(device, tq, 1, pieces, 2) == ERX_ECORRUPT);
	CHECK(complete(device, rq, &done) == ERX_ECORRUPT);

	/* The install: every descriptor's address at its buffer, the ring's size, both engines. */
	negotiate(device);
	for (uint32_t desc = 0; desc < SIZE; desc++) {
		CHECK(descriptor_bytes(rx, desc) == memories[memory] + (uint64_t)desc * BUFFER);
		CHECK(descriptor_bytes(tx, desc) == memories[memory] + (uint64_t)(SIZE + desc) * BUFFER);
	}
	CHECK(field(rx->regs.buf_length, *reg(rx->regs.buf_size)) == BUFFER);
	CHECK(field(rx->regs.desc_count, *reg(rx->regs.buf_size)) == SIZE);

	/* Transmit: the bytes laid end to end, completed with the tag and no bytes. */
	CHECK(erx_device_post(device, rq, 1, pieces, 2) == ERX_EINVAL);
	CHECK(erx_device_post(device, tq, 1, written, 1) == ERX_EINVAL);
	CHECK(erx_device_post(device, tq, 77, pieces, 2) == ERX_OK);
	CHECK(complete(device, tq, &done) == ERX_OK && done == 0);
	CHECK(transmit(frame, sizeof(frame)) == 1);
	CHECK(complete(device, tq, &done) == ERX_OK && done == 1 && sunk_tags[0] == 77 && sunk_lengths[0] == 0);

	/* A full ring refuses the next post, and 256 completions come back 32 a call. */
	for (uint32_t post = 0; post < SIZE; post++)
		CHECK(erx_device_post(device, tq, post, pieces, 2) == ERX_OK);
	CHECK(erx_device_post(device, tq, SIZE, pieces, 2) == ERX_EWOULDBLOCK);
	CHECK(transmit(frame, sizeof(frame)) == SIZE);
	for (uint32_t call = 0; call < SIZE / ERX_DEVICE_COMPLETE_ENTRIES; call++) {
		CHECK(complete(device, tq, &done) == ERX_OK && done == ERX_DEVICE_COMPLETE_ENTRIES);
		CHECK(sunk_tags[0] == call * ERX_DEVICE_COMPLETE_ENTRIES);
	}

	/* Receive: a good frame, one with a CRC error and one of no bytes, each with its flags. */
	receive(frame, sizeof(frame), rx->regs.sop | rx->regs.eop);
	receive(frame, 60, rx->regs.sop | rx->regs.eop | CRC_ERROR);
	receive(frame, 0, rx->regs.sop);
	CHECK(complete(device, rq, &done) == ERX_OK && done == 3);
	CHECK(sunk_lengths[0] == sizeof(frame) && memcmp(sunk_bytes[0], frame, sizeof(frame)) == 0);
	CHECK(sunk_tags[0] == (rx->regs.sop | rx->regs.eop));
	CHECK(sunk_lengths[1] == 60 && memcmp(sunk_bytes[1], frame, 60) == 0);
	CHECK(sunk_tags[1] == (rx->regs.sop | rx->regs.eop | CRC_ERROR));
	CHECK(sunk_lengths[2] == 0 && sunk_tags[2] == rx->regs.sop);
	CHECK(field(rx->regs.index, *reg(rx->regs.software_index)) == 3);
	CHECK(complete(device, rq, &done) == ERX_OK && done == 0);

	/* A producer index more than the ring ahead breaks the queue until the next negotiation. */
	*reg(rx->regs.hardware_index) = place(rx->regs.index, 3 + SIZE + 1);
	CHECK(complete(device, rq, &done) == ERX_ECORRUPT);
	CHECK(complete(device, rq, &done) == ERX_ECORRUPT);
	negotiate(device);
	CHECK(field(rx->regs.index, *reg(rx->regs.hardware_index)) == 0);
	CHECK(complete(device, rq, &done) == ERX_OK && done == 0);
	receive(frame, 60, rx->regs.sop | rx->regs.eop);
	CHECK(complete(device, rq, &done) == ERX_OK && done == 1 && memcmp(sunk_bytes[0], frame, 60) == 0);
}

/* A pool whose device addresses pass the form's 40 bits is refused, taking nothing. */
static void
check_width(void)
{
	const erx_device_t *const device = open_genet(make_memory(DEVICE_MEMORY));
	uint32_t queue;

	high_addresses = true;
	CHECK(erx_device_queue_create(device, 0, SIZE, BUFFER, &queue) == ERX_ERANGE);
	high_addresses = false;
	CHECK(erx_device_queue_create(device, 0, SIZE, BUFFER, &queue) == ERX_OK);
}

int
main(void)
{
	genet = erx_device_peripheral_find("genet", 5);
	CHECK(genet != NULL);
	for (uint32_t side = 0; side < 2; side++) {
		CHECK(erx_device_genet_registers(genet, (erx_device_genet_direction_t)side, &engines[side].regs));
		engines[side].stop_reads = side == ERX_DEVICE_GENET_RX ? 1 : 3;
		engines[side].started = true;
	}
	check_register_ring();
	printf("register ring ok\n");
	check_width();
	printf("erx_device_genet done\n");
	return (0);
}
