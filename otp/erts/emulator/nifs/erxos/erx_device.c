/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The records and the register accesses. See erx_device.h.
 */

#include "erx_device.h"

#include <stdatomic.h>
#include <string.h>
#ifdef ERX_DEVICE_STAND_IN
#include <stdlib.h>
#endif

#include "erx/hw/device_access.h"
#include "liberx/backend/api.h"

/* The rings are virtio's little-endian layouts, written and read through their own types. */
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "erx_device writes virtio rings in the CPU's byte order, which must be little-endian"
#endif

/* The SVD profile has one address block per peripheral, and the table a window for each register. */
#define ERX_DEVICE_WINDOWS_MAX	1u

struct erx_device {
	const erx_device_peripheral_t	*peripheral;
	volatile uint8_t		*windows[ERX_DEVICE_WINDOWS_MAX];
	uint64_t			base;
	uint64_t			size;
	bool				stand_in;
	uint32_t			line_count;
	uint64_t			selectors[ERX_DEVICE_LINES_MAX];
	uint64_t			irqs[ERX_DEVICE_LINES_MAX];
	uintptr_t			register_keys[ERX_DEVICE_REGISTERS_MAX];
	uintptr_t			field_keys[ERX_DEVICE_FIELDS_MAX];
};

static erx_device_t devices[ERX_DEVICE_MAX];
static _Atomic uint32_t devices_open;

/* A window's mapping: device memory from the kernel, or the hosted stand-in's plain memory. */
static int
map_window(const erx_device_spec_t *spec, uint64_t size, volatile uint8_t **window)
{
	uint64_t mem, addr;
	int status;

#ifdef ERX_DEVICE_STAND_IN
	if (spec->stand_in) {
		*window = calloc(1, size);
		return (*window != NULL ? ERX_OK : ERX_ENOMEM);
	}
#else
	if (spec->stand_in)
		return (ERX_ENOTSUP);
#endif
	status = erx_mem_create_physical(0, 0, spec->base, size, ERX_MEM_ATTR_DEVICE, &mem);
	if (status == ERX_OK)
		status = erx_vm_reserve(0, size, 0, &addr);
	if (status == ERX_OK)
		status = erx_vm_map(ERX_CAP_SELF, addr, size, mem, 0, ERX_PROT_RW);
	if (status == ERX_OK)
		*window = (volatile uint8_t *)(uintptr_t)addr;
	return (status);
}

/* Every part of the spec the table or the record bounds, checked before anything is made. */
static bool
spec_fits(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral)
{
	return (peripheral != NULL && spec->line_count <= ERX_DEVICE_LINES_MAX &&
	    (spec->stand_in || spec->size >= peripheral->window_size));
}

static bool
same_spec(const erx_device_t *record, const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral)
{
	if (record->peripheral != peripheral || record->size != spec->size || record->line_count != spec->line_count)
		return (false);
	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (record->selectors[line] != spec->lines[line])
			return (false);
	}
	return (true);
}

/*
 * Whether an earlier open of the same window decides this one, and what it decides. A
 * stand-in has no window to share, so it is always a new device.
 */
static bool
find_open(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, uint32_t open, uint32_t *device,
    int *status)
{
	for (uint32_t index = 0; index < open && !spec->stand_in; index++) {
		if (devices[index].stand_in || devices[index].base != spec->base)
			continue;
		*device = index;
		*status = same_spec(&devices[index], spec, peripheral) ? ERX_OK : ERX_EBUSY;
		return (true);
	}
	return (false);
}

int
erx_device_open(const erx_device_spec_t *spec, const uintptr_t *register_keys, const uintptr_t *field_keys,
    uint32_t *device)
{
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(spec->peripheral, spec->peripheral_length);
	const uint32_t open = atomic_load_explicit(&devices_open, memory_order_relaxed);
	erx_device_t *record;
	int status;

	if (!spec_fits(spec, peripheral))
		return (ERX_EINVAL);
	if (find_open(spec, peripheral, open, device, &status))
		return (status);
	if (open == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	record = &devices[open];
	status = map_window(spec, spec->stand_in ? peripheral->window_size : spec->size, &record->windows[0]);
	for (uint32_t line = 0; status == ERX_OK && line < spec->line_count; line++) {
		status = erx_irq_create(0, 0, spec->stand_in ? ERX_IRQ_SOFT : ERX_IRQ_LINE, spec->lines[line],
		    &record->irqs[line]);
		record->selectors[line] = spec->lines[line];
	}
	if (status != ERX_OK)
		return (status);
	record->peripheral = peripheral;
	record->base = spec->base;
	record->size = spec->size;
	record->stand_in = spec->stand_in;
	record->line_count = spec->line_count;
	for (uint32_t index = 0; register_keys != NULL && index < peripheral->register_count; index++)
		record->register_keys[index] = register_keys[index];
	for (uint32_t index = 0; field_keys != NULL && index < peripheral->field_count; index++)
		record->field_keys[index] = field_keys[index];
	atomic_store_explicit(&devices_open, open + 1, memory_order_release);
	*device = open;
	return (ERX_OK);
}

const erx_device_t *
erx_device_get(uint64_t device)
{
	return (device < atomic_load_explicit(&devices_open, memory_order_acquire) ? &devices[device] : NULL);
}

const erx_device_peripheral_t *
erx_device_peripheral(const erx_device_t *device)
{
	return (device->peripheral);
}

const erx_device_register_t *
erx_device_register_by_key(const erx_device_t *device, uintptr_t key)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_key_find(device->register_keys, peripheral->register_count, key);

	return (found == peripheral->register_count ? NULL : &peripheral->registers[found]);
}

const erx_device_field_t *
erx_device_field_by_key(const erx_device_t *device, const erx_device_register_t *reg, uintptr_t key)
{
	const uint32_t found = erx_device_key_find(&device->field_keys[reg->first_field], reg->field_count, key);

	return (found == reg->field_count ? NULL : &device->peripheral->fields[reg->first_field + found]);
}

static uint64_t
load(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset)
{
	if (reg->width == 64)
		return (erx_device_access_load64(device->windows[reg->window], offset));
	return (erx_device_access_load32(device->windows[reg->window], offset));
}

static void
store(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	if (reg->width == 64)
		erx_device_access_store64(device->windows[reg->window], offset, value);
	else
		erx_device_access_store32(device->windows[reg->window], offset, (uint32_t)value);
}

bool
erx_device_read(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t *value)
{
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) || !erx_device_read_allowed(reg))
		return (false);
	*value = load(device, reg, offset);
	return (true);
}

bool
erx_device_write(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t value)
{
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) || !erx_device_write_allowed(reg, value))
		return (false);
	store(device, reg, offset, value);
	return (true);
}

bool
erx_device_read_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
    const erx_device_field_t *field, uint64_t *value)
{
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) ||
	    !erx_device_field_read_allowed(reg, field))
		return (false);
	*value = erx_device_field_get(field, load(device, reg, offset));
	return (true);
}

bool
erx_device_field_of(const erx_device_register_t *reg, erx_device_element_t element, const erx_device_field_t *field,
    uint64_t word, uint64_t *value)
{
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) ||
	    !erx_device_field_read_allowed(reg, field) || !erx_device_word_fits(reg, word))
		return (false);
	*value = erx_device_field_get(field, word);
	return (true);
}

bool
erx_device_write_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
    const erx_device_field_t *field, uint64_t value)
{
	const erx_device_field_plan_t plan = erx_device_field_plan(reg, field, value);
	uint64_t offset;

	if (!erx_device_element_offset(reg, element.indexed, element.index, &offset) || plan.op == ERX_DEVICE_FIELD_REFUSED)
		return (false);
	store(device, reg, offset, erx_device_field_apply(&plan, plan.op == ERX_DEVICE_FIELD_UPDATE ? load(device, reg, offset) : 0));
	return (true);
}

bool
erx_device_line_irq(const erx_device_t *device, uint64_t line, uint64_t *irq)
{
	if (line >= device->line_count)
		return (false);
	*irq = device->irqs[line];
	return (true);
}

/*
 * The queues. Each record is written whole by erx_device_queue_create and changes only under
 * the caller's serialisation. `ready` is true from an install to the next erx_device_reset_done:
 * a queue that is not ready is one the device may have forgotten, so nothing is posted on it
 * and nothing completed from it.
 */
typedef struct virtio_registers {
	const erx_device_register_t	*version;
	const erx_device_register_t	*sel;
	const erx_device_register_t	*num_max;
	const erx_device_register_t	*num;
	const erx_device_register_t	*ready;
	const erx_device_register_t	*notify;
	/* The registers that hold a device address, low word then high word: write_address's alone. */
	const erx_device_register_t	*desc[2];
	const erx_device_register_t	*driver[2];
	const erx_device_register_t	*device[2];
} virtio_registers_t;

typedef struct queue_record {
	const erx_device_t		*device;
	uint32_t			index;		/* the device's own number for the queue */
	bool				ready;
	virtio_registers_t		regs;
	erx_device_queue_layout_t	layout;
	volatile uint8_t		*rings;		/* this domain's mapping of the rings */
	uint64_t			ring_addrs[3];	/* the device addresses of desc, avail and used */
	uint8_t				*buffers;	/* this domain's mapping of the pool */
	erx_device_queue_t		core;
} queue_record_t;

static queue_record_t queues[ERX_DEVICE_QUEUES_MAX];
static uint32_t queues_open;

/* A plain register of the device's table by name, or NULL; only virtio's queue sequence names them. */
static const erx_device_register_t *
plain_register(const erx_device_t *device, const char *name)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	return (found == peripheral->register_count || peripheral->registers[found].count != 1 ? NULL :
	    &peripheral->registers[found]);
}

static bool
virtio_registers(const erx_device_t *device, virtio_registers_t *regs)
{
	static const char *const address_names[3][2] = { { "queue_desc_low", "queue_desc_high" },
	    { "queue_driver_low", "queue_driver_high" }, { "queue_device_low", "queue_device_high" } };
	const erx_device_register_t **const address_regs[3] = { regs->desc, regs->driver, regs->device };
	bool found;

	regs->version = plain_register(device, "version");
	regs->sel = plain_register(device, "queue_sel");
	regs->num_max = plain_register(device, "queue_num_max");
	regs->num = plain_register(device, "queue_num");
	regs->ready = plain_register(device, "queue_ready");
	regs->notify = plain_register(device, "queue_notify");
	found = regs->version != NULL && regs->sel != NULL && regs->num_max != NULL && regs->num != NULL &&
	    regs->ready != NULL && regs->notify != NULL;
	for (uint32_t ring = 0; ring < 3; ring++) {
		for (uint32_t word = 0; word < 2; word++) {
			address_regs[ring][word] = plain_register(device, address_names[ring][word]);
			found = found && address_regs[ring][word] != NULL && address_regs[ring][word]->holds_device_address;
		}
	}
	return (found);
}

/*
 * The one function that writes a register the SVD source marks as holding a device address,
 * from an address erx_mem_dma_addr gave for memory of a queue.
 */
static void
write_address(const erx_device_t *device, const erx_device_register_t *const words[2], uint64_t addr)
{
	store(device, words[0], words[0]->offset, addr & UINT32_MAX);
	store(device, words[1], words[1]->offset, addr >> 32);
}

/* Contiguous memory of at least `size` bytes, mapped here, and its object. */
static int
map_dma(uint64_t size, uint64_t *mem, uint8_t **mapping)
{
	const uint64_t rounded = (size + ERX_PAGE_SIZE - 1) & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	uint64_t addr;
	int status;

	status = erx_mem_create_contiguous(0, 0, rounded, 0, mem);
	if (status == ERX_OK)
		status = erx_vm_reserve(0, rounded, 0, &addr);
	if (status == ERX_OK)
		status = erx_vm_map(ERX_CAP_SELF, addr, rounded, *mem, 0, ERX_PROT_RW);
	if (status == ERX_OK)
		*mapping = (uint8_t *)(uintptr_t)addr;
	return (status);
}

/* The rings' memory and the pool's, with every device address the queue needs, from the kernel. */
static int
make_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size)
{
	const uint32_t offsets[3] = { record->layout.desc, record->layout.avail, record->layout.used };
	uint64_t ring_mem, pool_mem, pool;
	uint8_t *rings;
	int status;

	status = map_dma(record->layout.bytes, &ring_mem, &rings);
	for (uint32_t ring = 0; status == ERX_OK && ring < 3; ring++)
		status = erx_mem_dma_addr(ring_mem, offsets[ring], &record->ring_addrs[ring]);
	if (status == ERX_OK)
		status = map_dma((uint64_t)size * buffer_size, &pool_mem, &record->buffers);
	if (status == ERX_OK)
		status = erx_mem_dma_addr(pool_mem, 0, &pool);
	if (status != ERX_OK)
		return (status);
	if (!erx_device_queue_init(&record->core, size, buffer_size, pool))
		return (ERX_ERANGE);
	record->rings = rings;
	return (ERX_OK);
}

int
erx_device_queue_create(const erx_device_t *device, uint32_t index, uint32_t size, uint32_t buffer_size,
    uint32_t *queue)
{
	erx_device_queue_layout_t layout;
	queue_record_t *record;
	int status;

	if (!erx_device_queue_layout(size, &layout) || buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX ||
	    (uint64_t)size * buffer_size > ERX_MEM_CONTIGUOUS_MAX)
		return (ERX_EINVAL);
	for (uint32_t open = 0; open < queues_open; open++) {
		const queue_record_t *const other = &queues[open];

		if (other->device != device || other->index != index)
			continue;
		if (other->core.size != size || other->core.buffer_size != buffer_size)
			return (ERX_EBUSY);
		*queue = open;
		return (ERX_OK);
	}
	if (queues_open == ERX_DEVICE_QUEUES_MAX)
		return (ERX_ELIMIT);
	record = &queues[queues_open];
	memset(record, 0, sizeof(*record));
	if (!virtio_registers(device, &record->regs) ||
	    load(device, record->regs.version, record->regs.version->offset) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	record->device = device;
	record->index = index;
	record->layout = layout;
	status = make_queue_memory(record, size, buffer_size);
	if (status != ERX_OK)
		return (status);
	*queue = queues_open++;
	return (ERX_OK);
}

/*
 * The reset plan's checks for one queue: the device has let it go and can take its size.
 * They write only the selector, so a refusal changes nothing of any queue.
 */
static int
install_check(const queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->regs;

	store(device, regs->sel, regs->sel->offset, record->index);
	if (load(device, regs->ready, regs->ready->offset) != 0)
		return (ERX_EBUSY);
	if (load(device, regs->num_max, regs->num_max->offset) < record->core.size)
		return (ERX_ERANGE);
	return (ERX_OK);
}

/* The reset plan's effects for one queue, which cannot fail: forget, zero, then size, addresses and ready. */
static void
install_apply(queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->regs;

	store(device, regs->sel, regs->sel->offset, record->index);
	erx_device_queue_reset(&record->core);
	/* The device has let the queue go, so nothing else reaches the rings now. */
	memset((void *)(uintptr_t)record->rings, 0, record->layout.bytes);
	store(device, regs->num, regs->num->offset, record->core.size);
	write_address(device, regs->desc, record->ring_addrs[0]);
	write_address(device, regs->driver, record->ring_addrs[1]);
	write_address(device, regs->device, record->ring_addrs[2]);
	atomic_thread_fence(memory_order_seq_cst);
	store(device, regs->ready, regs->ready->offset, 1);
	record->ready = true;
}

/* Every queue of the device is checked before any is changed, so the plan applies whole or not at all. */
int
erx_device_reset_done(const erx_device_t *device)
{
	int status = ERX_OK;

	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			queues[open].ready = false;
	}
	for (uint32_t open = 0; status == ERX_OK && open < queues_open; open++) {
		if (queues[open].device == device)
			status = install_check(&queues[open]);
	}
	for (uint32_t open = 0; status == ERX_OK && open < queues_open; open++) {
		if (queues[open].device == device)
			install_apply(&queues[open]);
	}
	return (status);
}

static queue_record_t *
queue_of(const erx_device_t *device, uint32_t queue)
{
	return (queue < queues_open && queues[queue].device == device ? &queues[queue] : NULL);
}

/*
 * A post's plan, applied: the readable pieces into the head's buffer, the descriptors, the
 * available entry, then after a barrier the available index, and after another the doorbell.
 * Nothing here can fail, so a plan the core counts as made always reaches the device.
 */
static void
apply_post(const queue_record_t *record, const erx_device_piece_t *pieces, const erx_device_segment_t *segments,
    const erx_device_post_plan_t *plan)
{
	uint8_t *const buffer = record->buffers + (size_t)plan->head * record->core.buffer_size;
	volatile erx_virtq_desc_t *const table = (volatile erx_virtq_desc_t *)(record->rings + record->layout.desc);
	volatile erx_virtq_ring_head_t *const avail = (volatile erx_virtq_ring_head_t *)(record->rings + record->layout.avail);
	volatile uint16_t *const avail_ring = (volatile uint16_t *)(record->rings + record->layout.avail +
	    ERX_VIRTQ_RING_HEAD_SIZE);

	for (uint32_t step = 0; step < plan->count; step++) {
		const erx_device_desc_write_t *const desc = &plan->descs[step];

		if (!pieces[step].device_writes)
			memcpy(buffer + segments[step].offset, pieces[step].data, pieces[step].length);
		table[desc->index].addr = desc->addr;
		table[desc->index].len = desc->len;
		table[desc->index].flags = desc->flags;
		table[desc->index].next = desc->next;
	}
	avail_ring[plan->avail_slot] = plan->head;
	atomic_thread_fence(memory_order_release);
	avail->idx = plan->avail_idx;
	atomic_thread_fence(memory_order_seq_cst);
	store(record->device, record->regs.notify, record->regs.notify->offset, record->index);
}

int
erx_device_post(const erx_device_t *device, uint32_t queue, uint64_t tag, const erx_device_piece_t *pieces,
    uint32_t count)
{
	queue_record_t *const record = queue_of(device, queue);
	erx_device_segment_t segments[ERX_DEVICE_CHAIN_MAX];
	erx_device_post_plan_t plan;
	uint32_t offset = 0;

	if (record == NULL || count == 0 || count > ERX_DEVICE_CHAIN_MAX)
		return (ERX_EINVAL);
	for (uint32_t step = 0; step < count; step++) {
		if (pieces[step].length > record->core.buffer_size - offset)
			return (ERX_EINVAL);
		segments[step].offset = offset;
		segments[step].length = pieces[step].length;
		segments[step].device_writes = pieces[step].device_writes;
		offset += pieces[step].length;
	}
	if (!record->ready || record->core.broken)
		return (ERX_ECORRUPT);
	if (record->core.free_count < count)
		return (ERX_EWOULDBLOCK);
	if (!erx_device_queue_post(&record->core, segments, count, tag, &plan))
		return (ERX_EINVAL);
	apply_post(record, pieces, segments, &plan);
	return (ERX_OK);
}

/* A completion's ranges of its buffer, end to end into what the sink gave. */
static void
copy_out(const queue_record_t *record, const erx_device_completion_t *completion, uint8_t *bytes)
{
	const uint8_t *const buffer = record->buffers + (size_t)completion->buffer * record->core.buffer_size;
	uint32_t at = 0;

	for (uint32_t range = 0; range < completion->range_count; range++) {
		memcpy(bytes + at, buffer + completion->ranges[range].offset, completion->ranges[range].length);
		at += completion->ranges[range].length;
	}
}

/*
 * The used ring's index is loaded once, and each entry's two fields once each, from the slot
 * the core names, so the core decides on exactly what this read. The core returns the buffer
 * to the pool before its bytes are copied out, which is safe because only a post, which the
 * caller's serialisation keeps out, could take it again.
 */
int
erx_device_complete(const erx_device_t *device, uint32_t queue, erx_device_sink_t *sink, void *context,
    uint32_t *completed)
{
	queue_record_t *const record = queue_of(device, queue);
	volatile const erx_virtq_ring_head_t *used;
	volatile const erx_virtq_used_elem_t *elems;
	uint32_t fresh, done = 0;
	uint64_t copied = 0;

	if (record == NULL)
		return (ERX_EINVAL);
	if (!record->ready || record->core.broken)
		return (ERX_ECORRUPT);
	used = (volatile const erx_virtq_ring_head_t *)(record->rings + record->layout.used);
	elems = (volatile const erx_virtq_used_elem_t *)(record->rings + record->layout.used + ERX_VIRTQ_RING_HEAD_SIZE);
	if (!erx_device_queue_used(&record->core, used->idx, &fresh))
		return (ERX_ECORRUPT);
	atomic_thread_fence(memory_order_acquire);
	while (done < fresh && copied < ERX_DEVICE_COMPLETE_BYTES) {
		const uint32_t slot = erx_device_queue_used_slot(&record->core);
		const uint32_t id = elems[slot].id;
		const uint32_t length = elems[slot].len;
		erx_device_completion_t completion;

		if (!erx_device_queue_complete(&record->core, id, length, &completion))
			break;
		copy_out(record, &completion, sink(context, completion.tag, completion.length));
		copied += completion.length;
		done++;
	}
	*completed = done;
	return (done == 0 && record->core.broken ? ERX_ECORRUPT : ERX_OK);
}
