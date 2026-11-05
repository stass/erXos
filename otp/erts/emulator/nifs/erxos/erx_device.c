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
#include "liberx/backend/api.h"

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
