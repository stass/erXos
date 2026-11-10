/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The records and the register accesses. See erx_device.h.
 */

#include "erx_device.h"

#include <stdatomic.h>
#ifdef ERX_DEVICE_STAND_IN
#include <stdlib.h>
#endif

#include "erx/hw/device_access.h"
#include "erx/hw/device_owned.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/mem.h"

/* The rings are virtio's little-endian layouts, written and read through their own types. */
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "erx_device writes virtio rings in the CPU's byte order, which must be little-endian"
#endif

/* The SVD profile has one address block per peripheral, and the table a window for each register. */
#define ERX_DEVICE_WINDOWS_MAX	1u

struct erx_device {
	const erx_device_peripheral_t	*peripheral;
	volatile uint8_t		*windows[ERX_DEVICE_WINDOWS_MAX];
	erx_device_form_t		form;
	uint64_t			window;		/* a given device's window object */
	uint64_t			base;
	uint64_t			size;
	erx_device_pages_t		pages;
	uint32_t			line_count;
	uint64_t			lines[ERX_DEVICE_LINES_MAX];	/* as the spec named them */
	uint64_t			irqs[ERX_DEVICE_LINES_MAX];
	uint64_t			memory;		/* a given device's memory object */
	uint64_t			memory_size;	/* its bytes, 0 for none */
	uint8_t				*dma;		/* this domain's mapping of it */
	uintptr_t			register_keys[ERX_DEVICE_REGISTERS_MAX];
	uintptr_t			field_keys[ERX_DEVICE_FIELDS_MAX];
};

static erx_device_t devices[ERX_DEVICE_MAX];
static _Atomic uint32_t devices_open;

/* `size` bytes of the object from `offset`, mapped read and write where the kernel reserves room. */
static int
map_object(uint64_t mem, uint64_t offset, uint64_t size, uint64_t *addr)
{
	int status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr);

	if (status == ERX_OK)
		status = erx_vm_map(ERX_CAP_SELF, *addr, size, mem, offset, ERX_PROT_RW);
	return (status);
}

/* A hosted stand-in's window, `size` bytes of plain memory; no other build has one. */
static int
stand_in_window(uint64_t size, volatile uint8_t **window)
{
#ifdef ERX_DEVICE_STAND_IN
	*window = calloc(1, size);
	return (*window != NULL ? ERX_OK : ERX_ENOMEM);
#else
	(void)size;
	(void)window;
	return (ERX_ENOTSUP);
#endif
}

/*
 * A window's mapping: the pages that hold it, with the window at its offset inside them. A
 * physical device's pages are an object made here from their addresses; a given device's
 * are the pages of its window object at their offsets in it.
 */
static int
map_window(const erx_device_spec_t *spec, const erx_device_pages_t *pages, uint64_t size, volatile uint8_t **window)
{
	uint64_t mem = spec->window, offset = pages->base, addr;
	int status = ERX_OK;

	if (spec->form == ERX_DEVICE_FORM_STAND_IN)
		return (stand_in_window(size, window));
	if (spec->form == ERX_DEVICE_FORM_PHYSICAL) {
		status = erx_mem_create_physical(0, 0, pages->base, pages->size, ERX_MEM_ATTR_DEVICE, &mem);
		offset = 0;
	}
	if (status == ERX_OK)
		status = map_object(mem, offset, pages->size, &addr);
	if (status == ERX_OK)
		*window = (volatile uint8_t *)(uintptr_t)(addr + pages->offset);
	return (status);
}

/* The lines' IRQ objects: a given device's as it was given them, any other's made from their selectors. */
static int
take_lines(const erx_device_spec_t *spec, uint64_t *irqs)
{
	const uint32_t kind = spec->form == ERX_DEVICE_FORM_STAND_IN ? ERX_IRQ_SOFT : ERX_IRQ_LINE;
	int status = ERX_OK;

	for (uint32_t line = 0; status == ERX_OK && line < spec->line_count; line++) {
		if (spec->form == ERX_DEVICE_FORM_GIVEN)
			irqs[line] = spec->lines[line];
		else
			status = erx_irq_create(0, 0, kind, spec->lines[line], &irqs[line]);
	}
	return (status);
}

/* A given device's memory, mapped here whole, or nothing for a device with none. */
static int
map_memory(const erx_device_spec_t *spec, uint8_t **dma)
{
	uint64_t addr;
	int status;

	*dma = NULL;
	if (spec->memory_size == 0)
		return (ERX_OK);
	status = map_object(spec->memory, 0, spec->memory_size, &addr);
	if (status == ERX_OK)
		*dma = (uint8_t *)(uintptr_t)addr;
	return (status);
}

/*
 * Every part of the spec the table or the record bounds, checked before anything is made,
 * and the pages a window's mapping covers. A stand-in has none. Memory is a given device's
 * alone, and whole pages.
 */
static bool
spec_fits(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, erx_device_pages_t *pages)
{
	*pages = (erx_device_pages_t){ 0 };
	if (peripheral == NULL || spec->line_count > ERX_DEVICE_LINES_MAX ||
	    (spec->form != ERX_DEVICE_FORM_GIVEN && spec->memory_size != 0) || (spec->memory_size & (ERX_PAGE_SIZE - 1)) != 0)
		return (false);
	return (spec->form == ERX_DEVICE_FORM_STAND_IN ||
	    (spec->size >= peripheral->window_size && erx_device_base_aligned(peripheral, spec->base) &&
	    erx_device_window_pages(spec->base, spec->size, pages)));
}

/* Whether a record's window and the spec's are in one space: physical memory, or one window object. */
static bool
same_space(const erx_device_t *record, const erx_device_spec_t *spec)
{
	return (record->form == spec->form && record->window == spec->window);
}

static bool
same_spec(const erx_device_t *record, const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral)
{
	if (record->peripheral != peripheral || record->size != spec->size || record->line_count != spec->line_count ||
	    record->memory != spec->memory || record->memory_size != spec->memory_size)
		return (false);
	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (record->lines[line] != spec->lines[line])
			return (false);
	}
	return (true);
}

/*
 * Whether an earlier open decides this one, and what it decides. The same window is that
 * device again, or refused if anything else differs. A window whose pages another window's
 * mapping holds is refused: one device page has one mapping, its record's. So is memory
 * another record holds, since each device's queues are carved from its own. A stand-in has no
 * window to share, so it is always a new device.
 */
static bool
find_open(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, const erx_device_pages_t *pages,
    uint32_t open, uint32_t *device, int *status)
{
	for (uint32_t index = 0; index < open && spec->form != ERX_DEVICE_FORM_STAND_IN; index++) {
		const erx_device_t *const record = &devices[index];

		if (record->form == ERX_DEVICE_FORM_STAND_IN)
			continue;
		if (same_space(record, spec) && record->base == spec->base) {
			*device = index;
			*status = same_spec(record, spec, peripheral) ? ERX_OK : ERX_EBUSY;
			return (true);
		}
		if ((same_space(record, spec) && erx_device_pages_overlap(&record->pages, pages)) ||
		    (spec->memory_size != 0 && record->memory_size != 0 && record->memory == spec->memory)) {
			*status = ERX_EBUSY;
			return (true);
		}
	}
	return (false);
}

int
erx_device_open(const erx_device_spec_t *spec, const uintptr_t *register_keys, const uintptr_t *field_keys,
    uint32_t *device)
{
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(spec->peripheral, spec->peripheral_length);
	const uint32_t open = atomic_load_explicit(&devices_open, memory_order_relaxed);
	erx_device_pages_t pages;
	erx_device_t *record;
	int status;

	if (!spec_fits(spec, peripheral, &pages))
		return (ERX_EINVAL);
	if (find_open(spec, peripheral, &pages, open, device, &status))
		return (status);
	if (open == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	record = &devices[open];
	status = map_window(spec, &pages, peripheral->window_size, &record->windows[0]);
	if (status == ERX_OK)
		status = take_lines(spec, record->irqs);
	if (status == ERX_OK)
		status = map_memory(spec, &record->dma);
	if (status != ERX_OK)
		return (status);
	record->peripheral = peripheral;
	record->form = spec->form;
	record->window = spec->window;
	record->base = spec->base;
	record->size = spec->size;
	record->pages = pages;
	record->line_count = spec->line_count;
	for (uint32_t line = 0; line < spec->line_count; line++)
		record->lines[line] = spec->lines[line];
	record->memory = spec->memory;
	record->memory_size = spec->memory_size;
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
 * The queues and the device's initialisation. Each queue record is written whole by
 * erx_device_queue_create and changes only under the caller's serialisation. `ready` is true
 * from the install at the end of a negotiation to the start of the next: a queue that is not
 * ready is one the device may have forgotten, so nothing is posted on it and nothing
 * completed from it.
 */
typedef struct virtio_registers {
	/* What the NIF reads and the driver may read too. */
	const erx_device_register_t	*version;
	const erx_device_register_t	*device_features;
	const erx_device_register_t	*num_max;
	/* The registers the NIF owns (erx/hw/device_owned.h), which only this file writes. */
	const erx_device_register_t	*status;
	const erx_device_register_t	*device_features_sel;
	const erx_device_register_t	*driver_features;
	const erx_device_register_t	*driver_features_sel;
	const erx_device_register_t	*sel;
	const erx_device_register_t	*num;
	const erx_device_register_t	*ready;
	const erx_device_register_t	*notify;
	/* The rings' device addresses, low word then high word: write_address's alone. */
	const erx_device_register_t	*desc[2];
	const erx_device_register_t	*driver[2];
	const erx_device_register_t	*device[2];
	/* The status register's bits, from its fields in the table. */
	uint64_t			acknowledge;
	uint64_t			driver_bit;
	uint64_t			features_ok;
	uint64_t			driver_ok;
	uint64_t			failed;
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
/* The bytes of each given device's memory its queues have taken, from the start, by the device's index. */
static uint64_t memory_taken[ERX_DEVICE_MAX];

/* A plain register of the device's table by name, or NULL; only virtio's queue sequence names them. */
static const erx_device_register_t *
plain_register(const erx_device_t *device, const char *name)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	return (found == peripheral->register_count || peripheral->registers[found].count != 1 ? NULL :
	    &peripheral->registers[found]);
}

/* A plain register's one access, at its own offset. */
static uint64_t
get(const erx_device_t *device, const erx_device_register_t *reg)
{
	return (load(device, reg, reg->offset));
}

static void
put(const erx_device_t *device, const erx_device_register_t *reg, uint64_t value)
{
	store(device, reg, reg->offset, value);
}

/* A field's mask in the status register, by its table name, or 0 for none. */
static uint64_t
status_bit(const erx_device_peripheral_t *virtio, const erx_device_register_t *status, const char *name)
{
	const uint32_t found = erx_device_field_named(virtio, status, name);

	return (found == status->field_count ? 0 : virtio->fields[status->first_field + found].mask);
}

/*
 * The registers of a virtio-mmio device: those the NIF only reads by name, and those it owns
 * by their generated index in the table, which is virtio_mmio's because the device's
 * peripheral is. False for any other peripheral.
 */
static bool
virtio_registers(const erx_device_t *device, virtio_registers_t *regs)
{
	const erx_device_peripheral_t *const virtio = erx_device_peripheral_find("virtio_mmio", sizeof("virtio_mmio") - 1);
	const erx_device_register_t *owned;

	if (virtio == NULL || device->peripheral != virtio)
		return (false);
	owned = virtio->registers;
	regs->version = plain_register(device, "version");
	regs->device_features = plain_register(device, "device_features");
	regs->num_max = plain_register(device, "queue_num_max");
	regs->status = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS];
	regs->device_features_sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DEVICE_FEATURES_SEL];
	regs->driver_features = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DRIVER_FEATURES];
	regs->driver_features_sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DRIVER_FEATURES_SEL];
	regs->sel = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_SEL];
	regs->num = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_NUM];
	regs->ready = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_READY];
	regs->notify = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_NOTIFY];
	regs->desc[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DESC_LOW];
	regs->desc[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DESC_HIGH];
	regs->driver[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DRIVER_LOW];
	regs->driver[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DRIVER_HIGH];
	regs->device[0] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DEVICE_LOW];
	regs->device[1] = &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_DEVICE_HIGH];
	regs->acknowledge = status_bit(virtio, regs->status, "acknowledge");
	regs->driver_bit = status_bit(virtio, regs->status, "driver");
	regs->features_ok = status_bit(virtio, regs->status, "features_ok");
	regs->driver_ok = status_bit(virtio, regs->status, "driver_ok");
	regs->failed = status_bit(virtio, regs->status, "failed");
	return (regs->version != NULL && regs->device_features != NULL && regs->num_max != NULL &&
	    regs->acknowledge != 0 && regs->driver_bit != 0 && regs->features_ok != 0 && regs->driver_ok != 0 &&
	    regs->failed != 0);
}

/* The one function that writes a ring's device address, one erx_mem_dma_addr gave for memory of a queue. */
static void
write_address(const erx_device_t *device, const erx_device_register_t *const words[2], uint64_t addr)
{
	put(device, words[0], addr & UINT32_MAX);
	put(device, words[1], addr >> 32);
}

/* Contiguous memory of at least `size` bytes, made here and mapped, and its object. */
static int
map_dma(uint64_t size, uint64_t *mem, uint8_t **mapping)
{
	uint64_t rounded, addr;
	int status;

	if (!erx_device_page_round(size, &rounded))
		return (ERX_EINVAL);
	status = erx_mem_create_contiguous(0, 0, rounded, 0, mem);
	if (status == ERX_OK)
		status = map_object(*mem, 0, rounded, &addr);
	if (status == ERX_OK)
		*mapping = (uint8_t *)(uintptr_t)addr;
	return (status);
}

/*
 * A physical device's queue: its rings' memory and its pool's, each made here, which only the
 * root may, with every device address the queue needs. The system domain's devices that do
 * DMA open in the physical form and take their queues this way (TODO.md, "one DMA form").
 */
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

/*
 * A given device's queue, in the next pages of the device's one memory object: its rings, then
 * its pool, each device address from the object and an offset in it. Nothing is read from
 * the memory, which a former record and the device may have written: the install writes the
 * rings whole. ERX_ERANGE, taking nothing, for a queue the memory has no room for; the pages
 * are taken only once everything else has succeeded.
 */
static int
carve_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size)
{
	const erx_device_t *const device = record->device;
	const uint32_t offsets[3] = { record->layout.desc, record->layout.avail, record->layout.used };
	uint64_t *const taken = &memory_taken[device - devices];
	erx_device_carve_t carve;
	uint64_t pool;
	int status = ERX_OK;

	if (!erx_device_carve(*taken, device->memory_size, record->layout.bytes, (uint64_t)size * buffer_size, &carve))
		return (ERX_ERANGE);
	for (uint32_t ring = 0; status == ERX_OK && ring < 3; ring++)
		status = erx_mem_dma_addr(device->memory, carve.rings + offsets[ring], &record->ring_addrs[ring]);
	if (status == ERX_OK)
		status = erx_mem_dma_addr(device->memory, carve.pool, &pool);
	if (status != ERX_OK)
		return (status);
	if (!erx_device_queue_init(&record->core, size, buffer_size, pool))
		return (ERX_ERANGE);
	record->rings = device->dma + carve.rings;
	record->buffers = device->dma + carve.pool;
	*taken = carve.end;
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
	bzero(record, sizeof(*record));
	if (!virtio_registers(device, &record->regs) ||
	    get(device, record->regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	record->device = device;
	record->index = index;
	record->layout = layout;
	if (device->form == ERX_DEVICE_FORM_GIVEN)
		status = carve_queue_memory(record, size, buffer_size);
	else
		status = make_queue_memory(record, size, buffer_size);
	if (status != ERX_OK)
		return (status);
	*queue = queues_open++;
	return (ERX_OK);
}

/*
 * The install's checks for one queue: the device has let it go, as a reset makes it, and can
 * take its size. They write only the selector, so a refusal changes nothing of any queue.
 */
static int
install_check(const queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->regs;

	put(device, regs->sel, record->index);
	if (get(device, regs->ready) != 0)
		return (ERX_EBUSY);
	if (get(device, regs->num_max) < record->core.size)
		return (ERX_ERANGE);
	return (ERX_OK);
}

/*
 * The install's effects for one queue, which cannot fail: forget, zero, then size, addresses and
 * ready. The rings are zeroed whole, so no index a former driver, a former record or the device
 * left in them is ever read.
 */
static void
install_apply(queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->regs;

	put(device, regs->sel, record->index);
	erx_device_queue_reset(&record->core);
	/* The device has let the queue go, so nothing else reaches the rings now. */
	bzero((void *)(uintptr_t)record->rings, record->layout.bytes);
	put(device, regs->num, record->core.size);
	write_address(device, regs->desc, record->ring_addrs[0]);
	write_address(device, regs->driver, record->ring_addrs[1]);
	write_address(device, regs->device, record->ring_addrs[2]);
	atomic_thread_fence(memory_order_seq_cst);
	put(device, regs->ready, 1);
	record->ready = true;
}

/* Every queue of the device is checked before any is changed, so the install applies whole or not at all. */
static int
install_queues(const erx_device_t *device)
{
	int status = ERX_OK;

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

/* The 64 feature bits the device offers, low word then high. */
static uint64_t
offered_features(const erx_device_t *device, const virtio_registers_t *regs)
{
	uint64_t words[2];

	for (uint32_t word = 0; word < 2; word++) {
		put(device, regs->device_features_sel, word);
		words[word] = get(device, regs->device_features) & UINT32_MAX;
	}
	return (words[0] | words[1] << 32);
}

static void
accept_features(const erx_device_t *device, const virtio_registers_t *regs, uint64_t accepted)
{
	for (uint32_t word = 0; word < 2; word++) {
		put(device, regs->driver_features_sel, word);
		put(device, regs->driver_features, (accepted >> (32 * word)) & UINT32_MAX);
	}
}

/*
 * Virtio's initialisation, section 3.1.1, whole: the reset, ACKNOWLEDGE and DRIVER, the
 * features, FEATURES_OK read back, every queue of the device installed, and DRIVER_OK. Every
 * queue stops being ready before the reset, so nothing is posted while the device may still
 * hold an old descriptor, and is ready again only after this reset. A step that fails sets
 * FAILED, so the device stays unusable until the next negotiation resets it.
 */
int
erx_device_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted)
{
	virtio_registers_t regs;
	uint64_t device_status, taken;
	int result = ERX_OK;

	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			queues[open].ready = false;
	}
	if (!virtio_registers(device, &regs) || get(device, regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	put(device, regs.status, 0);
	if (get(device, regs.status) != 0)
		return (ERX_EBUSY);
	device_status = regs.acknowledge;
	put(device, regs.status, device_status);
	device_status |= regs.driver_bit;
	put(device, regs.status, device_status);
	if (!erx_device_queue_features(wanted, offered_features(device, &regs), &taken))
		result = ERX_ENOTSUP;
	if (result == ERX_OK) {
		accept_features(device, &regs, taken);
		device_status |= regs.features_ok;
		put(device, regs.status, device_status);
		if ((get(device, regs.status) & regs.features_ok) == 0)
			result = ERX_ENOTSUP;
	}
	if (result == ERX_OK)
		result = install_queues(device);
	if (result != ERX_OK) {
		put(device, regs.status, device_status | regs.failed);
		return (result);
	}
	put(device, regs.status, device_status | regs.driver_ok);
	*accepted = taken;
	return (ERX_OK);
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
			bcopy(pieces[step].data, buffer + segments[step].offset, pieces[step].length);
		table[desc->index].addr = desc->addr;
		table[desc->index].len = desc->len;
		table[desc->index].flags = desc->flags;
		table[desc->index].next = desc->next;
	}
	avail_ring[plan->avail_slot] = plan->head;
	atomic_thread_fence(memory_order_release);
	avail->idx = plan->avail_idx;
	atomic_thread_fence(memory_order_seq_cst);
	put(record->device, record->regs.notify, record->index);
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
		bcopy(buffer + completion->ranges[range].offset, bytes + at, completion->ranges[range].length);
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
