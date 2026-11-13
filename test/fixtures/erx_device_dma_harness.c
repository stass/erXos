/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's queues on the host (test/host/erx_device_queue_test.rb): a virtio-mmio device
 * whose register window is plain memory and whose DMA addresses are this process's own, so
 * the harness plays the device. Its registers react as a device's do, through the access
 * functions test/fixtures/device_model gives erx_device.c: a reset clears the status and the
 * queue's ready bit, the feature words are banked by their selectors, and the device can
 * refuse FEATURES_OK or a reset. The harness reads the rings the NIF's effects wrote, writes
 * into the buffers and the used ring, and lies, and checks what erx_device_queue_create,
 * erx_device_negotiate, erx_device_post and erx_device_complete do with it: the features
 * masked to what the split ring serves, every failure leaving the device FAILED and the
 * queue refused, the install whole and in order, a post whole or not at all, each chain in
 * its own buffer, a broken queue refused until the next negotiation, and the regions
 * erx_device_region takes from the same memory, which a post names by their entries.
 */

#include <sys/mman.h>
#include <sys/wait.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "liberx/backend/api.h"
#include "liberx/backend/core/device_check.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"
#include "otp/erts/emulator/nifs/erxos/erx_dma_arch.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define MEMORIES_MAX	16u
#define BUFFER_SIZE	ERX_DEVICE_BUFFER_MAX
#define QUEUE_SIZE	8u
/* The pages of a queue of QUEUE_SIZE buffers of BUFFER_SIZE: its rings', then its pool's. */
#define QUEUE_PAGES	(1u + (QUEUE_SIZE * BUFFER_SIZE + ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE)
/* A given device's queues have buffers of a page, smaller than BUFFER_SIZE, so a few fit its memory. */
#define SMALL_BUFFER	ERX_PAGE_SIZE
/* The pages one queue of SMALL_BUFFER takes: its rings', which fit one page at QUEUE_SIZE, and its pool's. */
#define SMALL_QUEUE_PAGES	(1u + QUEUE_SIZE * SMALL_BUFFER / ERX_PAGE_SIZE)
/* Where a given device's registers lie in its window object, as a virtio-mmio slot does in its page. */
#define GIVEN_OFFSET	0xe00u
#define GIVEN_LINE	33u

/*
 * Every memory object, as plain memory whose device address is its own. It is shared, so
 * what one record and the device leave in it outlives the process of that record, as kept
 * memory outlives a holder.
 */
typedef struct memory {
	uint8_t		*bytes;
	uint64_t	size;
} memory_t;

static memory_t memories[MEMORIES_MAX];
static uint32_t memory_count;
/* The objects the effects will map, in order: each made here, or given to a record. */
static uint64_t maps[MEMORIES_MAX];
static uint32_t maps_pushed, maps_done;
static uint32_t irqs_created;
static const erx_device_peripheral_t *virtio;
static uint8_t *window;

static void
expect_map(uint64_t mem)
{
	CHECK(maps_pushed < MEMORIES_MAX);
	maps[maps_pushed++] = mem;
}

static uint64_t
make_memory(uint64_t size)
{
	void *bytes;

	CHECK(memory_count < MEMORIES_MAX && size % ERX_PAGE_SIZE == 0);
	bytes = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
	CHECK(bytes != MAP_FAILED);
	memories[memory_count].bytes = bytes;
	memories[memory_count].size = size;
	return (memory_count++);
}

int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	(void)budget;
	(void)resource;
	/* Both backends refuse what the kernel interface refuses: anything but whole pages. */
	CHECK(erx_backend_physical_check(base, size, attr) == ERX_OK);
	CHECK(size <= ERX_PAGE_SIZE);
	*mem = make_memory(ERX_PAGE_SIZE);
	window = memories[*mem].bytes;
	expect_map(*mem);
	return (ERX_OK);
}

int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	if (mem >= memory_count)
		return (ERX_EINVAL);
	if (offset >= memories[mem].size)
		return (ERX_ERANGE);
	*addr = (uint64_t)(uintptr_t)(memories[mem].bytes + offset);
	return (ERX_OK);
}

/* Each reservation is for the next object to map, at that object's own address. */
int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	CHECK(space == ERX_CAP_SELF && addr == 0 && flags == 0 && maps_done < maps_pushed);
	CHECK(size <= memories[maps[maps_done]].size);
	*reserved = (uint64_t)(uintptr_t)memories[maps[maps_done]].bytes;
	return (ERX_OK);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	CHECK(space == ERX_CAP_SELF && maps_done < maps_pushed && mem == maps[maps_done] &&
	    addr == (uint64_t)(uintptr_t)memories[mem].bytes && size <= memories[mem].size && offset == 0 &&
	    prot == ERX_PROT_RW);
	maps_done++;
	return (ERX_OK);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	(void)budget;
	(void)resource;
	(void)kind;
	irqs_created++;
	*irq = selector;
	return (ERX_OK);
}

/* The device's side of its registers, by the generated table's names. */
static uint64_t
offset_of(const char *name)
{
	const uint32_t found = erx_device_register_named(virtio, name);

	CHECK(found < virtio->register_count);
	return (virtio->registers[found].offset);
}

static uint32_t *
reg(const char *name)
{
	return ((uint32_t *)(void *)(window + offset_of(name)));
}

static uint32_t
status_bit(const char *name)
{
	const erx_device_register_t *const status = &virtio->registers[erx_device_register_named(virtio, "status")];
	const uint32_t found = erx_device_field_named(virtio, status, name);

	CHECK(found < status->field_count);
	return ((uint32_t)virtio->fields[status->first_field + found].mask);
}

/* What the device offers and does, and what it saw. */
static struct {
	uint64_t	offered;
	bool		refuse_features;	/* FEATURES_OK does not stick */
	bool		reset_sticks;		/* the status does not read 0 after a reset */
	bool		ready_sticks;		/* a reset leaves the queue ready */
	uint32_t	resets;
	uint32_t	driver_features[2];
} model;

/*
 * The device's reaction to a write, after the word lands in the window, and the order of
 * section 3.1.1 checked at each step: the driver's features while ACKNOWLEDGE and DRIVER
 * alone are set, a queue's setup between FEATURES_OK and DRIVER_OK, and DRIVER_OK only over
 * an installed queue.
 */
static void
device_write(uint64_t offset, uint32_t value)
{
	const uint32_t introduced = status_bit("acknowledge") | status_bit("driver");
	const uint32_t features_ok = status_bit("features_ok");

	if (offset == offset_of("status") && value == 0) {
		model.resets++;
		*reg("status") = model.reset_sticks ? status_bit("device_needs_reset") : 0;
		if (!model.ready_sticks)
			*reg("queue_ready") = 0;
	} else if (offset == offset_of("status")) {
		if (model.refuse_features)
			*reg("status") = value & ~features_ok;
		if ((value & status_bit("driver_ok")) != 0)
			CHECK(*reg("queue_ready") == 1 && (value & status_bit("failed")) == 0);
	} else if (offset == offset_of("queue_num") || offset == offset_of("queue_ready") ||
	    offset == offset_of("queue_desc_low")) {
		CHECK((*reg("status") & features_ok) != 0 && (*reg("status") & status_bit("driver_ok")) == 0);
	} else if (offset == offset_of("device_features_sel")) {
		*reg("device_features") = value < 2 ? (uint32_t)(model.offered >> (32 * value)) : 0;
	} else if (offset == offset_of("driver_features")) {
		CHECK(*reg("driver_features_sel") < 2 && *reg("status") == introduced);
		model.driver_features[*reg("driver_features_sel")] = value;
	}
}

uint32_t
erx_device_access_load32(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 4 <= ERX_PAGE_SIZE);
	return (*(volatile uint32_t *)(void *)(at + offset));
}

void
erx_device_access_store32(volatile uint8_t *at, uint64_t offset, uint32_t value)
{
	CHECK(at == window && offset + 4 <= ERX_PAGE_SIZE);
	*(volatile uint32_t *)(void *)(at + offset) = value;
	device_write(offset, value);
}

/* virtio-mmio has no 64-bit register. */
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

static uint64_t
reg_address(const char *low, const char *high)
{
	return (*reg(low) | (uint64_t)*reg(high) << 32);
}

/* The device's view of the rings, through the addresses the registers hold. */
typedef struct rings {
	erx_virtq_desc_t	*desc;
	erx_virtq_ring_head_t	*avail;
	uint16_t		*avail_ring;
	erx_virtq_ring_head_t	*used;
	erx_virtq_used_elem_t	*used_ring;
} rings_t;

static rings_t
device_rings(void)
{
	const uintptr_t avail = (uintptr_t)reg_address("queue_driver_low", "queue_driver_high");
	const uintptr_t used = (uintptr_t)reg_address("queue_device_low", "queue_device_high");

	return ((rings_t){ .desc = (erx_virtq_desc_t *)(uintptr_t)reg_address("queue_desc_low", "queue_desc_high"),
	    .avail = (erx_virtq_ring_head_t *)avail, .avail_ring = (uint16_t *)(avail + ERX_VIRTQ_RING_HEAD_SIZE),
	    .used = (erx_virtq_ring_head_t *)used, .used_ring = (erx_virtq_used_elem_t *)(used + ERX_VIRTQ_RING_HEAD_SIZE) });
}

/* What the sink collected. */
static uint64_t sunk_tags[QUEUE_SIZE];
static uint32_t sunk_lengths[QUEUE_SIZE];
static uint8_t sunk_bytes[QUEUE_SIZE][BUFFER_SIZE];
static uint32_t sunk;

static uint8_t *
sink(void *context, uint64_t tag, uint32_t length)
{
	CHECK(context == &sunk && sunk < QUEUE_SIZE && length <= BUFFER_SIZE);
	sunk_tags[sunk] = tag;
	sunk_lengths[sunk] = length;
	return (sunk_bytes[sunk++]);
}

/*
 * The device serves the next available chain as virtio-blk serves a read: it checks the
 * chain's shape against what was posted, fills every writable descriptor with `fill`, and
 * returns `length`. The head it served.
 */
static uint16_t
device_serve(const rings_t *rings, uint16_t *seen, uint8_t fill, uint32_t length)
{
	const uint16_t head = rings->avail_ring[*seen % QUEUE_SIZE];
	uint16_t index = head;

	for (uint32_t step = 0; step < ERX_DEVICE_CHAIN_MAX; step++) {
		const erx_virtq_desc_t *const desc = &rings->desc[index];

		CHECK((desc->flags & ~(ERX_VIRTQ_DESC_F_NEXT | ERX_VIRTQ_DESC_F_WRITE)) == 0);
		if ((desc->flags & ERX_VIRTQ_DESC_F_WRITE) != 0)
			memset((void *)(uintptr_t)desc->addr, fill, desc->len);
		if ((desc->flags & ERX_VIRTQ_DESC_F_NEXT) == 0)
			break;
		index = desc->next;
	}
	rings->used_ring[rings->used->idx % QUEUE_SIZE] = (erx_virtq_used_elem_t){ .id = head, .len = length };
	rings->used->idx++;
	(*seen)++;
	return (head);
}

static uint32_t
open_virtio(void)
{
	const erx_device_spec_t spec = { .peripheral = "virtio_mmio", .peripheral_length = 11, .base = 0x0a000000,
	    .size = 512 };
	uint32_t device;

	virtio = erx_device_peripheral_find("virtio_mmio", 11);
	CHECK(virtio != NULL);
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_OK);
	return (device);
}

/*
 * The registers the NIF owns are these, and write/3's and write_field/4's C calls refuse
 * each of them, for every field and any value, touching nothing of the device.
 */
static void
check_owned(const erx_device_t *device)
{
	static const char *const owned[] = { "device_features_sel", "driver_features", "driver_features_sel", "queue_sel",
	    "queue_num", "queue_ready", "queue_notify", "status", "queue_desc_low", "queue_desc_high", "queue_driver_low",
	    "queue_driver_high", "queue_device_low", "queue_device_high" };
	const erx_device_element_t plain = { .indexed = false };
	uint8_t before[ERX_PAGE_SIZE];
	uint32_t count = 0;

	CHECK(virtio->window_size <= sizeof(before));
	memcpy(before, window, virtio->window_size);
	for (uint32_t index = 0; index < virtio->register_count; index++) {
		const erx_device_register_t *const reg = &virtio->registers[index];
		const uint64_t values[] = { 0, 1, reg->writable };
		bool listed = false;

		for (uint32_t at = 0; at < sizeof(owned) / sizeof(owned[0]); at++)
			listed = listed || strcmp(owned[at], reg->name) == 0;
		CHECK(reg->owned_by_nif == listed);
		if (!reg->owned_by_nif)
			continue;
		count++;
		for (uint32_t at = 0; at < sizeof(values) / sizeof(values[0]); at++)
			CHECK(!erx_device_write(device, reg, plain, values[at]));
		for (uint32_t field = 0; field < reg->field_count; field++) {
			CHECK(!erx_device_write_field(device, reg, plain, &virtio->fields[reg->first_field + field], 0));
			CHECK(!erx_device_write_field(device, reg, plain, &virtio->fields[reg->first_field + field], 1));
		}
	}
	CHECK(count == sizeof(owned) / sizeof(owned[0]));
	CHECK(memcmp(before, window, virtio->window_size) == 0 && model.resets == 0);
}

static void
check_create(const erx_device_t *device, uint32_t *queue)
{
	uint32_t again;

	*reg("version") = 1;
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, BUFFER_SIZE, queue) == ERX_ENOTSUP);
	*reg("version") = ERX_VIRTIO_MMIO_VERSION;
	CHECK(erx_device_queue_create(device, 0, 6, BUFFER_SIZE, queue) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, 0, queue) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, BUFFER_SIZE + 1, queue) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, 32, BUFFER_SIZE, queue) == ERX_EINVAL);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, BUFFER_SIZE, queue) == ERX_OK);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, BUFFER_SIZE, &again) == ERX_OK && again == *queue);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE / 2, BUFFER_SIZE, &again) == ERX_EBUSY);
	/* Nothing reaches the device before a negotiation installs the queue. */
	CHECK(*reg("queue_ready") == 0 && reg_address("queue_desc_low", "queue_desc_high") == 0);
}

static uint64_t
bit(uint32_t number)
{
	return (UINT64_C(1) << number);
}

/* A negotiation that fails after the reset leaves the device FAILED and nothing of the queue on it. */
static void
check_failed(const erx_device_t *device, uint32_t queue, int expected, bool failed)
{
	const erx_device_piece_t one = { .device_writes = true, .length = 1 };
	const uint32_t resets = model.resets;
	uint64_t accepted = 0;
	uint32_t count;

	CHECK(erx_device_negotiate(device, ~UINT64_C(0), &accepted) == expected && accepted == 0);
	CHECK(model.resets == resets + 1);
	CHECK(((*reg("status") & status_bit("failed")) != 0) == failed);
	CHECK((*reg("status") & status_bit("driver_ok")) == 0);
	CHECK(*reg("queue_num") == 0 && reg_address("queue_desc_low", "queue_desc_high") == 0);
	CHECK(erx_device_post(device, queue, 1, &one, 1) == ERX_ECORRUPT);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_ECORRUPT);
}

/*
 * Nothing is posted before a negotiation; each refusal leaves the queue off the device; then
 * the features are masked, the rings zeroed, and the size, the addresses and ready written.
 */
static rings_t
check_negotiate(const erx_device_t *device, uint32_t queue)
{
	static const uint32_t ring_bits[] = { ERX_VIRTIO_F_INDIRECT_DESC, ERX_VIRTIO_F_EVENT_IDX,
	    ERX_VIRTIO_F_RING_PACKED, ERX_VIRTIO_F_IN_ORDER,
	    ERX_VIRTIO_F_NOTIFICATION_DATA, ERX_VIRTIO_F_RING_RESET };
	const erx_device_piece_t one = { .device_writes = true, .length = 1 };
	const uint32_t running = status_bit("acknowledge") | status_bit("driver") | status_bit("features_ok") |
	    status_bit("driver_ok");
	erx_device_queue_layout_t layout;
	uint64_t accepted;
	rings_t rings;
	uint32_t count;

	CHECK(erx_device_post(device, queue, 1, &one, 1) == ERX_ECORRUPT);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_ECORRUPT);
	*reg("queue_num_max") = 256;
	model.offered = ~UINT64_C(0) & ~bit(ERX_VIRTIO_F_VERSION_1);
	check_failed(device, queue, ERX_ENOTSUP, true);
	model.offered = ~UINT64_C(0);
	model.refuse_features = true;
	check_failed(device, queue, ERX_ENOTSUP, true);
	model.refuse_features = false;
	model.reset_sticks = true;
	check_failed(device, queue, ERX_EBUSY, false);
	CHECK(*reg("status") == status_bit("device_needs_reset"));
	model.reset_sticks = false;
	*reg("queue_num_max") = QUEUE_SIZE / 2;
	check_failed(device, queue, ERX_ERANGE, true);
	*reg("queue_num_max") = 256;
	*reg("queue_ready") = 1;
	model.ready_sticks = true;
	check_failed(device, queue, ERX_EBUSY, true);
	model.ready_sticks = false;

	/* Of all 64 bits, the device type's, VERSION_1 and ACCESS_PLATFORM, and no bit of the ring or the transport. */
	const uint64_t always = bit(ERX_VIRTIO_F_VERSION_1) | bit(ERX_VIRTIO_F_ACCESS_PLATFORM);
	CHECK(erx_device_negotiate(device, ~UINT64_C(0), &accepted) == ERX_OK);
	CHECK(accepted == (ERX_VIRTIO_F_DEVICE_TYPE_MASK | always));
	for (uint32_t at = 0; at < sizeof(ring_bits) / sizeof(ring_bits[0]); at++)
		CHECK((accepted & bit(ring_bits[at])) == 0);
	CHECK(model.driver_features[0] == (uint32_t)accepted && model.driver_features[1] == (uint32_t)(accepted >> 32));
	CHECK(*reg("status") == running);
	/* VERSION_1 and an offered ACCESS_PLATFORM always, and only what the driver wants of the rest. */
	CHECK(erx_device_negotiate(device, bit(3), &accepted) == ERX_OK && accepted == (bit(3) | always));
	CHECK(erx_device_negotiate(device, 0, &accepted) == ERX_OK && accepted == always);
	CHECK(model.driver_features[0] == 0 && model.driver_features[1] == 3);
	model.offered = bit(ERX_VIRTIO_F_VERSION_1) | bit(3);
	CHECK(erx_device_negotiate(device, ~UINT64_C(0), &accepted) == ERX_OK && accepted == model.offered);

	CHECK(*reg("queue_sel") == 0 && *reg("queue_num") == QUEUE_SIZE && *reg("queue_ready") == 1);
	CHECK(erx_device_queue_layout(QUEUE_SIZE, erx_dma_granule(), &layout));
	rings = device_rings();
	CHECK((uint8_t *)rings.avail == (uint8_t *)rings.desc + layout.avail);
	CHECK((uint8_t *)rings.used == (uint8_t *)rings.desc + layout.used);
	for (uint32_t at = 0; at < layout.bytes; at++)
		CHECK(((uint8_t *)rings.desc)[at] == 0);
	return (rings);
}

/* A negotiation with the device type's bits the harness wants; its result checked above. */
static int
negotiate(const erx_device_t *device)
{
	uint64_t accepted;

	return (erx_device_negotiate(device, 0, &accepted));
}

/* A virtio-blk read: the header goes out, the device writes 512 bytes and a status. */
static void
check_read(const erx_device_t *device, uint32_t queue, const rings_t *rings, uint16_t *seen)
{
	static const uint8_t header[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 7 };
	const erx_device_piece_t read[] = { { .device_writes = false, .data = header, .length = sizeof(header) },
	    { .device_writes = true, .length = 512 }, { .device_writes = true, .length = 1 } };
	uint32_t count;
	uint16_t head;

	*reg("queue_notify") = 0xff;
	CHECK(erx_device_post(device, queue, 77, read, 3) == ERX_OK);
	CHECK(*reg("queue_notify") == 0 && rings->avail->idx == 1);
	head = rings->avail_ring[0];
	CHECK(memcmp((const void *)(uintptr_t)rings->desc[head].addr, header, sizeof(header)) == 0);
	CHECK(rings->desc[head].len == sizeof(header) && rings->desc[head].flags == ERX_VIRTQ_DESC_F_NEXT);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 0);
	CHECK(device_serve(rings, seen, 0x5a, 513) == head);
	sunk = 0;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 1);
	CHECK(sunk == 1 && sunk_tags[0] == 77 && sunk_lengths[0] == 513);
	for (uint32_t at = 0; at < 513; at++)
		CHECK(sunk_bytes[0][at] == 0x5a);
	/* A device writing the buffer after its completion changes nothing returned. */
	memset((void *)(uintptr_t)rings->desc[rings->desc[head].next].addr, 0x11, 512);
	CHECK(sunk_bytes[0][0] == 0x5a);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 0);
}

/* Refused posts write nothing; chains in flight each have their own buffer; a full queue says so. */
static void
check_posts(const erx_device_t *device, uint32_t queue, const rings_t *rings)
{
	static const uint8_t bytes[4] = { 1, 2, 3, 4 };
	const erx_device_piece_t too_long[] = { { .device_writes = false, .data = bytes, .length = 4 },
	    { .device_writes = true, .length = BUFFER_SIZE - 3 } };
	const erx_device_piece_t backwards[] = { { .device_writes = true, .length = 4 },
	    { .device_writes = false, .data = bytes, .length = 4 } };
	const erx_device_piece_t empty[] = { { .device_writes = true, .length = 0 } };
	const erx_device_piece_t three[] = { { .device_writes = false, .data = bytes, .length = 4 },
	    { .device_writes = true, .length = 4 }, { .device_writes = true, .length = 1 } };
	const uint16_t idx = rings->avail->idx;
	uint64_t first;

	*reg("queue_notify") = 0xff;
	CHECK(erx_device_post(device, queue, 1, too_long, 2) == ERX_EINVAL);
	CHECK(erx_device_post(device, queue, 1, backwards, 2) == ERX_EINVAL);
	CHECK(erx_device_post(device, queue, 1, empty, 1) == ERX_EINVAL);
	CHECK(erx_device_post(device, queue, 1, three, 0) == ERX_EINVAL);
	CHECK(erx_device_post(device, queue + 1, 1, three, 3) == ERX_EINVAL);
	CHECK(rings->avail->idx == idx && *reg("queue_notify") == 0xff);
	CHECK(erx_device_post(device, queue, 2, three, 3) == ERX_OK);
	first = rings->desc[rings->avail_ring[idx % QUEUE_SIZE]].addr;
	CHECK(erx_device_post(device, queue, 3, three, 3) == ERX_OK);
	CHECK(rings->desc[rings->avail_ring[(idx + 1) % QUEUE_SIZE]].addr != first);
	CHECK((rings->desc[rings->avail_ring[(idx + 1) % QUEUE_SIZE]].addr - first) % BUFFER_SIZE == 0);
	*reg("queue_notify") = 0xff;
	CHECK(erx_device_post(device, queue, 4, three, 3) == ERX_EWOULDBLOCK);
	CHECK(rings->avail->idx == (uint16_t)(idx + 2) && *reg("queue_notify") == 0xff);
}

/* A lying device breaks the queue until a negotiation, whose reset gives every buffer back. */
static void
check_broken(const erx_device_t *device, uint32_t queue, rings_t *rings, uint16_t *seen)
{
	const erx_device_piece_t whole[] = { { .device_writes = true, .length = BUFFER_SIZE } };
	uint32_t count;

	rings->used_ring[rings->used->idx % QUEUE_SIZE] = (erx_virtq_used_elem_t){ .id = 99, .len = 1 };
	rings->used->idx++;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_ECORRUPT);
	CHECK(erx_device_post(device, queue, 5, whole, 1) == ERX_ECORRUPT);
	model.ready_sticks = true;
	CHECK(negotiate(device) == ERX_EBUSY);
	CHECK(erx_device_post(device, queue, 5, whole, 1) == ERX_ECORRUPT);
	model.ready_sticks = false;
	CHECK(negotiate(device) == ERX_OK);
	*rings = device_rings();
	*seen = 0;

	/* Two whole buffers: one call copies up to its bound and leaves the rest for the next. */
	CHECK(erx_device_post(device, queue, 6, whole, 1) == ERX_OK);
	CHECK(erx_device_post(device, queue, 7, whole, 1) == ERX_OK);
	device_serve(rings, seen, 0x21, BUFFER_SIZE);
	device_serve(rings, seen, 0x22, BUFFER_SIZE);
	sunk = 0;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 1 && sunk_tags[0] == 6);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 1 && sunk_tags[1] == 7);
	CHECK(sunk_bytes[1][BUFFER_SIZE - 1] == 0x22);

	/*
	 * A completion before a malformed one is still returned, and the next call reports the
	 * break; a used index beyond the chains in flight breaks the queue at once.
	 */
	CHECK(erx_device_post(device, queue, 8, whole, 1) == ERX_OK);
	CHECK(erx_device_post(device, queue, 9, whole, 1) == ERX_OK);
	device_serve(rings, seen, 0x23, 3);
	rings->used_ring[rings->used->idx % QUEUE_SIZE] = (erx_virtq_used_elem_t){ .id = 0, .len = BUFFER_SIZE + 1 };
	rings->used->idx++;
	sunk = 0;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 1 && sunk_lengths[0] == 3);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_ECORRUPT);
	CHECK(negotiate(device) == ERX_OK);
	*rings = device_rings();
	CHECK(erx_device_post(device, queue, 10, whole, 1) == ERX_OK);
	rings->used->idx = 2;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_ECORRUPT);
}

/* A device the harness offers: version 2, queues up to 256 and VERSION_1 with one type bit. */
static void
device_offers(void)
{
	*reg("version") = ERX_VIRTIO_MMIO_VERSION;
	*reg("queue_num_max") = 256;
	model.offered = bit(ERX_VIRTIO_F_VERSION_1) | bit(3);
}

/* A given virtio-mmio device: its registers at GIVEN_OFFSET in `window_object`, one line and `memory`. */
static erx_device_spec_t
given_spec(uint64_t window_object, uint64_t memory)
{
	return ((erx_device_spec_t){ .peripheral = "virtio_mmio", .peripheral_length = 11, .form = ERX_DEVICE_FORM_GIVEN,
	    .window = window_object, .base = GIVEN_OFFSET, .size = 512, .line_count = 1, .lines = { GIVEN_LINE },
	    .memory = memory, .memory_size = memories[memory].size });
}

/* Opens a given device, which maps its window object and then its memory, and nothing else. */
static const erx_device_t *
open_given(const erx_device_spec_t *spec)
{
	const uint32_t created = irqs_created;
	uint32_t device;
	uint64_t irq;

	expect_map(spec->window);
	expect_map(spec->memory);
	CHECK(erx_device_open(spec, NULL, NULL, &device) == ERX_OK);
	CHECK(maps_done == maps_pushed && irqs_created == created);
	window = memories[spec->window].bytes + GIVEN_OFFSET;
	CHECK(erx_device_line_irq(erx_device_get(device), 0, &irq) && irq == spec->lines[0]);
	return (erx_device_get(device));
}

/* Posts one chain of a whole buffer the device writes, tagged `tag`. */
static int
post_one(const erx_device_t *device, uint32_t queue, uint64_t tag)
{
	const erx_device_piece_t whole[] = { { .device_writes = true, .length = SMALL_BUFFER } };

	return (erx_device_post(device, queue, tag, whole, 1));
}

/*
 * A given device: what open refuses, the same spec again, and the queues carved from its one
 * memory, rings then pool, each at the next page, the same queue again carving nothing and a
 * queue past the memory's end refused.
 */
static void
check_given(void)
{
	/* Room for one queue and a smaller one: a second of the first's size starts inside it and ends past it. */
	const uint64_t memory = make_memory((2 * SMALL_QUEUE_PAGES - 1) * ERX_PAGE_SIZE);
	const uint64_t window_object = make_memory(ERX_PAGE_SIZE);
	const erx_device_spec_t spec = given_spec(window_object, memory);
	const uint8_t *const base = memories[memory].bytes;
	erx_device_queue_layout_t layout;
	erx_device_spec_t other = spec;
	const erx_device_t *device;
	uint32_t index, first, again, second;
	rings_t rings;

	other.memory_size = ERX_PAGE_SIZE + 1;
	CHECK(erx_device_open(&other, NULL, NULL, &index) == ERX_EINVAL);
	other = spec;
	other.form = ERX_DEVICE_FORM_PHYSICAL;
	CHECK(erx_device_open(&other, NULL, NULL, &index) == ERX_EINVAL);
	CHECK(maps_pushed == 0);
	device = open_given(&spec);
	CHECK(erx_device_open(&spec, NULL, NULL, &index) == ERX_OK && erx_device_get(index) == device);
	other = spec;
	other.memory_size = ERX_PAGE_SIZE;
	CHECK(erx_device_open(&other, NULL, NULL, &index) == ERX_EBUSY);
	other = spec;
	other.base = 0;
	CHECK(erx_device_open(&other, NULL, NULL, &index) == ERX_EBUSY);
	other = spec;
	other.window = make_memory(ERX_PAGE_SIZE);
	CHECK(erx_device_open(&other, NULL, NULL, &index) == ERX_EBUSY);
	CHECK(maps_done == maps_pushed);

	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &first) == ERX_OK);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &again) == ERX_OK && again == first);
	CHECK(erx_device_queue_create(device, 1, QUEUE_SIZE, SMALL_BUFFER, &second) == ERX_ERANGE);
	CHECK(erx_device_queue_create(device, 1, QUEUE_SIZE / 2, SMALL_BUFFER, &second) == ERX_OK);
	CHECK(maps_done == maps_pushed);

	/* The install leaves the second queue's registers last: its rings follow the first queue's pages, as the refusal took none. */
	CHECK(negotiate(device) == ERX_OK);
	CHECK(erx_device_queue_layout(QUEUE_SIZE / 2, erx_dma_granule(), &layout));
	rings = device_rings();
	CHECK((const uint8_t *)rings.desc == base + SMALL_QUEUE_PAGES * ERX_PAGE_SIZE);
	CHECK((const uint8_t *)rings.avail == (const uint8_t *)rings.desc + layout.avail);
	CHECK((const uint8_t *)rings.used == (const uint8_t *)rings.desc + layout.used);
	/* The first queue's chain lies in its pool, after its rings' page and before the second queue. */
	CHECK(erx_device_queue_layout(QUEUE_SIZE, erx_dma_granule(), &layout));
	CHECK(post_one(device, first, 1) == ERX_OK);
	const erx_virtq_desc_t *const table = (const erx_virtq_desc_t *)(const void *)base;
	const uint16_t head = ((const uint16_t *)(const void *)(base + layout.avail + ERX_VIRTQ_RING_HEAD_SIZE))[0];
	CHECK(table[head].addr >= (uint64_t)(uintptr_t)(base + ERX_PAGE_SIZE));
	CHECK(table[head].addr + SMALL_BUFFER <= (uint64_t)(uintptr_t)(base + SMALL_QUEUE_PAGES * ERX_PAGE_SIZE));
}

/*
 * A driver's restart within one record: its successor opens the same spec, finds its queue
 * with every buffer still posted, and has them all back from its negotiation.
 */
static void
check_driver_restart(void)
{
	const erx_device_spec_t spec = given_spec(make_memory(ERX_PAGE_SIZE), make_memory(SMALL_QUEUE_PAGES * ERX_PAGE_SIZE));
	const erx_device_t *device = open_given(&spec);
	uint32_t queue, again, index;

	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &queue) == ERX_OK);
	CHECK(negotiate(device) == ERX_OK);
	for (uint32_t tag = 0; tag < QUEUE_SIZE; tag++)
		CHECK(post_one(device, queue, tag) == ERX_OK);
	CHECK(post_one(device, queue, QUEUE_SIZE) == ERX_EWOULDBLOCK);

	CHECK(erx_device_open(&spec, NULL, NULL, &index) == ERX_OK && erx_device_get(index) == device);
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &again) == ERX_OK && again == queue);
	CHECK(negotiate(device) == ERX_OK);
	for (uint32_t tag = 0; tag < QUEUE_SIZE; tag++)
		CHECK(post_one(device, queue, tag) == ERX_OK);
}

/* The region entry the post wrote at `offset` of the buffer of the chain at avail slot `slot`, whose rings are at `rings`. */
static erx_virtio_gpu_mem_entry_t
posted_entry(const uint8_t *rings, uint32_t slot, uint32_t offset)
{
	erx_device_queue_layout_t layout;
	erx_virtio_gpu_mem_entry_t entry;

	CHECK(erx_device_queue_layout(QUEUE_SIZE, erx_dma_granule(), &layout));
	const erx_virtq_desc_t *const table = (const erx_virtq_desc_t *)(const void *)rings;
	const uint16_t head = ((const uint16_t *)(const void *)(rings + layout.avail + ERX_VIRTQ_RING_HEAD_SIZE))[slot];
	memcpy(&entry, (const uint8_t *)(uintptr_t)table[head].addr + offset, sizeof(entry));
	return (entry);
}

/*
 * A given device's regions: pages of the memory its queues are carved from, at the first page
 * nothing earlier took, so a queue made after a region lies past it; the same region again
 * and a different size refused; one past the memory's end taking nothing; a post naming a
 * region writing its device address and length in the record's entry layout; and a region of
 * another device, a region named as bytes the device writes, and a region on a device that is
 * not coherent each refused.
 */
static void
check_regions(void)
{
	const uint64_t memory = make_memory((2 * SMALL_QUEUE_PAGES + 2) * ERX_PAGE_SIZE);
	erx_device_spec_t spec = given_spec(make_memory(ERX_PAGE_SIZE), memory);
	const uint8_t *const base = memories[memory].bytes;
	const uint8_t header[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
	const erx_device_t *device, *other;
	erx_device_spec_t other_spec;
	uint32_t first, second, region, again, foreign;
	erx_virtio_gpu_mem_entry_t entry;
	uint8_t *region_base;
	uint64_t region_bytes;
	rings_t rings;

	spec.coherent = true;
	device = open_given(&spec);
	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &first) == ERX_OK);
	CHECK(erx_device_region(device, 0, 0, &region) == ERX_EINVAL);
	CHECK(erx_device_region(device, 0, ERX_PAGE_SIZE + 1, &region) == ERX_OK);
	CHECK(erx_device_region(device, 0, ERX_PAGE_SIZE + 1, &again) == ERX_OK && again == region);
	CHECK(erx_device_region(device, 0, ERX_PAGE_SIZE, &again) == ERX_EBUSY);
	CHECK(erx_device_region(device, 1, memories[memory].size, &again) == ERX_ERANGE);
	CHECK(erx_device_region_memory(region, &region_base, &region_bytes));
	CHECK(region_base == base + SMALL_QUEUE_PAGES * ERX_PAGE_SIZE && region_bytes == 2 * ERX_PAGE_SIZE);
	CHECK(!erx_device_region_memory(region + 1, &region_base, &region_bytes));
	/* The refusal took nothing: the second queue starts right after the region, and fits only so. */
	CHECK(erx_device_queue_create(device, 1, QUEUE_SIZE, SMALL_BUFFER, &second) == ERX_OK);
	CHECK(negotiate(device) == ERX_OK);
	rings = device_rings();
	CHECK((const uint8_t *)rings.desc == base + (SMALL_QUEUE_PAGES + 2) * ERX_PAGE_SIZE);

	const erx_device_piece_t named[] = { { .data = header, .length = sizeof(header) },
	    { .names_region = true, .region = region }, { .device_writes = true, .length = 24 } };
	/* The first queue's pool holds an earlier request's bytes: the post zeroes what the device writes. */
	memset((uint8_t *)memories[memory].bytes + ERX_PAGE_SIZE, 0xa5, QUEUE_SIZE * SMALL_BUFFER);
	CHECK(erx_device_post(device, first, 7, named, 3) == ERX_OK);
	entry = posted_entry(base, 0, sizeof(header));
	CHECK(entry.addr == (uint64_t)(uintptr_t)(base + SMALL_QUEUE_PAGES * ERX_PAGE_SIZE));
	CHECK(entry.length == 2 * ERX_PAGE_SIZE && entry.padding == 0);
	CHECK(posted_entry(base, 0, sizeof(header) + sizeof(entry)).addr == 0);
	CHECK(posted_entry(base, 0, sizeof(header) + 2 * sizeof(entry) - 8).addr == 0);

	other_spec = given_spec(make_memory(ERX_PAGE_SIZE), make_memory(ERX_PAGE_SIZE));
	other_spec.coherent = true;
	other_spec.lines[0] = GIVEN_LINE + 1;
	other = open_given(&other_spec);
	CHECK(erx_device_region(other, 0, ERX_PAGE_SIZE, &foreign) == ERX_OK && foreign != region);
	const erx_device_piece_t stolen[] = { { .names_region = true, .region = foreign } };
	CHECK(erx_device_post(device, first, 8, stolen, 1) == ERX_EINVAL);
	const erx_device_piece_t unmade[] = { { .names_region = true, .region = foreign + 1 } };
	CHECK(erx_device_post(device, first, 8, unmade, 1) == ERX_EINVAL);
	const erx_device_piece_t written[] = { { .names_region = true, .device_writes = true, .region = region } };
	CHECK(erx_device_post(device, first, 8, written, 1) == ERX_EINVAL);

	/* A device that is not coherent has no region, and the refusal takes none of its memory. */
	erx_device_spec_t plain_spec = given_spec(make_memory(ERX_PAGE_SIZE), make_memory(SMALL_QUEUE_PAGES * ERX_PAGE_SIZE));

	plain_spec.lines[0] = GIVEN_LINE + 2;
	const erx_device_t *const plain = open_given(&plain_spec);
	device_offers();
	CHECK(erx_device_region(plain, 0, ERX_PAGE_SIZE, &again) == ERX_ENOTSUP);
	CHECK(erx_device_queue_create(plain, 0, QUEUE_SIZE, SMALL_BUFFER, &again) == ERX_OK);
	CHECK(erx_device_region(plain, 1, ERX_PAGE_SIZE, &again) == ERX_ENOTSUP);
}

/* A holder's device, whose memory and window outlive each record over them. */
static erx_device_spec_t kept;

/*
 * A holder's former record, in a process of its own: it posts three chains, the device serves
 * two, and the record ends with the device still running, which then writes a used index far
 * past anything posted. All of it stays in the kept memory and the window.
 */
static void
former_record(void)
{
	const erx_device_t *device = open_given(&kept);
	uint16_t seen = 0;
	uint32_t queue;
	rings_t rings;

	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &queue) == ERX_OK);
	CHECK(negotiate(device) == ERX_OK);
	rings = device_rings();
	for (uint64_t tag = 1; tag <= 3; tag++)
		CHECK(post_one(device, queue, tag) == ERX_OK);
	device_serve(&rings, &seen, 0x31, 16);
	device_serve(&rings, &seen, 0x32, 16);
	rings.used->idx += 5;
}

/*
 * The holder's next record over the same memory, in a fresh process: its queue is carved
 * again, and after its negotiation one chain posted and served completes alone, with its own
 * tag and bytes, whatever the former record and the device left behind.
 */
static void
next_record(void)
{
	const erx_device_t *device = open_given(&kept);
	uint16_t seen = 0;
	uint32_t queue, count;
	rings_t rings;

	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, SMALL_BUFFER, &queue) == ERX_OK);
	CHECK(negotiate(device) == ERX_OK);
	rings = device_rings();
	CHECK((const uint8_t *)rings.desc == memories[kept.memory].bytes);
	CHECK(post_one(device, queue, 41) == ERX_OK);
	device_serve(&rings, &seen, 0x41, 7);
	sunk = 0;
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 1);
	CHECK(sunk == 1 && sunk_tags[0] == 41 && sunk_lengths[0] == 7 && sunk_bytes[0][6] == 0x41);
	CHECK(erx_device_complete(device, queue, sink, &sunk, &count) == ERX_OK && count == 0);
}

/*
 * A given device's queue whole: the registers the NIF owns, the create, the negotiation, a
 * read, refused and full posts and a lying device. Its memory starts full of garbage, so the
 * install is seen to write the rings whole.
 */
static void
check_queue(void)
{
	const uint64_t memory = make_memory(QUEUE_PAGES * ERX_PAGE_SIZE);
	const erx_device_spec_t spec = given_spec(make_memory(ERX_PAGE_SIZE), memory);
	const erx_device_t *device;
	uint32_t queue;
	uint16_t seen = 0;
	rings_t rings;

	memset(memories[memory].bytes, 0xa5, memories[memory].size);
	device = open_given(&spec);
	check_owned(device);
	check_create(device, &queue);
	rings = check_negotiate(device, queue);
	check_read(device, queue, &rings, &seen);
	check_posts(device, queue, &rings);
	check_broken(device, queue, &rings, &seen);
}

/*
 * The physical form, the system domain's UARTs', whose window and lines the effects make,
 * has no queue: every device that does DMA is given its memory, so a queue of a physical
 * device is refused, and nothing is made or mapped for it.
 */
static void
check_physical(void)
{
	const erx_device_t *const device = erx_device_get(open_virtio());
	const uint32_t made = memory_count;
	uint32_t queue;

	CHECK(device != NULL && maps_done == maps_pushed);
	device_offers();
	CHECK(erx_device_queue_create(device, 0, QUEUE_SIZE, BUFFER_SIZE, &queue) == ERX_ENOTSUP);
	CHECK(erx_device_region(device, 0, ERX_PAGE_SIZE, &queue) == ERX_ENOTSUP);
	CHECK(memory_count == made && maps_done == maps_pushed);
}

typedef void scenario_t(void);

/*
 * Each scenario runs in a process of its own, so each starts with no record, as a domain's
 * runtime does, and shares only the memory made before it. False when it failed.
 */
static bool
run(const char *name, scenario_t *scenario)
{
	pid_t child;
	int status;

	fflush(stdout);
	child = fork();
	CHECK(child >= 0);
	if (child == 0) {
		scenario();
		printf("%s ok\n", name);
		exit(0);
	}
	CHECK(waitpid(child, &status, 0) == child);
	return (WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int
main(void)
{
	bool passed = true;

	virtio = erx_device_peripheral_find("virtio_mmio", 11);
	CHECK(virtio != NULL);
	passed &= run("physical", check_physical);
	passed &= run("queue", check_queue);
	passed &= run("given", check_given);
	passed &= run("driver restart", check_driver_restart);
	passed &= run("regions", check_regions);
	kept = given_spec(make_memory(ERX_PAGE_SIZE), make_memory(SMALL_QUEUE_PAGES * ERX_PAGE_SIZE));
	passed &= run("former record", former_record);
	passed &= run("next record", next_record);
	if (!passed)
		return (1);
	printf("erx_device_dma done\n");
	return (0);
}
