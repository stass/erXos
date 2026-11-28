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
#include <string.h>
#endif

#include "erx/hw/device_access.h"
#include "erx/hw/device_owned.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/mem.h"

#include "erx_device_dma.h"
#include "erx_device_genet.h"
#include "erx_device_genet_model.h"
#include "erx_device_trb_form.h"
#include "erx_device_virtio_core.h"
#include "erx_device_xhci.h"
#include "erx_dma_arch.h"

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
	uint32_t			line_count;
	uint64_t			lines[ERX_DEVICE_LINES_MAX];	/* as the spec named them */
	uint32_t			entries[ERX_DEVICE_LINES_MAX];	/* each line's in line_entries */
	uint64_t			memory;		/* a given device's memory object */
	uint64_t			memory_size;	/* its bytes, 0 for none */
	uint8_t				*dma;		/* this domain's mapping of it */
	bool				coherent;	/* its DMA is cache-coherent */
	uintptr_t			register_keys[ERX_DEVICE_REGISTERS_MAX];
	uintptr_t			field_keys[ERX_DEVICE_FIELDS_MAX];
	erx_device_layout_t		layout;		/* where its registers are, decided at open */
	const erx_device_peripheral_t	*msix_table;	/* pci_msix, bound at open, or NULL for no MSI-X route */
	erx_device_msix_t		msix;		/* the spec's route, which msix_table is bound for */
};

static erx_device_t devices[ERX_DEVICE_MAX];
static _Atomic uint32_t devices_open;

/*
 * What records share (docs/design-shared-devices.md, "Pages inside a domain" and "Lines
 * inside a domain"). A run is the pages a record's window covers, mapped once at the first
 * open of any record in it; a line entry is one IRQ object, which a given record names by
 * the object's handle and any other by its selector, with the records' mark of whether two
 * devices of the unit name it. Both are kept for the boot, as records are, so an open that
 * fails after making one leaves it for the next open to take. Only opens, which the caller
 * serialises, write them, and nothing reads them through a record before the record is
 * published in devices_open.
 */
typedef struct page_run {
	erx_device_form_t	form;
	uint64_t		window;		/* a given run's window object */
	erx_device_pages_t	pages;		/* `offset` is 0 */
	volatile uint8_t	*mapping;	/* its first page */
} page_run_t;

typedef struct line_entry {
	erx_device_form_t	form;		/* whose naming `key` is */
	uint64_t		key;		/* a given record's handle, or a selector */
	uint64_t		irq;
	bool			shared;
} line_entry_t;

static page_run_t runs[ERX_DEVICE_MAX];
static uint32_t runs_mapped;
static line_entry_t line_entries[ERX_DEVICE_LINE_ENTRIES_MAX];
static uint32_t lines_taken;

#ifdef ERX_DEVICE_STAND_IN
/* The stand-in's device model, defined below store(), which calls it. */
static void	stand_in_preset(const erx_device_t *device);
static void	stand_in_stored(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset,
	    uint64_t value);
#endif

/*
 * `size` bytes of the object from `offset`, mapped read and write where the kernel reserves
 * room; a map the kernel refuses gives the reservation back.
 */
static int
map_object(uint64_t mem, uint64_t offset, uint64_t size, uint64_t *addr)
{
	int status = erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr);

	if (status == ERX_OK) {
		status = erx_vm_map(ERX_CAP_SELF, *addr, size, mem, offset, ERX_PROT_RW);
		if (status != ERX_OK)
			(void)erx_vm_release(ERX_CAP_SELF, *addr, size);
	}
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
 * A run's mapping: its pages, a physical device's an object made here from their addresses
 * and a given device's the pages of its window object at their offsets in it.
 */
static int
map_run(const erx_device_spec_t *spec, const erx_device_pages_t *pages, volatile uint8_t **mapping,
    erx_device_open_step_t *step)
{
	uint64_t mem = spec->window, offset = pages->base, addr;
	int status = ERX_OK;

	if (spec->form == ERX_DEVICE_FORM_PHYSICAL) {
		status = erx_mem_create_physical(0, 0, pages->base, pages->size, ERX_MEM_ATTR_DEVICE, &mem);
		offset = 0;
	}
	if (status != ERX_OK)
		return (status);
	status = map_object(mem, offset, pages->size, &addr);
	if (status != ERX_OK)
		*step = ERX_DEVICE_OPEN_MAP_WINDOW;
	else
		*mapping = (volatile uint8_t *)(uintptr_t)addr;
	return (status);
}

/*
 * Whether the window's pages are a mapped run's, with the run; ERX_EBUSY when they meet a
 * run without being it, since a run is its unit's pages and the record's writer and the unit
 * then disagree.
 */
static int
find_run(const erx_device_spec_t *spec, const erx_device_pages_t *pages, bool *found, uint32_t *run)
{
	*found = false;
	for (uint32_t index = 0; index < runs_mapped; index++) {
		const page_run_t *const mapped = &runs[index];

		if (mapped->form != spec->form || mapped->window != spec->window ||
		    !erx_device_pages_overlap(&mapped->pages, pages))
			continue;
		if (mapped->pages.base != pages->base || mapped->pages.size != pages->size)
			return (ERX_EBUSY);
		*found = true;
		*run = index;
		return (ERX_OK);
	}
	return (ERX_OK);
}

/*
 * The window inside its run's mapping, the run mapped here when this is the first open in
 * it. A hosted stand-in's window is plain memory of its own.
 */
static int
take_window(const erx_device_spec_t *spec, const erx_device_pages_t *pages, uint64_t size, volatile uint8_t **window,
    erx_device_open_step_t *step)
{
	page_run_t *run;
	uint32_t index = runs_mapped;
	bool found;
	int status;

	if (spec->form == ERX_DEVICE_FORM_STAND_IN)
		return (stand_in_window(size, window));
	status = find_run(spec, pages, &found, &index);
	if (status != ERX_OK)
		return (status);
	if (!found && runs_mapped == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	run = &runs[index];
	if (!found) {
		status = map_run(spec, pages, &run->mapping, step);
		if (status != ERX_OK)
			return (status);
		run->form = spec->form;
		run->window = spec->window;
		run->pages = (erx_device_pages_t){ .base = pages->base, .size = pages->size };
		runs_mapped++;
	}
	/* A run is its record's pages, so the window starts at its offset in the run's first page. */
	*window = run->mapping + pages->offset;
	return (ERX_OK);
}

/* The entry of the spec's line, false for a line no open has taken. */
static bool
find_line(const erx_device_spec_t *spec, uint32_t line, uint32_t *entry)
{
	for (uint32_t index = 0; index < lines_taken; index++) {
		if (line_entries[index].form == spec->form && line_entries[index].key == spec->lines[line]) {
			*entry = index;
			return (true);
		}
	}
	return (false);
}

/* Whether one of the first `open` records names the line entry. */
static bool
line_named(uint32_t entry, uint32_t open)
{
	for (uint32_t index = 0; index < open; index++) {
		for (uint32_t line = 0; line < devices[index].line_count; line++) {
			if (devices[index].entries[line] == entry)
				return (true);
		}
	}
	return (false);
}

/*
 * Whether the spec's lines agree with what is taken: a line two records name is shared, so
 * a spec that marks a taken line otherwise than its entry, or names a direct line an open
 * record names, disagrees with the unit. Checked before anything is made.
 */
static bool
lines_agree(const erx_device_spec_t *spec, uint32_t open)
{
	uint32_t entry;

	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (find_line(spec, line, &entry) && (line_entries[entry].shared != spec->shared[line] ||
		    (!spec->shared[line] && line_named(entry, open))))
			return (false);
	}
	return (true);
}

/*
 * Each line's entry: the one taken already, or a new one holding the line's IRQ object, a
 * given device's as it was given it and any other's made from its selector.
 */
static int
take_lines(const erx_device_spec_t *spec, uint32_t *entries)
{
	const uint32_t kind = spec->form == ERX_DEVICE_FORM_STAND_IN ? ERX_IRQ_SOFT : ERX_IRQ_LINE;
	line_entry_t *entry;
	int status = ERX_OK;

	for (uint32_t line = 0; status == ERX_OK && line < spec->line_count; line++) {
		if (find_line(spec, line, &entries[line]))
			continue;
		if (lines_taken == ERX_DEVICE_LINE_ENTRIES_MAX)
			return (ERX_ELIMIT);
		entry = &line_entries[lines_taken];
		*entry = (line_entry_t){ .form = spec->form, .key = spec->lines[line], .irq = spec->lines[line],
		    .shared = spec->shared[line] };
		if (spec->form != ERX_DEVICE_FORM_GIVEN)
			status = erx_irq_create(0, 0, kind, spec->lines[line], &entry->irq, NULL);
		if (status == ERX_OK)
			entries[line] = lines_taken++;
	}
	return (status);
}

/* A given device's memory, mapped here whole, or nothing for a device with none. */
static int
map_memory(const erx_device_spec_t *spec, uint8_t **dma, erx_device_open_step_t *step)
{
	uint64_t addr;
	int status;

	*dma = NULL;
	if (spec->memory_size == 0)
		return (ERX_OK);
	status = map_object(spec->memory, 0, spec->memory_size, &addr);
	if (status != ERX_OK)
		*step = ERX_DEVICE_OPEN_MAP_MEMORY;
	else
		*dma = (uint8_t *)(uintptr_t)addr;
	return (status);
}

/* Whether the spec names each of its lines once. */
static bool
lines_distinct(const erx_device_spec_t *spec)
{
	for (uint32_t line = 0; line < spec->line_count && line < ERX_DEVICE_LINES_MAX; line++) {
		for (uint32_t other = line + 1; other < spec->line_count && other < ERX_DEVICE_LINES_MAX; other++) {
			if (spec->lines[line] == spec->lines[other])
				return (false);
		}
	}
	return (true);
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
	if (peripheral == NULL || spec->line_count > ERX_DEVICE_LINES_MAX || !lines_distinct(spec) ||
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
	    record->memory != spec->memory || record->memory_size != spec->memory_size || record->coherent != spec->coherent ||
	    record->msix.address != spec->msix.address || record->msix.data != spec->msix.data ||
	    record->msix.offset != spec->msix.offset || record->msix.entries != spec->msix.entries)
		return (false);
	for (uint32_t line = 0; line < spec->line_count; line++) {
		if (record->lines[line] != spec->lines[line] ||
		    line_entries[record->entries[line]].shared != spec->shared[line])
			return (false);
	}
	return (true);
}

/*
 * Whether an earlier open decides this one, and what it decides. The same window is that
 * device again, or refused if anything else differs. So is memory another record holds,
 * since each device's queues are carved from its own, and a window that overlaps another
 * record's, whose registers would then reach the other's. Another window in the same pages is
 * a new record, which find_run places in their run. A stand-in has no window to share, so it is
 * always a new device.
 */
static bool
find_open(const erx_device_spec_t *spec, const erx_device_peripheral_t *peripheral, uint32_t open, uint32_t *device,
    int *status)
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
		if ((same_space(record, spec) && record->base < spec->base + spec->size && spec->base < record->base + record->size) ||
		    (spec->memory_size != 0 && record->memory_size != 0 && record->memory == spec->memory)) {
			*status = ERX_EBUSY;
			return (true);
		}
	}
	return (false);
}

/* One volatile load of `width` bits at `offset` of a window, which the table holds as 8, 16, 32 or 64. */
static uint64_t
load_word(volatile uint8_t *window, uint8_t width, uint64_t offset)
{
	switch (width) {
	case 8:
		return (erx_device_access_load8(window, offset));
	case 16:
		return (erx_device_access_load16(window, offset));
	case 64:
		return (erx_device_access_load64(window, offset));
	default:
		return (erx_device_access_load32(window, offset));
	}
}

/*
 * The function's MSI-X table bound at open (docs/design-pcie.md, "The choice"): the pci_msix
 * table at the route's offset of the window, every element of every register of each of the
 * route's entries wholly inside the window of `size` bytes at an offset aligned to its width,
 * the table at an offset aligned to 8, as the capability's table offset is, whose low 3 bits are
 * the BIR (pcireg.h:971-973). `table_end` is the end of its last byte, which the resolve keeps
 * every register apart from (resolve_layout); the route's offset itself for none. A route of
 * more entries than the table declares binds nothing and is refused.
 */
static bool
bind_msix(erx_device_t *record, const erx_device_msix_t *msix, uint64_t size, uint64_t *table_end)
{
	const erx_device_peripheral_t *const table = erx_device_peripheral_find("pci_msix", sizeof("pci_msix") - 1);

	record->msix_table = NULL;
	record->msix = *msix;
	*table_end = msix->offset;
	if (msix->entries == 0)
		return (true);
	if (table == NULL || msix->offset % 8u != 0)
		return (false);
	for (uint32_t index = 0; index < table->register_count; index++) {
		const erx_device_register_t *const reg = &table->registers[index];
		uint64_t last, end;

		if (msix->entries > reg->count || !erx_device_element_offset(reg, true, msix->entries - 1, &last) ||
		    __builtin_add_overflow(last, msix->offset, &last) || last % (reg->width / 8u) != 0 ||
		    __builtin_add_overflow(last, reg->width / 8u, &end) || end > size)
			return (false);
		if (end > *table_end)
			*table_end = end;
	}
	record->msix_table = table;
	return (true);
}

/*
 * The record's layout, erx_device_resolve run over its window of `size` bytes, every register
 * kept apart from its MSI-X table (bind_msix), so no register a driver may write is a table
 * word the NIF writes: each read it asks for is one load, and it asks for no more than its
 * sources and ERX_DEVICE_LIST_ENTRIES_MAX list entries, each inside the window. `resolve` is
 * the machine at its end; a table the window does not hold ends it refused before it starts.
 */
static bool
resolve_layout(erx_device_t *record, const erx_device_msix_t *msix, uint64_t size, erx_device_resolve_t *resolve)
{
	uint64_t table_end;

	if (!bind_msix(record, msix, size, &table_end)) {
		*resolve = (erx_device_resolve_t){ .op = ERX_DEVICE_RESOLVE_REFUSED, .size = size,
		    .refusal = { .rule = ERX_DEVICE_REFUSAL_MSIX, .offset_known = true,
		    .offset = msix->offset, .msix_entries = msix->entries } };
		return (false);
	}
	erx_device_resolve_begin(record->peripheral, size, msix->offset, table_end - msix->offset, &record->layout,
	    resolve);
	while (resolve->op == ERX_DEVICE_RESOLVE_READ)
		erx_device_resolve_step(record->peripheral, &record->layout, resolve,
		    load_word(record->windows[0], resolve->width, resolve->offset));
	return (resolve->op == ERX_DEVICE_RESOLVE_DONE);
}

int
erx_device_open(const erx_device_spec_t *spec, const uintptr_t *register_keys, const uintptr_t *field_keys,
    uint32_t *device, erx_device_open_failure_t *failure)
{
	/* Where the failure goes for a caller that wants none; opens are serialised, so one is enough. */
	static erx_device_open_failure_t unwanted;
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(spec->peripheral, spec->peripheral_length);
	const uint32_t open = atomic_load_explicit(&devices_open, memory_order_relaxed);
	/* A stand-in's window is the table's size; any other's the spec's, which spec_fits held to at least that. */
	const uint64_t size = spec->form == ERX_DEVICE_FORM_STAND_IN && peripheral != NULL ? peripheral->window_size : spec->size;
	erx_device_pages_t pages;
	erx_device_t *record;
	int status;

	if (failure == NULL)
		failure = &unwanted;
	failure->step = ERX_DEVICE_OPEN_OTHER;
	if (!spec_fits(spec, peripheral, &pages)) {
		failure->step = ERX_DEVICE_OPEN_SPEC;
		return (ERX_EINVAL);
	}
	if (find_open(spec, peripheral, open, device, &status))
		return (status);
	if (open == ERX_DEVICE_MAX)
		return (ERX_ELIMIT);
	if (!lines_agree(spec, open))
		return (ERX_EBUSY);
	record = &devices[open];
	record->peripheral = peripheral;
	status = take_window(spec, &pages, peripheral->window_size, &record->windows[0], &failure->step);
	if (status == ERX_OK && !resolve_layout(record, &spec->msix, size, &failure->layout)) {
		failure->step = ERX_DEVICE_OPEN_LAYOUT;
		status = ERX_EINVAL;
	}
	if (status == ERX_OK)
		status = take_lines(spec, record->entries);
	if (status == ERX_OK)
		status = map_memory(spec, &record->dma, &failure->step);
	if (status != ERX_OK)
		return (status);
	record->form = spec->form;
	record->window = spec->window;
	record->base = spec->base;
	record->size = spec->size;
	record->line_count = spec->line_count;
	for (uint32_t line = 0; line < spec->line_count; line++)
		record->lines[line] = spec->lines[line];
	record->memory = spec->memory;
	record->memory_size = spec->memory_size;
	record->coherent = spec->coherent;
	for (uint32_t index = 0; register_keys != NULL && index < peripheral->register_count; index++)
		record->register_keys[index] = register_keys[index];
	for (uint32_t index = 0; field_keys != NULL && index < peripheral->field_count; index++)
		record->field_keys[index] = field_keys[index];
#ifdef ERX_DEVICE_STAND_IN
	if (record->form == ERX_DEVICE_FORM_STAND_IN)
		stand_in_preset(record);
#endif
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

/* The one load of a register: one access of its declared width. */
static uint64_t
load(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset)
{
	return (load_word(device->windows[reg->window], reg->width, offset));
}

/* One volatile store of `width` bits at `offset` of a window, which the table holds as 8, 16, 32 or 64. */
static void
store_word(volatile uint8_t *window, uint8_t width, uint64_t offset, uint64_t value)
{
	switch (width) {
	case 8:
		erx_device_access_store8(window, offset, (uint8_t)value);
		break;
	case 16:
		erx_device_access_store16(window, offset, (uint16_t)value);
		break;
	case 64:
		erx_device_access_store64(window, offset, value);
		break;
	default:
		erx_device_access_store32(window, offset, (uint32_t)value);
		break;
	}
}

/* One volatile store of the register's declared width at `offset` of its window. */
static void
store_width(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	store_word(device->windows[reg->window], reg->width, offset, value);
}

/*
 * The one store to a register, waited for before anything after it: a store the device
 * answers with a bus error raises it asynchronously (an SError on AArch64), and the wait
 * has the answer arrive before the call returns, so the error is pending by then; the
 * architecture does not bound when it is taken, so that its pc lies in the store's
 * caller is likely, not certain. A hosted stand-in's device then acts on the store, as
 * a device would.
 */
static void
store(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	store_width(device, reg, offset, value);
	erx_dma_store_wait();
#ifdef ERX_DEVICE_STAND_IN
	if (device->form == ERX_DEVICE_FORM_STAND_IN)
		stand_in_stored(device, reg, offset, value);
#endif
}

#ifdef ERX_DEVICE_STAND_IN
/*
 * The hosted stand-in's model of a virtio-mmio transport, over its plain memory: the device
 * side of the few registers whose value is not simply what was last stored. It is a version 2
 * device whose queues take the largest size, offering VERSION_1 alone, and a reset lets every
 * queue go, as section 4.2.2.1 of the virtio specification has it. Its one ready word serves
 * every queue selector, so it models a device that holds all its queues ready or none. A
 * stand-in GENET is erx_device_genet_model over its window. A stand-in of another
 * peripheral is plain memory only.
 */
static bool
stand_in_virtio(const erx_device_t *device)
{
	return (erx_device_peripheral_is(device->peripheral, "virtio_mmio"));
}

/*
 * A register of the stand-in's memory, set at its width as its device would set it: straight to the
 * memory, not through store(), so the model never acts on its own stores. A name the table
 * does not have sets nothing.
 */
static void
stand_in_set(const erx_device_t *device, const char *name, uint32_t value)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	if (found < peripheral->register_count)
		store_width(device, &peripheral->registers[found], peripheral->registers[found].offset, value);
}

static bool
stand_in_genet(const erx_device_t *device)
{
	return (device->peripheral == erx_device_peripheral_find("genet", sizeof("genet") - 1));
}

/* A field of a register of the device's table by its name, or NULL. */
static const erx_device_field_t *
stand_in_field(const erx_device_t *device, const erx_device_register_t *reg, const char *name)
{
	const uint32_t found = erx_device_field_named(device->peripheral, reg, name);

	return (found < reg->field_count ? &device->peripheral->fields[reg->first_field + found] : NULL);
}

/*
 * The stand-in GENET's controller: erx_device_genet_model over its window, built for each
 * call. It keeps nothing between calls, since its stop shows at the store that makes it
 * (no DMA status reads), so all it knows is in the window and the queues' memory.
 */
static bool
stand_in_genet_model(const erx_device_t *device, erx_device_genet_model_t *model)
{
	return (stand_in_genet(device) && erx_device_genet_model_init(model, device->peripheral, device->windows[0], 0));
}

/* What a stand-in's virtio transport, or its GENET's revision, reads as before the driver stores anything. */
static void
stand_in_preset(const erx_device_t *device)
{
	erx_device_genet_model_t genet;

	if (stand_in_genet_model(device, &genet))
		erx_device_genet_model_preset(&genet);
	if (!stand_in_virtio(device))
		return;
	stand_in_set(device, "magic", ERX_VIRTIO_MMIO_MAGIC);
	stand_in_set(device, "version", ERX_VIRTIO_MMIO_VERSION);
	stand_in_set(device, "queue_num_max", ERX_DEVICE_QUEUE_SIZE_MAX);
}

/*
 * The device's side of the store of `value` at `offset` in `reg`: GENET's model acts on it,
 * and a virtio transport sets the features word the selector names or resets.
 */
static void
stand_in_stored(const erx_device_t *device, const erx_device_register_t *reg, uint64_t offset, uint64_t value)
{
	const erx_device_register_t *const owned = device->peripheral->registers;
	const uint32_t version_word = ERX_VIRTIO_F_VERSION_1 / 32, version_bit = ERX_VIRTIO_F_VERSION_1 % 32;
	erx_device_genet_model_t genet;

	if (stand_in_genet_model(device, &genet)) {
		erx_device_genet_model_stored(&genet, (uint32_t)offset, (uint32_t)value);
		return;
	}
	if (!stand_in_virtio(device))
		return;
	if (reg == &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_DEVICE_FEATURES_SEL])
		stand_in_set(device, "device_features", value == version_word ? UINT32_C(1) << version_bit : 0);
	if (reg == &owned[ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS] && value == 0)
		stand_in_set(device, "queue_ready", 0);
}
#endif

/* Where the element is in the device's window, by the layout its open decided; false for an element it does not have. */
static bool
element_at(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t *offset)
{
	return (erx_device_layout_offset(device->peripheral, &device->layout, reg, element.indexed, element.index, offset));
}

bool
erx_device_read(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t *value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_read_allowed(reg))
		return (false);
	*value = load(device, reg, offset);
	return (true);
}

/*
 * A write of a register with fields the NIF owns reads it first, which the generator allows
 * only where the read has no side effect, and is refused when it would change one of them.
 */
bool
erx_device_write(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element, uint64_t value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_write_allowed(reg, value) ||
	    (reg->owned != 0 && !erx_device_owned_kept(reg, load(device, reg, offset), value)))
		return (false);
	store(device, reg, offset, value);
	return (true);
}

uint32_t
erx_device_elements(const erx_device_t *device, const erx_device_register_t *reg)
{
	return (device->layout.elements[reg - device->peripheral->registers]);
}

/*
 * The command register and its DMA enable are found by their table names in sdhci's
 * table, so only a device of that peripheral reaches the register and the bit is the SVD
 * source's; a table that does not mark the register owned is refused whole.
 */
bool
erx_device_command(const erx_device_t *device, uint64_t word)
{
	const erx_device_peripheral_t *const sdhci = erx_device_peripheral_find("sdhci", sizeof("sdhci") - 1);
	const erx_device_register_t *cmdtm;
	uint32_t found, dma;

	if (sdhci == NULL || device->peripheral != sdhci)
		return (false);
	found = erx_device_register_named(sdhci, "cmdtm");
	if (found == sdhci->register_count || !sdhci->registers[found].owned_by_nif)
		return (false);
	cmdtm = &sdhci->registers[found];
	dma = erx_device_field_named(sdhci, cmdtm, "trns_dma");
	if (dma == cmdtm->field_count || !erx_device_command_allowed(cmdtm, &sdhci->fields[cmdtm->first_field + dma], word))
		return (false);
	store(device, cmdtm, cmdtm->offset, word);
	return (true);
}

bool
erx_device_read_field(const erx_device_t *device, const erx_device_register_t *reg, erx_device_element_t element,
    const erx_device_field_t *field, uint64_t *value)
{
	uint64_t offset;

	if (!element_at(device, reg, element, &offset) || !erx_device_field_read_allowed(reg, field))
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

	if (!element_at(device, reg, element, &offset) || plan.op == ERX_DEVICE_FIELD_REFUSED)
		return (false);
	store(device, reg, offset, erx_device_field_apply(&plan, plan.op == ERX_DEVICE_FIELD_UPDATE ? load(device, reg, offset) : 0));
	return (true);
}

/* The bytes of the device's window: a stand-in's is its table's size, any other's its spec's. */
static uint64_t
window_bytes(const erx_device_t *device)
{
	return (device->form == ERX_DEVICE_FORM_STAND_IN ? device->peripheral->window_size : device->size);
}

uint32_t
erx_device_space_elements(const erx_device_t *device, const erx_device_space_t *space)
{
	return (erx_device_space_blocks(space, window_bytes(device)));
}

bool
erx_device_config_read(const erx_device_t *device, const erx_device_space_t *space, erx_device_element_t element,
    uint64_t offset, uint64_t width, uint64_t *value)
{
	uint64_t at;

	if (!erx_device_space_offset(space, window_bytes(device), element.indexed, element.index, offset, width, &at))
		return (false);
	*value = load_word(device->windows[0], (uint8_t)(width * 8u), at);
	return (true);
}

/* A configuration store is waited for, as store() waits for a register's. */
bool
erx_device_config_write(const erx_device_t *device, const erx_device_space_t *space, erx_device_element_t element,
    uint64_t offset, uint64_t width, uint64_t value)
{
	uint64_t at;

	if (!erx_device_space_offset(space, window_bytes(device), element.indexed, element.index, offset, width, &at) ||
	    value >> (width * 8u) != 0)
		return (false);
	store_word(device->windows[0], (uint8_t)(width * 8u), at, value);
	erx_dma_store_wait();
	return (true);
}

bool
erx_device_line_irq(const erx_device_t *device, uint64_t line, uint64_t *irq)
{
	if (line >= device->line_count)
		return (false);
	*irq = line_entries[device->entries[line]].irq;
	return (true);
}

bool
erx_device_line_entry(const erx_device_t *device, uint64_t line, uint32_t *entry)
{
	if (line >= device->line_count)
		return (false);
	*entry = device->entries[line];
	return (true);
}

erx_device_bind_t
erx_device_bind_check(const erx_device_t *device, uint64_t line, erx_device_binder_t binder, const erx_device_t *through,
    uint64_t through_line)
{
	if (line >= device->line_count)
		return (ERX_DEVICE_BIND_NO_LINE);

	const bool shared = line_entries[device->entries[line]].shared;

	if (shared && binder == ERX_DEVICE_BINDER_DRIVER)
		return (ERX_DEVICE_BIND_SHARED);
	if (!shared && binder == ERX_DEVICE_BINDER_OWNER)
		return (ERX_DEVICE_BIND_DIRECT);
	if (through != NULL && (through != device || through_line != line))
		return (ERX_DEVICE_BIND_BUSY);
	return (ERX_DEVICE_BIND_OK);
}

/*
 * The queues and the device's initialisation. Each queue record is written whole by
 * erx_device_queue_create and changes only under the caller's serialisation. `ready` is true
 * from the install at the end of a negotiation to the start of the next: a queue that is not
 * ready is one the device may have forgotten, so nothing is posted on it and nothing
 * completed from it.
 *
 * A record runs one of the descriptor forms (docs/design-device-dma.md, "The descriptor
 * forms"), which the device's peripheral fixes: virtio-mmio's split ring, whose rings lie in
 * the queue's memory before its pool, or GENET's register ring, whose descriptors are the
 * device's registers, so its queue's memory is its pool alone. Everything the effect layer
 * does is common to both; only the form's core and the registers its plans publish differ.
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
	/* The rings' device addresses, low word then high word: written only by the install's plan. */
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

/* A GENET record's queues: receive, then transmit, in virtio-net's order. */
#define GENET_QUEUE_RX	0u
#define GENET_QUEUE_TX	1u

typedef enum queue_form {
	QUEUE_SPLIT_RING,		/* virtio-mmio */
	QUEUE_REGISTER_RING,		/* GENET */
	QUEUE_TRB_RING,			/* xHCI */
} queue_form_t;

/* A split ring: its device's virtio-mmio registers and the form's core, which owns its layout. */
typedef struct split_ring {
	virtio_registers_t		regs;
	erx_split_ring_t		ring;
} split_ring_t;

typedef struct register_ring {
	erx_device_genet_registers_t	regs;		/* the direction's, which the context's owned list points into */
	erx_dma_length_reg_t		length_reg;	/* the ring's buffer size, which the context names as a length */
	erx_device_genet_queue_t	core;
} register_ring_t;

/* A register of an xHCI controller where the device's open placed it (docs/design-usb.md, "Registers at offsets the controller reports"). */
typedef struct xhci_reg {
	const erx_device_register_t	*reg;
	uint64_t			offset;		/* in its window */
} xhci_reg_t;

/*
 * The registers of an xHCI controller its start reads and writes (docs/design-usb.md,
 * "Install"), and the fields it names, all from the device's table: every word the start reads
 * is taken apart, and every word it writes made, through these fields, an address as its low
 * word's register, then its high word's.
 */
typedef struct xhci_registers {
	/* Read once, when the record is made: the counts its layout needs, AC64 and the context size. */
	xhci_reg_t			hcsparams1, hcsparams2, hccparams1, pagesize;
	const erx_device_field_t	*max_slots, *max_ports, *scratchpads_hi, *scratchpads_lo, *ac64, *csz, *four_kib;
	uint64_t			doorbells;	/* doorbell 0's offset in the window */
	/* Read by each call of the start. */
	xhci_reg_t			usbsts;
	const erx_device_field_t	*hch, *cnr;
	/* The registers the NIF owns (erx/hw/device_owned.h), which only this file writes. */
	xhci_reg_t			usbcmd, config, erstsz, imod, iman, dcbaap[2], erstba[2], erdp[2], crcr[2];
	const erx_device_field_t	*rs, *hcrst, *inte, *max_slots_en, *erst_size, *imodi, *imodc, *ie, *rcs;
	const erx_device_field_t	*dcbaap_field[2], *erstba_field[2], *erdp_field[2], *crcr_field[2];
	/* Written by each post (a doorbell, element n slot n's, 0 the command ring's) and each completion (ERDP's busy bit). */
	const erx_device_register_t	*db;
	const erx_device_field_t	*db_target, *ehb;
} xhci_registers_t;

/*
 * An xHCI controller's record: the TRB form over its memory, laid out once from the counts it
 * read when it was made, and where its start stands between negotiate calls.
 */
typedef struct trb_ring {
	xhci_registers_t	regs;
	bool			reaches_64_bits;	/* HCCPARAMS1.AC64 */
	erx_trb_start_step_t	step;
	erx_trb_form_t		form;
} trb_ring_t;

typedef struct queue_record {
	const erx_device_t		*device;
	uint32_t			index;		/* the device's own number for the queue */
	queue_form_t			form;
	bool				ready;
	volatile uint8_t		*memory;	/* this domain's mapping of the queue: its rings, if any, from 0 */
	uint64_t			memory_size;	/* the rings, any gap, then the pool */
	uint64_t			pool_offset;	/* the pool's first byte, a granule boundary past the rings */
	uint64_t			device_base;	/* the device address of the queue's first byte */
	erx_dma_context_t		context;	/* the check's facts, from the fields above and the form */
	erx_dma_state_t			state;		/* who writes each region, as the last plan run left it */
	union {
		split_ring_t		split;		/* QUEUE_SPLIT_RING */
		register_ring_t		genet;		/* QUEUE_REGISTER_RING */
		trb_ring_t		trb;		/* QUEUE_TRB_RING */
	};
} queue_record_t;

static queue_record_t queues[ERX_DEVICE_QUEUES_MAX];
static uint32_t queues_open;
/* The bytes of each given device's memory its queues and regions have taken, from the start, by the device's index. */
static uint64_t memory_taken[ERX_DEVICE_MAX];
/*
 * Each given device's region table, by the device's index: every region erx_device_region made
 * for it, which each of its split rings' ledgers reads (erx_dma_ledger_make), so a post names
 * only its own device's regions. Changed only under the caller's lock, as every queue call is.
 */
static erx_dma_regions_t device_regions[ERX_DEVICE_MAX];

/* The device's region table: the one place a device finds its own. */
static erx_dma_regions_t *
regions_of(const erx_device_t *device)
{
	return (&device_regions[device - devices]);
}

/* A plain register of the device's table by name, or NULL; only virtio's queue sequence names them. */
static const erx_device_register_t *
plain_register(const erx_device_t *device, const char *name)
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	const uint32_t found = erx_device_register_named(peripheral, name);

	return (found == peripheral->register_count || peripheral->registers[found].count != 1 ? NULL :
	    &peripheral->registers[found]);
}

/*
 * The register, or the element of an array, that begins at a window offset of the device's
 * table, for one access at that offset: its width and its window. NULL for an offset where no
 * register or element begins. Plans name registers by window offset, so this one lookup maps
 * every register step, owned or not, to the register the table puts there.
 */
static const erx_device_register_t *
register_at(const erx_device_peripheral_t *peripheral, uint32_t offset)
{
	for (uint32_t at = 0; at < peripheral->register_count; at++) {
		const erx_device_register_t *const reg = &peripheral->registers[at];
		const uint32_t past = offset - reg->offset;

		if (offset < reg->offset)
			continue;
		if (reg->count == 1 ? past == 0 : reg->stride != 0 && past % reg->stride == 0 && past / reg->stride < reg->count)
			return (reg);
	}
	return (NULL);
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
 * by their generated index in virtio_mmio's table. The device's peripheral is virtio_mmio or
 * a kind whose table begins with virtio_mmio's registers at the same indices
 * (docs/design-generation.md, "Register inputs"). False for any other peripheral.
 */
static bool
virtio_registers(const erx_device_t *device, virtio_registers_t *regs)
{
	const erx_device_peripheral_t *const virtio = device->peripheral;
	const erx_device_register_t *owned;

	if (!erx_device_peripheral_is(virtio, "virtio_mmio"))
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

/* Whether the device's queues are the register ring's: its peripheral is GENET's. */
static bool
register_ring_device(const erx_device_t *device)
{
	return (device->peripheral == erx_device_peripheral_find("genet", sizeof("genet") - 1));
}

/* Whether the device's queues are the TRB ring form's: its peripheral is xHCI's. */
static bool
trb_ring_device(const erx_device_t *device)
{
	return (device->peripheral == erx_device_peripheral_find("xhci", sizeof("xhci") - 1));
}

/*
 * No queue's pool passes the largest contiguous object: the largest pool is the most buffers
 * of the largest size, a whole number of pages, which rounding to a granule of at most a page
 * leaves unchanged.
 */
_Static_assert((uint64_t)ERX_DEVICE_QUEUE_SIZE_MAX * ERX_DEVICE_BUFFER_MAX <= ERX_MEM_CONTIGUOUS_MAX &&
    (uint64_t)ERX_GENET_RING_SIZE * ERX_DEVICE_BUFFER_MAX <= ERX_MEM_CONTIGUOUS_MAX &&
    ERX_DEVICE_BUFFER_MAX % ERX_PAGE_SIZE == 0, "a queue's pool fits one contiguous object");
_Static_assert(ERX_GENET_RING_SIZE <= ERX_DMA_REGIONS_MAX, "a register ring's buffers fit a state");

/* `bytes` rounded up to a power of two `granule`; neither is near UINT32_MAX here. */
static uint32_t
granule_round(uint32_t bytes, uint32_t granule)
{
	return ((bytes + granule - 1) & ~(granule - 1));
}

/*
 * The bytes of a split ring's memory, its rings and its pool as erx_dma_layout_split_ring lays
 * them out from offset 0, or 0 for a geometry it refuses.
 */
static uint64_t
split_ring_bytes(uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	erx_dma_layout_t layout;
	const erx_dma_pool_t *const pool = &layout.pools[0];	/* the split ring's one pool, past its tables */

	if (!erx_dma_layout_split_ring(size, buffer_size, granule, UINT64_MAX, 0, 64, &layout))
		return (0);
	return (pool->first + (uint64_t)pool->count * pool->stride);
}

/*
 * The bytes of a queue's memory before its pool and in it. The split ring lays out its rings
 * and pool itself, so its memory is one run, taken as the carve's pool.
 */
static void
queue_bytes(const queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule, uint64_t *rings,
    uint64_t *pool)
{
	*rings = 0;
	*pool = record->form == QUEUE_SPLIT_RING ? split_ring_bytes(size, buffer_size, granule) :
	    (uint64_t)size * granule_round(buffer_size, granule);
}

/*
 * The form's core of a queue whose memory is placed: empty, at the device address its memory
 * gives; a split ring's ledger reads its device's region table. False for a pool the form
 * cannot address, such as one that reaches past GENET's 40 bits.
 */
static bool
core_init(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	if (record->form == QUEUE_REGISTER_RING)
		return (erx_device_genet_init(&record->genet.core, &record->genet.regs, buffer_size, granule,
		    record->device_base + record->pool_offset));
	return (erx_split_ring_make(&record->split.ring, size, buffer_size, granule, record->memory_size,
	    record->device_base, 64, regions_of(record->device)));
}

/*
 * A given device's queue, in the next pages of the device's one memory object: its rings, then
 * its pool. The object is contiguous to the device, so the device address of the rings and the
 * offsets of the queue name all of it. Nothing is read from the memory, which a former record
 * and the device may have written: the install writes the rings whole and hands each buffer
 * over afresh. ERX_ERANGE, taking nothing, for a queue the memory has no room for or the form
 * cannot address; the pages are taken only once everything else has succeeded.
 */
static int
carve_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	const erx_device_t *const device = record->device;
	uint64_t *const taken = &memory_taken[device - devices];
	erx_device_carve_t carve;
	uint64_t pool_addr, rings, pool;
	int status;

	queue_bytes(record, size, buffer_size, granule, &rings, &pool);
	if (!erx_device_carve(*taken, device->memory_size, rings, pool, &carve))
		return (ERX_ERANGE);
	status = erx_mem_dma_addr(device->memory, carve.rings, &record->device_base);
	if (status == ERX_OK)
		status = erx_mem_dma_addr(device->memory, carve.pool, &pool_addr);
	if (status != ERX_OK)
		return (status);
	if (pool_addr - record->device_base != carve.pool - carve.rings)
		return (ERX_ERANGE);
	record->pool_offset = carve.pool - carve.rings;
	record->memory_size = carve.end - carve.rings;
	if (!core_init(record, size, buffer_size, granule))
		return (ERX_ERANGE);
	record->memory = device->dma + carve.rings;
	*taken = carve.end;
	return (ERX_OK);
}

/*
 * A hosted stand-in's queue, in one zeroed block of plain memory on a granule: its rings, then
 * its pool. The split ring's device base is this process's own address of the block, since
 * the stand-in's device is code in this process. A register ring's is a stand-in address
 * below GENET's 40 bits, 4 GiB apart for each record, since this process's addresses may lie
 * above them; the device side finds the record's memory from the record, not the address. No
 * other build has one.
 */
static int
stand_in_queue_memory(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
#ifdef ERX_DEVICE_STAND_IN
	uint64_t rings, pool, bytes;
	uint8_t *memory;

	queue_bytes(record, size, buffer_size, granule, &rings, &pool);
	bytes = rings + pool;
	memory = aligned_alloc(granule, bytes);
	if (memory == NULL)
		return (ERX_ENOMEM);
	bzero(memory, bytes);
	record->device_base = record->form == QUEUE_REGISTER_RING ? (uint64_t)(record - queues + 1) << 32 :
	    (uintptr_t)memory;
	record->pool_offset = rings;
	record->memory_size = bytes;
	if (!core_init(record, size, buffer_size, granule)) {
		free(memory);
		return (ERX_ERANGE);
	}
	record->memory = memory;
	return (ERX_OK);
#else
	(void)record;
	(void)size;
	(void)buffer_size;
	(void)granule;
	return (ERX_ENOTSUP);
#endif
}

static int
place_queue(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	return (record->device->form == ERX_DEVICE_FORM_GIVEN ? carve_queue_memory(record, size, buffer_size, granule) :
	    stand_in_queue_memory(record, size, buffer_size, granule));
}

/* The check's facts every form shares: the queue's memory, the device's window and the granule. */
static erx_dma_context_t
common_facts(const queue_record_t *record, uint32_t granule)
{
	return ((erx_dma_context_t){ .memory_size = record->memory_size, .device_base = record->device_base,
	    .window_size = record->device->peripheral->window_size, .granule = granule });
}

/*
 * A split ring's queue: virtio-mmio version 2's registers and its memory, which the form's core
 * lays out; nothing is installed until a negotiation's reset.
 */
static int
split_ring_create(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	if (!virtio_registers(record->device, &record->split.regs) ||
	    get(record->device, record->split.regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	return (place_queue(record, size, buffer_size, granule));
}

/* A split ring's layout, which its core made. */
static const erx_dma_layout_t *
split_layout(const queue_record_t *record)
{
	return (erx_dma_ledger_layout(erx_split_ring_ledger(&record->split.ring)));
}

/*
 * One direction of a GENET record, queue 0 receiving or queue 1 transmitting, of 256
 * buffers, one for each of the direction's descriptors. Its registers come from the table, its
 * pool from the device's memory, and the check's facts from the form; the state is the
 * uninstalled queue's, every buffer the CPU's.
 */
static int
register_ring_create(queue_record_t *record, uint32_t size, uint32_t buffer_size, uint32_t granule)
{
	register_ring_t *const ring = &record->genet;
	int status;

	if (!erx_device_genet_registers(record->device->peripheral,
	    record->index == GENET_QUEUE_RX ? ERX_DEVICE_GENET_RX : ERX_DEVICE_GENET_TX, &ring->regs))
		return (ERX_ENOTSUP);
	/* Transmit's length field is 12 bits and receive's 16: a buffer past either is the wrong geometry. */
	if (buffer_size > ring->regs.buflen >> __builtin_ctz(ring->regs.buflen) ||
	    buffer_size > ring->regs.buf_length >> __builtin_ctz(ring->regs.buf_length))
		return (ERX_EINVAL);
	status = place_queue(record, size, buffer_size, granule);
	if (status != ERX_OK)
		return (status);
	record->context = common_facts(record, granule);
	erx_device_genet_form(&ring->core, &ring->regs, &ring->length_reg, &record->context);
	erx_device_genet_view(&ring->core, record->pool_offset, &record->state);
	return (ERX_OK);
}

/* A record's geometry, whichever its form. */
static uint32_t
queue_size(const queue_record_t *record)
{
	return (record->form == QUEUE_SPLIT_RING ? split_layout(record)->pools[0].count : ERX_GENET_RING_SIZE);
}

static uint32_t
queue_buffer_size(const queue_record_t *record)
{
	return (record->form == QUEUE_SPLIT_RING ? split_layout(record)->pools[0].size : record->genet.core.buffer_size);
}

/* Whether GENET's core has broken the queue, which then refuses every call until the reset. */
static bool
queue_broken(const queue_record_t *record)
{
	return (record->genet.core.broken);
}

/* A register ring broken by a plan the effect layer refused; a split ring's core breaks itself. */
static void
break_queue(queue_record_t *record)
{
	record->genet.core.broken = true;
}

int
erx_device_queue_create(const erx_device_t *device, uint32_t index, uint32_t size, uint32_t buffer_size,
    uint32_t *queue)
{
	const queue_form_t form = register_ring_device(device) ? QUEUE_REGISTER_RING : QUEUE_SPLIT_RING;
	const uint32_t granule = erx_dma_granule();
	queue_record_t *record;
	int status;

	/* A physical device does no DMA, so it has no queue (docs/design-fiasco.md, "Device records"). */
	if (device->form == ERX_DEVICE_FORM_PHYSICAL)
		return (ERX_ENOTSUP);
	/* An xHCI device's one record is the TRB form's, which its first negotiation makes. */
	if (trb_ring_device(device))
		return (ERX_ENOTSUP);
	if (buffer_size == 0 || buffer_size > ERX_DEVICE_BUFFER_MAX || (form == QUEUE_REGISTER_RING ?
	    index > GENET_QUEUE_TX || size != ERX_GENET_RING_SIZE : split_ring_bytes(size, buffer_size, granule) == 0))
		return (ERX_EINVAL);
	for (uint32_t open = 0; open < queues_open; open++) {
		const queue_record_t *const other = &queues[open];

		if (other->device != device || other->index != index)
			continue;
		if (queue_size(other) != size || queue_buffer_size(other) != buffer_size)
			return (ERX_EBUSY);
		*queue = open;
		return (ERX_OK);
	}
	if (queues_open == ERX_DEVICE_QUEUES_MAX)
		return (ERX_ELIMIT);
	record = &queues[queues_open];
	bzero(record, sizeof(*record));
	record->device = device;
	record->index = index;
	record->form = form;
	status = form == QUEUE_REGISTER_RING ? register_ring_create(record, size, buffer_size, granule) :
	    split_ring_create(record, size, buffer_size, granule);
	if (status != ERX_OK)
		return (status);
	*queue = queues_open++;
	return (ERX_OK);
}

/*
 * The regions. Each record is written whole before regions_open counts it, by a release
 * store, and never changes after, so erx_device_region_memory, which takes no lock, reads
 * only whole records. A region's device address, like a ring's, leaves this file only inside
 * the region entry a post writes.
 */
typedef struct region_record {
	const erx_device_t	*device;
	uint32_t		index;		/* the driver's number for it */
	uint64_t		bytes;		/* what the driver asked for */
	uint64_t		length;		/* its whole pages */
	uint8_t			*mapping;	/* this domain's mapping of it */
	uint64_t		addr;		/* its device address */
} region_record_t;

static region_record_t regions[ERX_DEVICE_REGIONS_MAX];
static _Atomic uint32_t regions_open;

/* The longest region the record's region entry, erx_virtio_gpu_mem_entry with its 32-bit length, can state. */
#define REGION_LENGTH_MAX	UINT32_MAX

/*
 * A given device's region, in the first pages of its memory no queue or region took, its
 * device address from the object and the offset. Its bytes are zeroed, so a new record never
 * shows the device what a former one left. ERX_ERANGE, taking nothing, for no room.
 */
static int
carve_region_memory(region_record_t *record, uint64_t bytes)
{
	const erx_device_t *const device = record->device;
	uint64_t *const taken = &memory_taken[device - devices];
	erx_device_region_carve_t carve;
	int status;

	if (!erx_device_carve_region(*taken, device->memory_size, bytes, REGION_LENGTH_MAX, &carve))
		return (ERX_ERANGE);
	status = erx_mem_dma_addr(device->memory, carve.start, &record->addr);
	if (status != ERX_OK)
		return (status);
	record->length = carve.length;
	record->mapping = device->dma + carve.start;
	bzero(record->mapping, carve.length);
	*taken = carve.end;
	return (ERX_OK);
}

/* A hosted stand-in's region, in zeroed plain memory whose device address is its own; no other build has one. */
static int
stand_in_region_memory(region_record_t *record, uint64_t bytes)
{
#ifdef ERX_DEVICE_STAND_IN
	erx_device_region_carve_t carve;
	uint8_t *mapping;

	if (!erx_device_carve_region(0, REGION_LENGTH_MAX, bytes, REGION_LENGTH_MAX, &carve))
		return (ERX_ERANGE);
	mapping = aligned_alloc(ERX_PAGE_SIZE, carve.length);
	if (mapping == NULL)
		return (ERX_ENOMEM);
	bzero(mapping, carve.length);
	record->length = carve.length;
	record->mapping = mapping;
	record->addr = (uintptr_t)mapping;
	return (ERX_OK);
#else
	(void)record;
	(void)bytes;
	return (ERX_ENOTSUP);
#endif
}

int
erx_device_region(const erx_device_t *device, uint32_t index, uint64_t bytes, uint32_t *region)
{
	const uint32_t open = atomic_load_explicit(&regions_open, memory_order_relaxed);
	region_record_t *record;
	int status;

	/*
	 * A physical device does no DMA, and a device that is not coherent would read a region no
	 * maintenance cleaned (docs/design-device-dma.md, "Regions and writers").
	 */
	if (device->form == ERX_DEVICE_FORM_PHYSICAL || !device->coherent)
		return (ERX_ENOTSUP);
	if (bytes == 0)
		return (ERX_EINVAL);
	for (uint32_t name = 0; name < open; name++) {
		if (regions[name].device != device || regions[name].index != index)
			continue;
		if (regions[name].bytes != bytes)
			return (ERX_EBUSY);
		*region = name;
		return (ERX_OK);
	}
	if (open == ERX_DEVICE_REGIONS_MAX)
		return (ERX_ELIMIT);
	record = &regions[open];
	*record = (region_record_t){ .device = device, .index = index, .bytes = bytes };
	status = device->form == ERX_DEVICE_FORM_GIVEN ? carve_region_memory(record, bytes) :
	    stand_in_region_memory(record, bytes);
	if (status != ERX_OK)
		return (status);
	/* A new name, at most ERX_DEVICE_REGIONS_MAX of them, of a length a region entry states: a refusal is a bug. */
	if (!erx_dma_regions_add(regions_of(device), (erx_dma_persistent_region_t){ .name = open,
	    .address = record->addr, .length = record->length }))
		return (ERX_EINVAL);
	atomic_store_explicit(&regions_open, open + 1, memory_order_release);
	*region = open;
	return (ERX_OK);
}

/* The framebuffer record's window as mapped here: the boot page's record and where it lies. */
typedef struct framebuffer_record {
	uint64_t		window;		/* the record's window object */
	uint64_t		offset;		/* the framebuffer's first byte in the object */
	uint64_t		bytes;		/* the framebuffer's length */
	volatile uint8_t	*mapping;	/* this domain's mapping of the object's first page */
} framebuffer_record_t;

static framebuffer_record_t framebuffers[ERX_DEVICE_FRAMEBUFFERS_MAX];
static _Atomic uint32_t framebuffers_open;

int
erx_device_framebuffer(uint64_t window, uint64_t offset, uint64_t bytes, uint32_t *framebuffer)
{
	const uint32_t open = atomic_load_explicit(&framebuffers_open, memory_order_relaxed);
	uint64_t end, pages, addr;
	int status;

	if (bytes == 0 || offset >= ERX_PAGE_SIZE || __builtin_add_overflow(offset, bytes, &end) ||
	    __builtin_add_overflow(end, ERX_PAGE_SIZE - 1, &pages))
		return (ERX_EINVAL);
	pages &= ~(uint64_t)(ERX_PAGE_SIZE - 1);
	for (uint32_t name = 0; name < open; name++) {
		const framebuffer_record_t *const record = &framebuffers[name];

		if (record->window == window && record->offset == offset && record->bytes == bytes) {
			*framebuffer = name;
			return (ERX_OK);
		}
	}
	if (open == ERX_DEVICE_FRAMEBUFFERS_MAX)
		return (ERX_EBUSY);
	status = map_object(window, 0, pages, &addr);
	if (status != ERX_OK)
		return (status);
	framebuffers[open] = (framebuffer_record_t){ .window = window, .offset = offset, .bytes = bytes,
	    .mapping = (volatile uint8_t *)(uintptr_t)addr };
	atomic_store_explicit(&framebuffers_open, open + 1, memory_order_release);
	*framebuffer = open;
	return (ERX_OK);
}

bool
erx_device_framebuffer_memory(uint32_t framebuffer, volatile uint8_t **base, uint64_t *bytes)
{
	if (framebuffer >= atomic_load_explicit(&framebuffers_open, memory_order_acquire))
		return (false);
	*base = framebuffers[framebuffer].mapping + framebuffers[framebuffer].offset;
	*bytes = framebuffers[framebuffer].bytes;
	return (true);
}

bool
erx_device_region_memory(uint32_t region, uint8_t **base, uint64_t *bytes)
{
	if (region >= atomic_load_explicit(&regions_open, memory_order_acquire))
		return (false);
	*base = regions[region].mapping;
	*bytes = regions[region].length;
	return (true);
}

/*
 * The install's checks for one split-ring queue: the device has let it go, as a reset makes
 * it, and can take its size. They write only the selector, so a refusal changes nothing of
 * any queue.
 */
static int
install_check(const queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->split.regs;

	put(device, regs->sel, record->index);
	if (get(device, regs->ready) != 0)
		return (ERX_EBUSY);
	if (get(device, regs->num_max) < split_layout(record)->pools[0].count)
		return (ERX_ERANGE);
	return (ERX_OK);
}

/*
 * The register ring's effect layer (docs/design-device-dma.md, "Calls, observations and plans"):
 * GENET answers a queue call through its pure round function (erx_device_genet_round); run_call
 * asks it for round after round. Each round's answers are checked against its copies
 * (answers_fit) and its plan against the record's last state and the state after it, then
 * ordered by the sequencer (accept_plan), all before any effect; then the
 * answers are given to the caller (deliver), the effects run in that order (apply_plan), and
 * the plan's `after` becomes the next plan's `before`. Nothing here chooses a step, a cache operation, a barrier or an order within a
 * call; the order of calls across the two directions of a GENET record is the negotiation's.
 *
 * One plan's steps, states, effects, registers, report values, answers and copy destinations
 * at a time, under the caller's serialisation: together far too large for a scheduler's
 * stack. The largest plan is GENET's install, an address for each of its 256 descriptors and
 * the ring's registers; a split ring's completion, a copy for each range of each entry it
 * takes, comes next.
 */
#define PLAN_MAX(a, b)	((a) > (b) ? (a) : (b))
_Static_assert(ERX_DEVICE_BUFFER_MAX <= ERX_DEVICE_COMPLETE_BYTES, "a completion takes at least one buffer");
#define PLAN_STEPS_MAX	PLAN_MAX(ERX_DEVICE_GENET_INSTALL_STEPS, ERX_DEVICE_COMPLETE_ENTRIES * ERX_DEVICE_CHAIN_MAX)
_Static_assert(PLAN_STEPS_MAX >= ERX_DEVICE_GENET_POST_STEPS && PLAN_STEPS_MAX >= ERX_DEVICE_COMPLETE_ENTRIES,
    "a plan's steps fit");
_Static_assert(ERX_DEVICE_COMPLETE_ENTRIES <= ERX_DMA_ANSWERS_MAX, "a completion's answers fit");

static erx_dma_step_t plan_steps[PLAN_STEPS_MAX];
static uint64_t plan_values[PLAN_STEPS_MAX];
/* Each register step's registers in the table, low then high, found before any effect runs. */
static const erx_device_register_t *plan_registers[PLAN_STEPS_MAX][2];
static erx_dma_state_t plan_after;
static erx_dma_answer_t plan_answers[ERX_DMA_ANSWERS_MAX];
static uint8_t *plan_destinations[PLAN_STEPS_MAX];
static erx_dma_effect_t plan_effects[ERX_DMA_EFFECTS_BOUND(ERX_DMA_REGIONS_MAX, PLAN_STEPS_MAX)];

/* A ring field's one store or load, of the width the step names: 1, 2, 4 or 8 bytes, aligned. */
static void
store_field(volatile uint8_t *at, uint32_t width, uint64_t value)
{
	switch (width) {
	case 1:
		*at = (uint8_t)value;
		break;
	case 2:
		*(volatile uint16_t *)(volatile void *)at = (uint16_t)value;
		break;
	case 4:
		*(volatile uint32_t *)(volatile void *)at = (uint32_t)value;
		break;
	default:
		*(volatile uint64_t *)(volatile void *)at = value;
		break;
	}
}

static uint64_t
load_field(volatile const uint8_t *at, uint32_t width)
{
	switch (width) {
	case 1:
		return (*at);
	case 2:
		return (*(volatile const uint16_t *)(volatile const void *)at);
	case 4:
		return (*(volatile const uint32_t *)(volatile const void *)at);
	default:
		return (*(volatile const uint64_t *)(volatile const void *)at);
	}
}

/*
 * The table's register for each register step of a plan the check accepted, into
 * plan_registers; false, finding nothing more, for an offset where the table has none, which
 * would be a bug in the form's core, or for one that is not 32 bits wide, the only width the
 * check allows a register step. So every effect of a plan reaches the register at the offset
 * its step names, owned or not, with the width the check saw, and a plan with a step that
 * reaches none runs nothing.
 */
static bool
resolve_registers(const queue_record_t *record, const erx_dma_plan_t *plan)
{
	const erx_device_peripheral_t *const peripheral = record->device->peripheral;

	for (uint32_t at = 0; at < plan->count; at++) {
		const erx_dma_step_t *const step = &plan->steps[at];

		if (step->target != ERX_DMA_REGISTER)
			continue;
		plan_registers[at][0] = register_at(peripheral, step->reg);
		plan_registers[at][1] = step->reg_high == ERX_DMA_NO_REGISTER ? NULL : register_at(peripheral, step->reg_high);
		if (plan_registers[at][0] == NULL || plan_registers[at][0]->width != 32 ||
		    (step->reg_high != ERX_DMA_NO_REGISTER && (plan_registers[at][1] == NULL || plan_registers[at][1]->width != 32)))
			return (false);
	}
	return (true);
}

/*
 * One step of a plan: a write or a publish into the queue's memory or a register at the offset
 * the step names (an address over two registers low word first), a copy out to
 * `destinations[at]`, or a report's one load into `values[at]`.
 */
static void
run_step(const queue_record_t *record, const erx_dma_step_t *step, uint32_t at, uint8_t *const *destinations,
    uint64_t *values)
{
	volatile uint8_t *const memory = record->memory + (step->target == ERX_DMA_MEMORY ? step->offset : 0);
	const erx_device_register_t *const *const regs = plan_registers[at];

	switch (step->kind) {
	case ERX_DMA_WRITE:
	case ERX_DMA_PUBLISH:
		if (step->target == ERX_DMA_REGISTER) {
			store(record->device, regs[0], step->reg, step->reg_high == ERX_DMA_NO_REGISTER ? step->value :
			    step->value & UINT32_MAX);
			if (step->reg_high != ERX_DMA_NO_REGISTER)
				store(record->device, regs[1], step->reg_high, step->value >> 32);
		} else if (step->source == ERX_DMA_BYTES) {
			bcopy(step->bytes, (void *)(uintptr_t)memory, step->length);
		} else if (step->source == ERX_DMA_ZEROS) {
			bzero((void *)(uintptr_t)memory, step->length);
		} else {
			store_field(memory, step->width, step->value);
		}
		break;
	case ERX_DMA_COPY:
		bcopy((const void *)(uintptr_t)memory, destinations[at], step->length);
		break;
	case ERX_DMA_REPORT:
		values[at] = step->target == ERX_DMA_REGISTER ? load(record->device, regs[0], step->reg) :
		    load_field(memory, step->width);
		break;
	}
}

static void
run_effects(const queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_effects_t *effects,
    uint8_t *const *destinations, uint64_t *values)
{
	for (uint32_t at = 0; at < effects->count; at++) {
		const erx_dma_effect_t *const effect = &effects->effects[at];

		switch (effect->kind) {
		case ERX_DMA_EFFECT_ZERO:
			bzero((void *)(uintptr_t)(record->memory + effect->offset), effect->length);
			break;
		case ERX_DMA_EFFECT_STEP:
			run_step(record, &plan->steps[effect->step], effect->step, destinations, values);
			break;
		case ERX_DMA_EFFECT_CLEAN:
			erx_dma_clean(record->memory + effect->offset, effect->length, effect->line);
			break;
		case ERX_DMA_EFFECT_CLEAN_INVAL:
			erx_dma_clean_inval(record->memory + effect->offset, effect->length, effect->line);
			break;
		case ERX_DMA_EFFECT_BARRIER:
			if (effect->barrier == ERX_DMA_BARRIER_PUBLISH)
				erx_dma_publish_barrier(effect->completes);
			else if (effect->barrier == ERX_DMA_BARRIER_REPORT)
				erx_dma_report_barrier();
			else
				erx_dma_completion_barrier();
			break;
		}
	}
}

/*
 * One round's plan accepted: `plan` from the record's last state to `after` (the record's own
 * state for an observation), checked, ordered into `effects` and its registers resolved, with
 * nothing run. False when the check, the sequencer or the register lookup refuses, which is a
 * bug in the form's core, not an input.
 */
static bool
accept_plan(queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_state_t *after,
    erx_dma_effects_t *effects)
{
	return (erx_device_dma_check(&record->context, &record->state, after, plan) &&
	    erx_device_dma_order(&record->state, after, plan, record->device->coherent, record->context.granule,
	    erx_dma_line(), effects) && resolve_registers(record, plan));
}

/* An accepted plan run, its copies into `plan_destinations`, and `after` kept as the record's state. */
static void
apply_plan(queue_record_t *record, const erx_dma_plan_t *plan, const erx_dma_effects_t *effects,
    const erx_dma_state_t *after)
{
	run_effects(record, plan, effects, plan_destinations, plan_values);
	if (after != &record->state)
		record->state = *after;
}

/* The record's facts a request carries to its form, which keeps only its own bookkeeping. */
static erx_dma_request_t
queue_request(const queue_record_t *record, erx_dma_request_kind_t kind)
{
	return ((erx_dma_request_t){ .kind = kind, .queue = record->index, .device_base = record->device_base,
	    .pool_offset = record->pool_offset, .ready = record->ready });
}

/* One round of a register ring's form; a split ring's core is called directly (split_ring_post). */
static void
form_round(queue_record_t *record, const erx_dma_request_t *request, erx_dma_round_t *round)
{
	erx_device_genet_round(&record->genet.core, &record->genet.regs, request, round);
}

/*
 * Whether a round's answers cover its plan's copies exactly: each answer's copy steps, in
 * order, fill its `length` bytes end to end, only a completion has copies, and a round with
 * answers has a sink to give them to. False is a bug in the form.
 */
static bool
answers_fit(const erx_dma_round_t *round, erx_device_sink_t *sink)
{
	uint32_t step = 0;

	if (round->answer_count > ERX_DMA_ANSWERS_MAX || (round->answer_count > 0 && sink == NULL))
		return (false);
	for (uint32_t at = 0; at < round->answer_count; at++) {
		const erx_dma_answer_t *const answer = &round->answers[at];
		uint64_t filled = 0;

		for (uint32_t copy = 0; copy < answer->copies; copy++, step++) {
			if (step >= round->count || round->steps[step].kind != ERX_DMA_COPY ||
			    round->steps[step].length > answer->length - filled)
				return (false);
			filled += round->steps[step].length;
		}
		if (filled != answer->length)
			return (false);
	}
	return (round->call == ERX_DMA_CALL_COMPLETE ? step == round->count : round->answer_count == 0);
}

/*
 * Each answer of a round whose answers fit given to the caller: the sink makes the answer's
 * `length` bytes, and the answer's copy steps are pointed at them in order, so a copy reaches
 * only what the sink made for its own tag.
 */
static void
deliver(const erx_dma_round_t *round, erx_device_sink_t *sink, void *context)
{
	uint32_t step = 0;

	for (uint32_t at = 0; at < round->answer_count; at++) {
		const erx_dma_answer_t *const answer = &round->answers[at];
		uint8_t *const into = sink(context, answer->tag, answer->length);
		uint64_t filled = 0;

		for (uint32_t copy = 0; copy < answer->copies; copy++, step++) {
			plan_destinations[step] = into + filled;
			filled += round->steps[step].length;
		}
	}
}

/*
 * One queue call: the form's rounds until the form ends the call, each round's answers and plan
 * checked before any effect, the caller's sinks included, then the answers given and the plan
 * run, with each observation's values handed to the next round. The status is the form's, or
 * ERX_EINVAL when a round's answers or plan are refused or the form does not end within
 * ERX_DMA_ROUNDS_MAX rounds, both bugs in the form's core that break the queue, so its
 * bookkeeping, which may already count the call, is used again only after a reset.
 * `answered` counts the answers given to `sink`; `value` is IDLE's.
 */
static int
run_call(queue_record_t *record, const erx_dma_request_t *request, erx_device_sink_t *sink, void *context,
    uint32_t *answered, uint64_t *value)
{
	uint32_t values = 0, total = 0;

	if (answered != NULL)
		*answered = 0;
	for (uint32_t number = 0; number < ERX_DMA_ROUNDS_MAX; number++) {
		erx_dma_round_t round = { .round = number, .values = plan_values, .value_count = values, .steps = plan_steps,
		    .after = &plan_after, .answers = plan_answers };
		erx_dma_effects_t effects = { .capacity = sizeof(plan_effects) / sizeof(plan_effects[0]),
		    .effects = plan_effects };
		erx_dma_plan_t plan;
		const erx_dma_state_t *after;

		form_round(record, request, &round);
		if (round.ends) {
			if (answered != NULL)
				*answered = total;
			if (value != NULL)
				*value = round.value;
			return (round.status);
		}
		plan = (erx_dma_plan_t){ .call = round.call, .count = round.count, .steps = plan_steps };
		after = round.keeps ? &record->state : &plan_after;
		if (!answers_fit(&round, sink) || !accept_plan(record, &plan, after, &effects)) {
			break_queue(record);
			return (ERX_EINVAL);
		}
		deliver(&round, sink, context);
		apply_plan(record, &plan, &effects, after);
		total += round.answer_count;
		values = round.call == ERX_DMA_CALL_OBSERVE ? round.count : 0;
	}
	break_queue(record);
	return (ERX_EINVAL);
}

/*
 * Every queue of the device stops being ready: at the start of a negotiation or of a DMA stop,
 * and when a negotiation fails.
 */
static void
unready_queues(const erx_device_t *device)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			queues[open].ready = false;
	}
}

/*
 * A split ring's effects (docs/design-device-dma.md, "Publication", "Releases"). Its core, over
 * the sequencer, decides every byte and register; what follows only applies that, under the
 * caller's lock: stores, cache maintenance and barriers for a device that is or is not
 * coherent, register writes, and the copies a completion gives. One sequence, element batch
 * and answer batch at a time, too large for a scheduler's stack.
 */
static erx_dma_sequence_t ring_sequence;
static erx_report_record_t ring_elements[ERX_DEVICE_COMPLETE_ENTRIES];
static erx_split_ring_answer_t ring_answers[ERX_DEVICE_COMPLETE_ENTRIES];

/*
 * The cache lines of `range` of the queue's memory cleaned, and with `invalidate` invalidated,
 * on a device that is not coherent; nothing on one that is. The memory is whole granules, so
 * rounding to lines stays inside it. True when it maintained anything.
 */
static bool
maintain(const queue_record_t *record, erx_dma_range_t range, bool invalidate)
{
	const uint64_t line = erx_dma_line();
	const uint64_t start = range.offset & ~(line - 1);
	const uint64_t end = (range.offset + range.length + line - 1) & ~(line - 1);

	if (record->device->coherent || range.length == 0)
		return (false);
	if (invalidate)
		erx_dma_clean_inval(record->memory + start, end - start, (uint32_t)line);
	else
		erx_dma_clean(record->memory + start, end - start, (uint32_t)line);
	return (true);
}

/* An install's register, by what it says, onto the device's own (an address low word first). */
static void
put_ring_register(const queue_record_t *record, erx_dma_register_write_t write)
{
	const erx_device_t *const device = record->device;
	const virtio_registers_t *const regs = &record->split.regs;
	const erx_device_register_t *const *address = NULL;

	switch (write.reg) {
	case ERX_DMA_VIRTQ_NUM:
		put(device, regs->num, write.value);
		return;
	case ERX_DMA_VIRTQ_READY:
		put(device, regs->ready, write.value);
		return;
	case ERX_DMA_VIRTQ_DESC:
		address = regs->desc;
		break;
	case ERX_DMA_VIRTQ_DRIVER:
		address = regs->driver;
		break;
	case ERX_DMA_VIRTQ_DEVICE:
		address = regs->device;
		break;
	/* The TRB form's, which a split ring's install never writes (erx_dma_install_controller). */
	case ERX_DMA_XHCI_SLOTS:
	case ERX_DMA_XHCI_DCBAA:
	case ERX_DMA_XHCI_EVENT_RING_SIZE:
	case ERX_DMA_XHCI_INTERRUPT_MODERATION:
	case ERX_DMA_XHCI_EVENT_DEQUEUE:
	case ERX_DMA_XHCI_SEGMENT_TABLE:
	case ERX_DMA_XHCI_INTERRUPTER_ENABLE:
	case ERX_DMA_XHCI_COMMAND_RING:
	case ERX_DMA_XHCI_RUN:
		return;
	}
	put(device, address[0], write.value & UINT32_MAX);
	put(device, address[1], write.value >> 32);
}

/*
 * A sequence applied in erx_device_sequencer.h's order: the zeros, the readable pieces' bytes
 * (`pieces[i]` fills sequence->fills[i]), the stores, the clean of every range passing to the
 * device and the publish barrier; then an install's registers after the queue's select, which
 * the core leaves to this layer because virtio-mmio banks them by it (Virtio 1.2, section 4.2.2),
 * and its ready bit; or a run's available index, the clean of its line, a publish barrier and
 * the doorbell. The zeros, fills and stores are plain copies: the device reads none of them
 * before the activation (the ready bit or the available index, itself one store) that follows
 * the publish barrier.
 */
static void
apply_memory(const queue_record_t *record, const erx_dma_sequence_t *sequence, const erx_dma_piece_t *pieces)
{
	volatile uint8_t *const memory = record->memory;

	for (uint32_t at = 0; at < sequence->zero_count; at++)
		bzero((void *)(uintptr_t)(memory + sequence->zeros[at].offset), sequence->zeros[at].length);
	for (uint32_t at = 0; at < sequence->fill_count; at++) {
		if (sequence->fills[at].length != 0)
			bcopy(pieces[at].bytes, (void *)(uintptr_t)(memory + sequence->fills[at].offset),
			    sequence->fills[at].length);
	}
	for (uint32_t at = 0; at < sequence->store_count; at++)
		bcopy(sequence->stores[at].bytes, (void *)(uintptr_t)(memory + sequence->stores[at].offset),
		    sequence->stores[at].length);
	for (uint32_t at = 0; at < sequence->clean_count; at++)
		maintain(record, sequence->cleans[at], false);
	erx_dma_publish_barrier(!record->device->coherent);
}

/*
 * A run's activation: its one store, little-endian as the device reads it, the clean of its line
 * and a publish barrier, after which the caller rings the doorbell.
 */
static void
apply_activation(const queue_record_t *record, const erx_dma_activation_t *activation)
{
	uint64_t value = 0;

	bcopy(activation->store.bytes, &value, activation->store.length);
	store_field(record->memory + activation->store.offset, activation->store.length, value);
	maintain(record, (erx_dma_range_t){ activation->store.offset, activation->store.length }, false);
	erx_dma_publish_barrier(!record->device->coherent);
}

/* A split ring's sequence whole: its memory (apply_memory), then an install's registers or a run's activation. */
static void
apply_sequence(const queue_record_t *record, const erx_dma_sequence_t *sequence, const erx_dma_piece_t *pieces)
{
	const erx_device_t *const device = record->device;
	const erx_dma_activation_t *const activation = &sequence->activation;

	apply_memory(record, sequence, pieces);
	if (activation->kind == ERX_DMA_ACTIVATE_REGISTER) {
		put(device, record->split.regs.sel, record->index);
		for (uint32_t at = 0; at < sequence->register_count; at++)
			put_ring_register(record, sequence->registers[at]);
		put_ring_register(record, activation->reg);
		return;
	}
	apply_activation(record, activation);
	put(device, record->split.regs.notify, record->index);
}

/*
 * The install of one split-ring queue, after its checks and the reset's idle report: every ring
 * zeroed and cleaned, so no index a former driver, a former record or the device left in them is
 * ever read, then the queue's size, its rings' addresses and ready (erx_split_ring_install).
 * ERX_EINVAL when the core refuses, which is a bug.
 */
static int
install_apply(queue_record_t *record)
{
	if (erx_split_ring_install(&record->split.ring, &ring_sequence) != ERX_OK)
		return (ERX_EINVAL);
	apply_sequence(record, &ring_sequence, NULL);
	record->ready = true;
	return (ERX_OK);
}

/*
 * The device's idle report: its status reads 0 after the reset, so it holds no chain of any
 * queue, and every split ring of the device ends its chains and is whole again.
 */
static void
reset_queues(const erx_device_t *device)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device)
			erx_split_ring_reset(&queues[open].split.ring);
	}
}

/*
 * Every queue of the device is checked before any is changed, so a device that refuses has
 * none installed. A plan refused part way, a bug, leaves no queue of the device ready, the
 * ones installed before it included, since the negotiation then marks the device FAILED.
 */
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
			status = install_apply(&queues[open]);
	}
	if (status != ERX_OK)
		unready_queues(device);
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
static int
split_ring_negotiate(const erx_device_t *device, uint64_t wanted, uint64_t *accepted)
{
	virtio_registers_t regs;
	uint64_t device_status, taken;
	int result = ERX_OK;

	if (!virtio_registers(device, &regs) || get(device, regs.version) != ERX_VIRTIO_MMIO_VERSION)
		return (ERX_ENOTSUP);
	put(device, regs.status, 0);
	if (get(device, regs.status) != 0)
		return (ERX_EBUSY);
	reset_queues(device);
	device_status = regs.acknowledge;
	put(device, regs.status, device_status);
	device_status |= regs.driver_bit;
	put(device, regs.status, device_status);
	if (!erx_split_ring_features(wanted, offered_features(device, &regs), &taken))
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

/* The device's queue of its own number `index`, or NULL. */
static queue_record_t *
queue_numbered(const erx_device_t *device, uint32_t index)
{
	for (uint32_t open = 0; open < queues_open; open++) {
		if (queues[open].device == device && queues[open].index == index)
			return (&queues[open]);
	}
	return (NULL);
}

/* A GENET record's receive and transmit queues, into `rings`; false unless it has both. */
static bool
register_ring_queues(const erx_device_t *device, queue_record_t *rings[2])
{
	rings[0] = queue_numbered(device, GENET_QUEUE_RX);
	rings[1] = queue_numbered(device, GENET_QUEUE_TX);
	return (rings[0] != NULL && rings[1] != NULL);
}

/*
 * GENET's reset and idle report (docs/design-device-dma.md, "Install and reset") over the
 * record's two queues `rings`, across the two directions in the order the design gives, which is
 * why it lives here and not in the per-direction form: DMA control stopped, transmit then
 * receive; then each direction's DMA status read once by its IDLE call, into `status`. ERX_OK
 * once both show the stop; ERX_EBUSY, with both engines left stopped, until then, so a later call
 * writes the stop again and reads again. It installs nothing and hands no buffer back. Any other
 * answer is a bug: ERX_ENOTSUP for a table without DMA control, ERX_EINVAL for a refused IDLE call.
 */
static int
register_ring_stop(const erx_device_t *device, queue_record_t *const rings[2], uint64_t status[2])
{
	const erx_device_peripheral_t *const peripheral = device->peripheral;
	bool idle = true;

	for (uint32_t side = 2; side-- > 0;) {
		const erx_device_genet_registers_t *const regs = &rings[side]->genet.regs;
		const erx_device_register_t *const ctrl = register_at(peripheral, regs->dma_ctrl);

		if (ctrl == NULL)
			return (ERX_ENOTSUP);
		put(device, ctrl, erx_device_genet_stop(regs));
	}
	for (uint32_t side = 0; side < 2; side++) {
		const erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_IDLE);
		const int shown = run_call(rings[side], &request, NULL, NULL, NULL, &status[side]);

		if (shown != ERX_OK && shown != ERX_EBUSY)
			return (ERX_EINVAL);
		idle = idle && shown == ERX_OK;
	}
	return (idle ? ERX_OK : ERX_EBUSY);
}

/*
 * GENET's reset and install (docs/design-device-dma.md, "Install and reset"): ERX_EINVAL for a
 * record without both its queues; the reset and idle report of register_ring_stop, whose
 * ERX_EBUSY it answers with nothing installed; then each queue's INSTALL call, which takes every
 * buffer back and installs its ring, receive then transmit; and only once both rings are
 * installed, each START call, receive first. The features mean nothing to GENET: none are
 * accepted. A refused plan, a bug, leaves both queues not ready.
 */
static int
register_ring_negotiate(const erx_device_t *device, uint64_t *accepted)
{
	queue_record_t *rings[2];
	uint64_t status[2];
	int stopped;

	if (!register_ring_queues(device, rings))
		return (ERX_EINVAL);
	stopped = register_ring_stop(device, rings, status);
	if (stopped != ERX_OK)
		return (stopped);
	for (uint32_t side = 0; side < 2; side++) {
		erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_INSTALL);

		request.idle = status[side];
		if (run_call(rings[side], &request, NULL, NULL, NULL, NULL) != ERX_OK)
			return (ERX_EINVAL);
	}
	for (uint32_t side = 0; side < 2; side++) {
		const erx_dma_request_t request = queue_request(rings[side], ERX_DMA_REQUEST_START);

		if (run_call(rings[side], &request, NULL, NULL, NULL, NULL) != ERX_OK)
			return (ERX_EINVAL);
	}
	rings[0]->ready = rings[1]->ready = true;
	*accepted = 0;
	return (ERX_OK);
}

/*
 * The TRB ring form's effects (docs/design-usb.md, "Install"): an xHCI controller's record, its
 * reset and start, one step a call. The form's core decides every byte of memory and every
 * register value, and its start core (erx_trb_form_start_next) every step; what follows only
 * reads the controller's registers and writes them, through the fields of the device's table.
 */

/* The register `name` of the device's table, where the device's open placed it; false for none. */
static bool
xhci_register(const erx_device_t *device, const char *name, xhci_reg_t *out)
{
	const erx_device_peripheral_t *const xhci = device->peripheral;
	const uint32_t found = erx_device_register_named(xhci, name);

	if (found == xhci->register_count)
		return (false);
	out->reg = &xhci->registers[found];
	return (element_at(device, out->reg, (erx_device_element_t){ .indexed = false }, &out->offset));
}

/* The field `name` of `r`, or NULL. */
static const erx_device_field_t *
xhci_field(const erx_device_t *device, xhci_reg_t r, const char *name)
{
	const uint32_t found = erx_device_field_named(device->peripheral, r.reg, name);

	return (found < r.reg->field_count ? &device->peripheral->fields[r.reg->first_field + found] : NULL);
}

/* An address's two registers, low word then high, and their address fields. */
static bool
xhci_address(const erx_device_t *device, const char *low, const char *high, const char *low_field,
    const char *high_field, xhci_reg_t r[2], const erx_device_field_t *f[2])
{
	if (!xhci_register(device, low, &r[0]) || !xhci_register(device, high, &r[1]))
		return (false);
	f[0] = xhci_field(device, r[0], low_field);
	f[1] = xhci_field(device, r[1], high_field);
	return (f[0] != NULL && f[1] != NULL);
}

/* Every register and field the start names, from the device's table; false when one is missing. */
static bool
xhci_registers(const erx_device_t *device, xhci_registers_t *regs)
{
	const uint32_t doorbell = erx_device_register_named(device->peripheral, "db");
	const erx_device_field_t *fields[20];
	uint32_t count = 0;

	if (!xhci_register(device, "hcsparams1", &regs->hcsparams1) || !xhci_register(device, "hcsparams2", &regs->hcsparams2) ||
	    !xhci_register(device, "hccparams1", &regs->hccparams1) || !xhci_register(device, "pagesize", &regs->pagesize) ||
	    !xhci_register(device, "usbsts", &regs->usbsts) || !xhci_register(device, "usbcmd", &regs->usbcmd) ||
	    !xhci_register(device, "config", &regs->config) || !xhci_register(device, "erstsz", &regs->erstsz) ||
	    !xhci_register(device, "imod", &regs->imod) || !xhci_register(device, "iman", &regs->iman) ||
	    !xhci_address(device, "dcbaap_lo", "dcbaap_hi", "pointer_lo", "pointer_hi", regs->dcbaap, regs->dcbaap_field) ||
	    !xhci_address(device, "erstba_lo", "erstba_hi", "address_lo", "address_hi", regs->erstba, regs->erstba_field) ||
	    !xhci_address(device, "erdp_lo", "erdp_hi", "pointer_lo", "pointer_hi", regs->erdp, regs->erdp_field) ||
	    !xhci_address(device, "crcr_lo", "crcr_hi", "pointer_lo", "pointer_hi", regs->crcr, regs->crcr_field) ||
	    doorbell == device->peripheral->register_count || !element_at(device, &device->peripheral->registers[doorbell],
	    (erx_device_element_t){ .indexed = true, .index = 0 }, &regs->doorbells))
		return (false);
	fields[count++] = regs->max_slots = xhci_field(device, regs->hcsparams1, "maxslots");
	fields[count++] = regs->max_ports = xhci_field(device, regs->hcsparams1, "maxports");
	fields[count++] = regs->scratchpads_hi = xhci_field(device, regs->hcsparams2, "spb_max_hi");
	fields[count++] = regs->scratchpads_lo = xhci_field(device, regs->hcsparams2, "spb_max_lo");
	fields[count++] = regs->ac64 = xhci_field(device, regs->hccparams1, "ac64");
	fields[count++] = regs->csz = xhci_field(device, regs->hccparams1, "csz");
	fields[count++] = regs->four_kib = xhci_field(device, regs->pagesize, "four_kib");
	fields[count++] = regs->hch = xhci_field(device, regs->usbsts, "hch");
	fields[count++] = regs->cnr = xhci_field(device, regs->usbsts, "cnr");
	fields[count++] = regs->rs = xhci_field(device, regs->usbcmd, "rs");
	fields[count++] = regs->hcrst = xhci_field(device, regs->usbcmd, "hcrst");
	fields[count++] = regs->inte = xhci_field(device, regs->usbcmd, "inte");
	fields[count++] = regs->max_slots_en = xhci_field(device, regs->config, "maxslotsen");
	fields[count++] = regs->erst_size = xhci_field(device, regs->erstsz, "size");
	fields[count++] = regs->imodi = xhci_field(device, regs->imod, "imodi");
	fields[count++] = regs->imodc = xhci_field(device, regs->imod, "imodc");
	fields[count++] = regs->ie = xhci_field(device, regs->iman, "ie");
	fields[count++] = regs->rcs = xhci_field(device, regs->crcr[0], "rcs");
	fields[count++] = regs->ehb = xhci_field(device, regs->erdp[0], "ehb");
	regs->db = &device->peripheral->registers[doorbell];
	fields[count++] = regs->db_target = xhci_field(device, (xhci_reg_t){ .reg = regs->db }, "target");
	for (uint32_t at = 0; at < count; at++) {
		if (fields[at] == NULL)
			return (false);
	}
	return (true);
}

/* Field `field` of `word`, a word read from `r`, into `*value`; false for a field the table lets no one read. */
static bool
xhci_field_of(xhci_reg_t r, const erx_device_field_t *field, uint64_t word, uint64_t *value)
{
	return (erx_device_field_of(r.reg, (erx_device_element_t){ .indexed = false }, field, word, value));
}

/* One word to store into a register: the start composes every word of a step before it stores any. */
typedef struct xhci_word {
	xhci_reg_t	r;
	uint64_t	word;
} xhci_word_t;

/*
 * `*word` with `field` replaced by `value`; false for a value the field cannot hold, which the
 * values the form's core gives never are.
 */
static bool
with_field(const erx_device_field_t *field, uint64_t value, uint64_t *word)
{
	if (value > field->mask >> field->shift)
		return (false);
	*word = (*word & ~field->mask) | value << field->shift;
	return (true);
}

/*
 * A word of `r` to store with `field` set to `value`: the bits a store keeps (the register's
 * preserve mask) as one read finds them, and every other bit 0, so a one-to-clear bit such as
 * IMAN.IP or ERDP.EHB clears nothing and a one-to-set bit such as HCRST sets nothing.
 */
static bool
field_word(const erx_device_t *device, xhci_reg_t r, const erx_device_field_t *field, uint64_t value, xhci_word_t *out)
{
	out->r = r;
	out->word = r.reg->preserve == 0 ? 0 : load(device, r.reg, r.offset) & r.reg->preserve;
	return (with_field(field, value, &out->word));
}

/*
 * An address as the two words of its registers, low word then high: the low word's field holds
 * its bits from the field's shift up, and the address has none below, beside the bits `low_bits`
 * of the low word, which the caller sets.
 */
static bool
address_words(const erx_device_t *device, const xhci_reg_t r[2], const erx_device_field_t *const f[2], uint64_t address,
    uint64_t low_bits, xhci_word_t out[2])
{
	const uint64_t low = address & UINT32_MAX & ~low_bits;

	return ((low & ~f[0]->mask) == 0 && field_word(device, r[0], f[0], low >> f[0]->shift, &out[0]) &&
	    field_word(device, r[1], f[1], address >> 32, &out[1]));
}

/*
 * The words of one register write of the install (erx_device_sequencer.h), appended at
 * `words[*count]`, room for two; false for a write the controller's registers cannot state, a
 * virtio-mmio register among them, which is a bug of the form's core.
 */
static bool
install_words(const erx_device_t *device, const xhci_registers_t *regs, erx_dma_register_write_t write,
    xhci_word_t *words, uint32_t *count)
{
	xhci_word_t *const out = &words[*count];
	uint32_t made_count = 1;
	bool made = false;

	switch (write.reg) {
	case ERX_DMA_XHCI_SLOTS:
		made = field_word(device, regs->config, regs->max_slots_en, write.value, out);
		break;
	case ERX_DMA_XHCI_EVENT_RING_SIZE:
		made = field_word(device, regs->erstsz, regs->erst_size, write.value, out);
		break;
	case ERX_DMA_XHCI_INTERRUPT_MODERATION:
		/*
		 * The whole register, nothing read, as FreeBSD writes it (xhci.c:369): IMODC 0, so whatever
		 * count the reset left (undefined, xHCI 1.2, Table 5-39) cannot delay the first interrupt.
		 */
		*out = (xhci_word_t){ .r = regs->imod, .word = 0 };
		made = with_field(regs->imodi, write.value, &out->word) && with_field(regs->imodc, 0, &out->word);
		break;
	case ERX_DMA_XHCI_INTERRUPTER_ENABLE:
		made = field_word(device, regs->iman, regs->ie, write.value, out);
		break;
	case ERX_DMA_XHCI_RUN:
		made = field_word(device, regs->usbcmd, regs->rs, write.value, out) &&
		    with_field(regs->inte, write.value, &out->word);
		break;
	case ERX_DMA_XHCI_DCBAA:
		made_count = 2;
		made = address_words(device, regs->dcbaap, regs->dcbaap_field, write.value, 0, out);
		break;
	case ERX_DMA_XHCI_EVENT_DEQUEUE:
		made_count = 2;
		made = address_words(device, regs->erdp, regs->erdp_field, write.value, 0, out);
		break;
	case ERX_DMA_XHCI_SEGMENT_TABLE:
		made_count = 2;
		made = address_words(device, regs->erstba, regs->erstba_field, write.value, 0, out);
		break;
	case ERX_DMA_XHCI_COMMAND_RING:
		/* Its cycle state rides in bit 0 of the position, the low word's RCS. */
		made_count = 2;
		made = address_words(device, regs->crcr, regs->crcr_field, write.value, regs->rcs->mask, out) &&
		    with_field(regs->rcs, (write.value & regs->rcs->mask) >> regs->rcs->shift, &out[0].word);
		break;
	case ERX_DMA_VIRTQ_NUM:
	case ERX_DMA_VIRTQ_DESC:
	case ERX_DMA_VIRTQ_DRIVER:
	case ERX_DMA_VIRTQ_DEVICE:
	case ERX_DMA_VIRTQ_READY:
		break;
	}
	*count += made_count;
	return (made);
}

/* The layout a new record is laid out into, too large for a scheduler's stack; used only under the caller's lock. */
static erx_device_trb_layout_t trb_layout;

/*
 * The counts the layout needs, read once from the capability registers (xHCI 1.2, 5.3.3-5.3.6):
 * the slots it enables, the controller's own, at most ERX_DEVICE_TRB_SLOTS_MAX; its ports; its
 * scratchpad pages, whose count is split across two fields, the low one's width the table's; the
 * context size; doorbell 0's place. ERX_ENOTSUP for a field no one may read, more scratchpad pages
 * than ERX_DEVICE_TRB_SCRATCHPADS_MAX, or a page size that excludes 4 KiB (5.4.3, p. 400).
 */
static int
controller_counts(const erx_device_t *device, trb_ring_t *ring, erx_device_trb_controller_t *controller)
{
	const xhci_registers_t *const regs = &ring->regs;
	const uint64_t params1 = load(device, regs->hcsparams1.reg, regs->hcsparams1.offset);
	const uint64_t params2 = load(device, regs->hcsparams2.reg, regs->hcsparams2.offset);
	const uint64_t capabilities = load(device, regs->hccparams1.reg, regs->hccparams1.offset);
	const uint64_t pagesize = load(device, regs->pagesize.reg, regs->pagesize.offset);
	uint64_t slots, ports, high, low, ac64, csz, four_kib;

	if (!xhci_field_of(regs->hcsparams1, regs->max_slots, params1, &slots) ||
	    !xhci_field_of(regs->hcsparams1, regs->max_ports, params1, &ports) ||
	    !xhci_field_of(regs->hcsparams2, regs->scratchpads_hi, params2, &high) ||
	    !xhci_field_of(regs->hcsparams2, regs->scratchpads_lo, params2, &low) ||
	    !xhci_field_of(regs->hccparams1, regs->ac64, capabilities, &ac64) ||
	    !xhci_field_of(regs->hccparams1, regs->csz, capabilities, &csz) ||
	    !xhci_field_of(regs->pagesize, regs->four_kib, pagesize, &four_kib))
		return (ERX_ENOTSUP);
	controller->scratchpads = (uint32_t)(high << __builtin_popcountll(regs->scratchpads_lo->mask) | low);
	if (four_kib == 0 || controller->scratchpads > ERX_DEVICE_TRB_SCRATCHPADS_MAX)
		return (ERX_ENOTSUP);
	controller->slots = (uint32_t)(slots < ERX_DEVICE_TRB_SLOTS_MAX ? slots : ERX_DEVICE_TRB_SLOTS_MAX);
	controller->ports = (uint32_t)ports;
	controller->context_size = csz != 0 ? 2u * ERX_XHCI_SLOT_CONTEXT_SIZE : ERX_XHCI_SLOT_CONTEXT_SIZE;
	controller->doorbells = (uint32_t)regs->doorbells;
	ring->reaches_64_bits = ac64 != 0;
	return (ERX_OK);
}

/*
 * An xHCI device's record, made by its first negotiate call before anything is written: its
 * registers from the table, its counts from the controller, and the TRB form over the next pages
 * of the device's memory, which the device addresses contiguously, laid out once and kept until
 * the device closes. ERX_ENOTSUP for a device that is not given or a table without what the start
 * names, besides controller_counts's; ERX_ERANGE for memory the layout does not fit or, on a
 * controller without AC64, memory past 4 GiB (docs/design-usb.md, "Address width"), checked by
 * the install's own test; ERX_ELIMIT with every record taken. Nothing is taken on a refusal.
 */
static int
trb_ring_create(const erx_device_t *device, queue_record_t **made)
{
	uint64_t *const taken = &memory_taken[device - devices];
	queue_record_t *record;
	erx_device_trb_controller_t controller;
	erx_device_carve_t carve;
	uint64_t base, last;
	int status;

	if (device->form != ERX_DEVICE_FORM_GIVEN)
		return (ERX_ENOTSUP);
	if (queues_open == ERX_DEVICE_QUEUES_MAX)
		return (ERX_ELIMIT);
	record = &queues[queues_open];
	bzero(record, sizeof(*record));
	record->device = device;
	record->form = QUEUE_TRB_RING;
	if (!xhci_registers(device, &record->trb.regs))
		return (ERX_ENOTSUP);
	status = controller_counts(device, &record->trb, &controller);
	if (status != ERX_OK)
		return (status);
	if (*taken >= device->memory_size || erx_mem_dma_addr(device->memory, *taken, &base) != ERX_OK ||
	    !erx_device_trb_layout(&trb_layout, &erx_device_trb_shape, &controller, base, erx_dma_granule(),
	    device->memory_size - *taken) || !erx_device_carve(*taken, device->memory_size, 0, trb_layout.bytes, &carve) ||
	    erx_mem_dma_addr(device->memory, carve.end - 1, &last) != ERX_OK || last - base != carve.end - 1 - carve.rings ||
	    !erx_trb_form_make(&record->trb.form, &trb_layout, regions_of(device)))
		return (ERX_ERANGE);
	status = erx_trb_form_install(&record->trb.form, record->trb.reaches_64_bits, &ring_sequence);
	if (status != ERX_OK)
		return (status == ERX_ERANGE ? ERX_ERANGE : ERX_EINVAL);
	record->memory = device->dma + carve.rings;
	record->memory_size = carve.end - carve.rings;
	record->device_base = base;
	*taken = carve.end;
	*made = &queues[queues_open++];
	return (ERX_OK);
}

/* Entry `entry`'s register `name` of the device's MSI-X table, and its byte offset in the window. */
static bool
msix_element(const erx_device_t *device, const char *name, uint32_t entry, xhci_reg_t *out)
{
	const erx_device_peripheral_t *const table = device->msix_table;
	const uint32_t found = erx_device_register_named(table, name);

	if (found == table->register_count)
		return (false);
	out->reg = &table->registers[found];
	return (erx_device_element_offset(out->reg, true, entry, &out->offset) &&
	    !__builtin_add_overflow(out->offset, device->msix.offset, &out->offset));
}

/* Entry `entry`'s field `field` of register `name`, written as `value` (field_word). */
static bool
msix_put(const erx_device_t *device, const char *name, const char *field, uint32_t entry, uint64_t value)
{
	xhci_reg_t r;
	xhci_word_t word;
	uint32_t found;

	if (!msix_element(device, name, entry, &r))
		return (false);
	found = erx_device_field_named(device->msix_table, r.reg, field);
	if (found == r.reg->field_count ||
	    !field_word(device, r, &device->msix_table->fields[r.reg->first_field + found], value, &word))
		return (false);
	store(device, word.r.reg, word.r.offset, word.word);
	return (true);
}

/*
 * The function's MSI-X table written whole, after the driver's reset (docs/design-pcie.md, "Who
 * programs what, and when"): entry 0 the route's message, unmasked, and every other entry of
 * the route's masked, as FreeBSD masks every entry before it enables MSI-X (pci.c:1941-1947);
 * then entry 0's data read back, which returns only once the writes before it have reached
 * the function (the PCIe ordering rule, unverified), and must be what was written. ERX_OK for
 * a device with no MSI-X route; ERX_EINVAL for a read that differs.
 */
static int
msix_install(const erx_device_t *device)
{
	xhci_reg_t data;
	uint64_t word, value;

	if (device->msix_table == NULL)
		return (ERX_OK);
	if (!msix_put(device, "address_lo", "address", 0, device->msix.address & UINT32_MAX) ||
	    !msix_put(device, "address_hi", "address", 0, device->msix.address >> 32) ||
	    !msix_put(device, "data", "data", 0, device->msix.data) ||
	    !msix_put(device, "vector_control", "mask", 0, 0))
		return (ERX_EINVAL);
	for (uint32_t entry = 1; entry < device->msix.entries; entry++) {
		if (!msix_put(device, "vector_control", "mask", entry, 1))
			return (ERX_EINVAL);
	}
	if (!msix_element(device, "data", 0, &data))
		return (ERX_EINVAL);
	word = load(device, data.reg, data.offset);
	return (erx_device_field_of(data.reg, (erx_device_element_t){ .indexed = true, .index = 0 },
	    &device->msix_table->fields[data.reg->first_field], word, &value) && value == device->msix.data ?
	    ERX_OK : ERX_EINVAL);
}

/*
 * The install, once the reset has ended: the reset's idle report ends every holding, then the
 * form's sequence (erx_device_sequencer.h), its registers composed whole first, so a write the
 * table cannot state, a bug, applies nothing; then its memory, then its registers in order, run
 * last. ERX_ERANGE or ERX_EINVAL as erx_trb_form_install refuses.
 */
static int
trb_ring_install(queue_record_t *record)
{
	const erx_device_t *const device = record->device;
	trb_ring_t *const ring = &record->trb;
	xhci_word_t words[2u * (ERX_DMA_REGISTERS_MAX + 1u)];
	uint32_t count = 0;
	int status;

	erx_trb_form_reset(&ring->form);
	status = erx_trb_form_install(&ring->form, ring->reaches_64_bits, &ring_sequence);
	if (status != ERX_OK)
		return (status == ERX_ERANGE ? ERX_ERANGE : ERX_EINVAL);
	if (ring_sequence.activation.kind != ERX_DMA_ACTIVATE_REGISTER)
		return (ERX_EINVAL);
	for (uint32_t at = 0; at <= ring_sequence.register_count; at++) {
		const erx_dma_register_write_t write = at < ring_sequence.register_count ? ring_sequence.registers[at] :
		    ring_sequence.activation.reg;

		if (!install_words(device, &ring->regs, write, words, &count))
			return (ERX_EINVAL);
	}
	apply_memory(record, &ring_sequence, NULL);
	for (uint32_t at = 0; at < count; at++)
		store(device, words[at].r.reg, words[at].r.offset, words[at].word);
	return (ERX_OK);
}

/* The call's one reading of the controller, USBCMD's and USBSTS's words taken apart by the table's fields. */
static bool
start_seen(const erx_device_t *device, const xhci_registers_t *regs, erx_trb_start_seen_t *seen)
{
	const uint64_t command = load(device, regs->usbcmd.reg, regs->usbcmd.offset);
	const uint64_t status = load(device, regs->usbsts.reg, regs->usbsts.offset);
	uint64_t running, halted, resetting, not_ready;

	if (!xhci_field_of(regs->usbcmd, regs->rs, command, &running) ||
	    !xhci_field_of(regs->usbsts, regs->hch, status, &halted) ||
	    !xhci_field_of(regs->usbcmd, regs->hcrst, command, &resetting) ||
	    !xhci_field_of(regs->usbsts, regs->cnr, status, &not_ready))
		return (false);
	*seen = (erx_trb_start_seen_t){ .running = running != 0, .halted = halted != 0, .resetting = resetting != 0,
	    .not_ready = not_ready != 0 };
	return (true);
}

/* USBCMD's `field` written as `value`, its other kept bits as read (field_word). */
static bool
command_put(const erx_device_t *device, const xhci_registers_t *regs, const erx_device_field_t *field, uint64_t value)
{
	xhci_word_t word;

	if (!field_word(device, regs->usbcmd, field, value, &word))
		return (false);
	store(device, word.r.reg, word.r.offset, word.word);
	return (true);
}

/*
 * negotiate/2 on an xHCI device (docs/design-usb.md, "Install"): its record made by the first
 * call, then one step of the controller's reset and start a call, as erx_trb_form_start_next
 * decides from the call's one reading and whether the call `continues` the negotiation or
 * begins one. ERX_EBUSY until the controller has started, but ERX_DEVICE_RESET_DONE from the call
 * that ends its reset and writes its MSI-X table; ERX_OK, with no feature accepted, once it has
 * started, and the record is ready. A refused install ends the negotiation with its error and the
 * record goes back to the first step.
 */
static int
trb_ring_negotiate(const erx_device_t *device, bool continues, uint64_t *accepted)
{
	queue_record_t *record = queue_numbered(device, 0);
	erx_trb_start_seen_t seen;
	erx_trb_start_next_t next;
	trb_ring_t *ring;
	int status = ERX_OK;

	if (record == NULL) {
		status = trb_ring_create(device, &record);
		if (status != ERX_OK)
			return (status);
	}
	ring = &record->trb;
	if (!start_seen(device, &ring->regs, &seen))
		return (ERX_EINVAL);
	next = erx_trb_form_start_next(ring->step, continues, seen);
	switch (next.effect) {
	case ERX_TRB_START_NOTHING:
		break;
	case ERX_TRB_START_CLEAR_RUN:
		status = command_put(device, &ring->regs, ring->regs.rs, 0) ? ERX_OK : ERX_EINVAL;
		break;
	case ERX_TRB_START_RESET:
		status = command_put(device, &ring->regs, ring->regs.hcrst, 1) ? ERX_OK : ERX_EINVAL;
		break;
	case ERX_TRB_START_ROUTE:
		status = msix_install(device);
		break;
	case ERX_TRB_START_INSTALL:
		status = trb_ring_install(record);
		break;
	}
	ring->step = status == ERX_OK ? next.step : ERX_TRB_START_BEGIN;
	if (status != ERX_OK)
		return (status);
	if (next.answer == ERX_TRB_START_BUSY)
		return (ERX_EBUSY);
	if (next.answer == ERX_TRB_START_RESET_DONE)
		return (ERX_DEVICE_RESET_DONE);
	record->ready = true;
	*accepted = 0;
	return (ERX_OK);
}

int
erx_device_negotiate(const erx_device_t *device, uint64_t wanted, bool continues, uint64_t *accepted)
{
	if (trb_ring_device(device)) {
		unready_queues(device);
		return (trb_ring_negotiate(device, continues, accepted));
	}
	if (continues)
		return (ERX_EINVAL);	/* the other forms take no steps; refused before a queue is touched */
	unready_queues(device);
	if (register_ring_device(device))
		return (register_ring_negotiate(device, accepted));
	return (split_ring_negotiate(device, wanted, accepted));
}

/* The queues stop being ready first, as at a negotiation's start, even when the record lacks one. */
int
erx_device_stop_register_ring(const erx_device_t *device)
{
	queue_record_t *rings[2];
	uint64_t status[2];

	if (!register_ring_device(device))
		return (ERX_ENOTSUP);
	unready_queues(device);
	if (!register_ring_queues(device, rings))
		return (ERX_EINVAL);
	return (register_ring_stop(device, rings, status));
}

/*
 * The TRB form's posts, completions and queue states (docs/design-usb.md, "The TRB ring form"):
 * the form's core decides every TRB, every answer and every state; what follows applies its
 * sequences, rings the doorbells and reads the event ring for it.
 */

/* The answers of one completion, too large for a scheduler's stack; used only under the caller's lock. */
static erx_trb_answer_t trb_answers[ERX_TRB_FORM_ANSWERS_MAX(ERX_DEVICE_COMPLETE_ENTRIES)];

/*
 * The device's xHCI record, started and whole, into `*made`: ERX_EINVAL for a device that is not
 * an xHCI controller or has no record yet; ERX_ECORRUPT for one whose negotiation has not
 * succeeded since its open or its last negotiation began, or whose form an event broke.
 */
static int
trb_record(const erx_device_t *device, queue_record_t **made)
{
	queue_record_t *const record = trb_ring_device(device) ? queue_numbered(device, 0) : NULL;

	if (record == NULL)
		return (ERX_EINVAL);
	if (!record->ready || erx_trb_form_broken(&record->trb.form))
		return (ERX_ECORRUPT);
	*made = record;
	return (ERX_OK);
}

/*
 * Doorbell `doorbell`'s place and the word that rings it for `target` (xHCI 1.2, 5.6, Table 5-43,
 * pp. 430-431): the target in its field, stream ID 0. False for a doorbell the controller lacks.
 */
static bool
doorbell_word(const queue_record_t *record, uint32_t doorbell, uint32_t target, xhci_word_t *out)
{
	const xhci_registers_t *const regs = &record->trb.regs;

	out->r.reg = regs->db;
	out->word = 0;
	return (element_at(record->device, regs->db, (erx_device_element_t){ .indexed = true, .index = doorbell },
	    &out->r.offset) && with_field(regs->db_target, target, &out->word));
}

/*
 * A run the form's core accepted, in erx_device_sequencer.h's order: its memory, an out transfer's
 * bytes from `piece` into its fill, then its activation, the first TRB's cycle bit, then the
 * doorbell, the one store the controller's fetch waits for on an idle ring.
 */
static void
trb_ring_run(const queue_record_t *record, const erx_dma_piece_t *piece, xhci_word_t doorbell)
{
	apply_memory(record, &ring_sequence, piece);
	apply_activation(record, &ring_sequence.activation);
	store(record->device, doorbell.r.reg, doorbell.r.offset, doorbell.word);
}

int
erx_device_trb_post(const erx_device_t *device, uint32_t slot, uint32_t dci, uint64_t tag,
    const erx_device_trb_request_t *request, erx_device_trb_verdict_t *verdict)
{
	const erx_dma_piece_t piece = { .bytes = request->bytes, .length = request->length };
	queue_record_t *record;
	xhci_word_t doorbell;
	const int status = trb_record(device, &record);

	if (status != ERX_OK)
		return (status);
	/* Slot n's doorbell rings endpoint `dci`; a slot past the doorbells names no queue. */
	if (!doorbell_word(record, slot, dci, &doorbell))
		*verdict = ERX_DEVICE_TRB_REFUSE_BADARG;
	else
		*verdict = erx_trb_form_post(&record->trb.form, slot, dci, request, tag, &ring_sequence);
	if (*verdict == ERX_DEVICE_TRB_ACCEPTED)
		trb_ring_run(record, &piece, doorbell);
	return (ERX_OK);
}

int
erx_device_trb_command(const erx_device_t *device, const erx_trb_command_t *command, uint64_t tag,
    erx_device_trb_verdict_t *verdict)
{
	queue_record_t *record;
	xhci_word_t doorbell;
	erx_trb_command_t chosen;
	const int status = trb_record(device, &record);

	if (status != ERX_OK)
		return (status);
	/* Doorbell 0, target 0: the command ring's (5.6, Table 5-44, p. 431). */
	if (!doorbell_word(record, 0, 0, &doorbell))
		return (ERX_EINVAL);
	chosen = *command;
	*verdict = erx_trb_form_choose_blocks(&record->trb.form, &chosen);
	if (*verdict == ERX_DEVICE_TRB_ACCEPTED)
		*verdict = erx_trb_form_command(&record->trb.form, &chosen, tag, &ring_sequence);
	if (*verdict == ERX_DEVICE_TRB_ACCEPTED)
		trb_ring_run(record, NULL, doorbell);
	return (ERX_OK);
}

/*
 * The acquisition's first phase: the cycle word of each of the next ERX_DEVICE_COMPLETE_ENTRIES
 * events, each line invalidated first on a device that is not coherent, read before any event is
 * (the report barrier); the core counts the leading ones the controller has written.
 */
static int
trb_ring_acquire(queue_record_t *record, uint32_t *count)
{
	erx_trb_form_t *const form = &record->trb.form;
	erx_dma_range_t places[ERX_DEVICE_COMPLETE_ENTRIES];
	uint32_t words[ERX_DEVICE_COMPLETE_ENTRIES], seen = 0;
	bool maintained = false;

	for (; seen < ERX_DEVICE_COMPLETE_ENTRIES; seen++) {
		places[seen] = erx_trb_form_validity_word(form, seen);
		if (places[seen].length == 0)
			break;
		maintained |= maintain(record, places[seen], true);
	}
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t k = 0; k < seen; k++)
		words[k] = (uint32_t)load_field(record->memory + places[k].offset, (uint32_t)places[k].length);
	erx_dma_report_barrier();
	return (erx_trb_form_acquire(form, words, seen, count));
}

/*
 * ERDP at the event ring's consumer position `dequeue`, low word then high, with its busy bit
 * written 1, which clears it (xHCI 1.2, 5.5.2.3.3, p. 429): the controller then raises the next
 * interrupt. ERX_EINVAL for a position the table cannot state, a bug of the form's core.
 */
static int
trb_ring_dequeue(const queue_record_t *record, uint64_t dequeue)
{
	const xhci_registers_t *const regs = &record->trb.regs;
	xhci_word_t words[2];

	if (!address_words(record->device, regs->erdp, regs->erdp_field, dequeue, 0, words) ||
	    !with_field(regs->ehb, 1, &words[0].word))
		return (ERX_EINVAL);
	for (uint32_t at = 0; at < 2; at++)
		store(record->device, words[at].r.reg, words[at].r.offset, words[at].word);
	return (ERX_OK);
}

int
erx_device_trb_complete(const erx_device_t *device, erx_device_trb_sink_t *sink, void *context, uint32_t *answered)
{
	queue_record_t *record;
	erx_trb_form_t *form;
	uint32_t count, done;
	uint64_t dequeue;
	bool maintained = false;
	int status = trb_record(device, &record);

	*answered = 0;
	if (status != ERX_OK)
		return (status);
	form = &record->trb.form;
	status = trb_ring_acquire(record, &count);
	if (status != ERX_OK)
		return (status);
	/* The second phase: each acquired event invalidated again and read whole, before the core reads any. */
	for (uint32_t k = 0; k < count; k++)
		maintained |= maintain(record, erx_trb_form_event(form, k), true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t event = erx_trb_form_event(form, k);

		bcopy((const void *)(uintptr_t)(record->memory + event.offset), &ring_elements[k], event.length);
	}
	erx_dma_report_barrier();
	status = erx_trb_form_complete(form, ring_elements, count, trb_answers, &done, &dequeue, &ring_sequence);
	/* What the consumed events left to apply, a disabled slot's DCBAA entry cleared, before any answer is given. */
	if (ring_sequence.clean_count != 0)
		apply_memory(record, &ring_sequence, NULL);
	/* ERDP moves past what the core consumed even when an event broke the form, so the controller is never left behind it. */
	if (trb_ring_dequeue(record, dequeue) != ERX_OK)
		return (ERX_EINVAL);
	if (status != ERX_OK)
		return (status);
	/* Each answer in the core's order, a transfer's bytes from its buffer, which its release returned. */
	maintained = false;
	for (uint32_t at = 0; at < done; at++)
		maintained |= maintain(record, trb_answers[at].data, true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t at = 0; at < done; at++) {
		const erx_dma_range_t data = trb_answers[at].data;
		uint8_t *const into = sink(context, &trb_answers[at]);

		if (data.length != 0)
			bcopy((const void *)(uintptr_t)(record->memory + data.offset), into, data.length);
	}
	*answered = done;
	return (ERX_OK);
}

int
erx_device_trb_queue_state(const erx_device_t *device, uint32_t slot, uint32_t dci, erx_trb_queue_state_t *state)
{
	queue_record_t *record;
	const int status = trb_record(device, &record);

	if (status != ERX_OK)
		return (status);
	*state = erx_trb_form_queue_state(&record->trb.form, slot, dci);
	return (ERX_OK);
}

static queue_record_t *
queue_of(const erx_device_t *device, uint32_t queue)
{
	return (queue < queues_open && queues[queue].device == device && queues[queue].form != QUEUE_TRB_RING ?
	    &queues[queue] : NULL);
}

/*
 * A post's pieces as the forms take them. A region piece names the region alone: the split
 * ring's core writes its entry from the device's region table, so the device learns a region's
 * address only from the NIF, and only for its own device's region.
 */
static void
form_pieces(const erx_device_piece_t *requested, uint32_t count, erx_dma_piece_t *pieces)
{
	for (uint32_t step = 0; step < count; step++)
		pieces[step] = (erx_dma_piece_t){ .bytes = requested[step].data, .length = requested[step].length,
		    .device_writes = requested[step].device_writes, .names_region = requested[step].names_region,
		    .region = requested[step].region };
}

/* A split ring's post: the core's sequence, applied whole, or its refusal with nothing applied. */
static int
split_ring_post(queue_record_t *record, uint64_t tag, const erx_dma_piece_t *pieces, uint32_t count)
{
	const int status = erx_split_ring_post(&record->split.ring, pieces, count, tag, &ring_sequence);

	if (status == ERX_OK)
		apply_sequence(record, &ring_sequence, pieces);
	return (status);
}

int
erx_device_post(const erx_device_t *device, uint32_t queue, uint64_t tag, const erx_device_piece_t *requested,
    uint32_t count)
{
	queue_record_t *const record = queue_of(device, queue);
	erx_dma_piece_t pieces[ERX_DEVICE_CHAIN_MAX];
	erx_dma_request_t request;

	if (record == NULL || count == 0 || count > ERX_DEVICE_CHAIN_MAX)
		return (ERX_EINVAL);
	form_pieces(requested, count, pieces);
	if (record->form == QUEUE_SPLIT_RING)
		return (record->ready ? split_ring_post(record, tag, pieces, count) : ERX_ECORRUPT);
	request = queue_request(record, ERX_DMA_REQUEST_POST);
	request.tag = tag;
	request.count = count;
	request.pieces = pieces;
	return (run_call(record, &request, NULL, NULL, NULL, NULL));
}

/*
 * A split ring's completion: on a device that is not coherent, each structure the device wrote
 * invalidated before it is read. The used index is loaded once and the core acquires what it
 * covers; each element is read whole and the core completes them; then each answer's written
 * range is copied to what the sink gives for its tag.
 */
static int
split_ring_complete(queue_record_t *record, erx_device_sink_t *sink, void *context, uint32_t *completed)
{
	erx_split_ring_t *const ring = &record->split.ring;
	const erx_dma_layout_t *const layout = split_layout(record);
	const erx_dma_table_t *const used =
	    &layout->tables[erx_dma_ledger_table(erx_split_ring_ledger(ring), ERX_STRUCTURE_VIRTQ_USED)];
	const erx_dma_range_t index_at = { used->region + offsetof(erx_virtq_ring_head_t, idx), sizeof(uint16_t) };
	uint32_t count, done;
	bool maintained;
	int status;

	if (maintain(record, index_at, true))
		erx_dma_completion_barrier();
	status = erx_split_ring_acquire(ring, (uint16_t)load_field(record->memory + index_at.offset, sizeof(uint16_t)),
	    ERX_DEVICE_COMPLETE_ENTRIES, &count);
	erx_dma_report_barrier();
	if (status != ERX_OK)
		return (status);
	maintained = false;
	for (uint32_t k = 0; k < count; k++)
		maintained |= maintain(record, erx_split_ring_element(ring, k), true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t k = 0; k < count; k++) {
		const erx_dma_range_t element = erx_split_ring_element(ring, k);

		bcopy((const void *)(uintptr_t)(record->memory + element.offset), ring_elements[k].bytes, element.length);
	}
	erx_dma_report_barrier();
	status = erx_split_ring_complete(ring, ring_elements, count, ERX_DEVICE_COMPLETE_BYTES, ring_answers, &done);
	if (status != ERX_OK)
		return (status);
	maintained = false;
	for (uint32_t at = 0; at < done; at++)
		maintained |= maintain(record, ring_answers[at].written, true);
	if (maintained)
		erx_dma_completion_barrier();
	for (uint32_t at = 0; at < done; at++) {
		const erx_dma_range_t written = ring_answers[at].written;
		uint8_t *const into = sink(context, ring_answers[at].tag, (uint32_t)written.length);

		if (written.length != 0)
			bcopy((const void *)(uintptr_t)(record->memory + written.offset), into, written.length);
	}
	*completed = done;
	return (ERX_OK);
}

int
erx_device_complete(const erx_device_t *device, uint32_t queue, erx_device_sink_t *sink, void *context,
    uint32_t *completed)
{
	queue_record_t *const record = queue_of(device, queue);
	erx_dma_request_t request;

	*completed = 0;
	if (record == NULL)
		return (ERX_EINVAL);
	if (record->form == QUEUE_SPLIT_RING)
		return (record->ready ? split_ring_complete(record, sink, context, completed) : ERX_ECORRUPT);
	if (!record->ready || queue_broken(record))
		return (ERX_ECORRUPT);
	request = queue_request(record, ERX_DMA_REQUEST_COMPLETE);
	request.answers_max = ERX_DEVICE_COMPLETE_ENTRIES;
	request.bytes_max = ERX_DEVICE_COMPLETE_BYTES;
	return (run_call(record, &request, sink, context, completed, NULL));
}

#ifdef ERX_DEVICE_STAND_IN
/*
 * The stand-in's device writes the used ring as any device may, honest or not; only the
 * driver side, erx_device_complete, judges what it wrote. The device's own count of what it
 * consumed is the used index, so the next available head is the one at that position.
 */
int
erx_device_stand_in_used(const erx_device_t *device, uint32_t queue, const erx_device_used_entry_t *entries,
    uint32_t count)
{
	const queue_record_t *const record = queue_of(device, queue);
	const erx_dma_ledger_t *ledger;
	const erx_dma_table_t *avail, *used_table;
	volatile erx_virtq_ring_head_t *used;
	volatile erx_virtq_used_elem_t *elems;
	volatile const uint16_t *avail_ring;
	uint32_t mask;
	uint16_t idx;

	if (record == NULL || device->form != ERX_DEVICE_FORM_STAND_IN || record->form != QUEUE_SPLIT_RING ||
	    !record->ready || count > split_layout(record)->pools[0].count)
		return (ERX_EINVAL);
	/* The device finds its rings where the install's registers put them: the core's layout. */
	ledger = erx_split_ring_ledger(&record->split.ring);
	avail = &split_layout(record)->tables[erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_AVAIL)];
	used_table = &split_layout(record)->tables[erx_dma_ledger_table(ledger, ERX_STRUCTURE_VIRTQ_USED)];
	mask = used_table->count - 1;
	used = (volatile erx_virtq_ring_head_t *)(record->memory + used_table->region);
	elems = (volatile erx_virtq_used_elem_t *)(record->memory + used_table->first);
	avail_ring = (volatile const uint16_t *)(record->memory + avail->first);
	idx = used->idx;
	for (uint32_t entry = 0; entry < count; entry++) {
		const uint32_t slot = (uint32_t)(idx + entry) & mask;

		elems[slot].id = entries[entry].next ? avail_ring[slot] : entries[entry].id;
		elems[slot].len = entries[entry].length;
	}
	atomic_thread_fence(memory_order_release);
	used->idx = (uint16_t)(idx + count);
	return (ERX_OK);
}

/*
 * The stand-in GENET's engines, run when a test asks, under the caller's lock as every queue
 * call is: erx_device_genet_model's, over the window and the installed ring's memory. The
 * model reaches each buffer through the address its descriptor holds, found in the record's
 * memory by the record's device base; it is never derived from the NIF's bookkeeping, so a
 * wrong published address shows as a refused or misplaced frame.
 */

/* The installed register ring of a stand-in GENET in one direction, or NULL. */
static const queue_record_t *
stand_in_genet_ring(const erx_device_t *device, uint32_t index)
{
	for (uint32_t at = 0; device->form == ERX_DEVICE_FORM_STAND_IN && at < queues_open; at++) {
		const queue_record_t *const record = &queues[at];

		if (record->device == device && record->form == QUEUE_REGISTER_RING && record->index == index &&
		    record->ready)
			return (record);
	}
	return (NULL);
}

/* The `length` bytes at device address `addr` in the record's memory, or NULL when they are not all in it. */
static volatile uint8_t *
stand_in_genet_bytes(const queue_record_t *record, uint64_t addr, uint32_t length)
{
	if (addr < record->device_base || addr - record->device_base > record->memory_size ||
	    length > record->memory_size - (addr - record->device_base))
		return (NULL);
	return (record->memory + (addr - record->device_base));
}

static bool
stand_in_genet_read(void *context, uint64_t addr, uint8_t *bytes, uint32_t length)
{
	volatile uint8_t *const from = stand_in_genet_bytes(context, addr, length);

	if (from == NULL)
		return (false);
	if (length != 0)
		bcopy((const void *)(uintptr_t)from, bytes, length);
	return (true);
}

static bool
stand_in_genet_write(void *context, uint64_t addr, const uint8_t *bytes, uint32_t length)
{
	volatile uint8_t *const to = stand_in_genet_bytes(context, addr, length);

	if (to == NULL)
		return (false);
	if (length != 0)
		bcopy(bytes, (void *)(uintptr_t)to, length);
	return (true);
}

/* The model's device memory: the ring's queue memory, which the stand-in's DMA reaches by device address. */
static erx_device_genet_memory_t
stand_in_genet_memory(const queue_record_t *record)
{
	return ((erx_device_genet_memory_t){ .context = (void *)(uintptr_t)record, .read = stand_in_genet_read,
	    .write = stand_in_genet_write });
}

int
erx_device_stand_in_transmitted(const erx_device_t *device, erx_device_sink_t *sink, void *context, uint32_t *sent)
{
	const queue_record_t *const record = stand_in_genet_ring(device, GENET_QUEUE_TX);
	erx_device_genet_model_t genet;
	erx_device_genet_memory_t memory;

	*sent = 0;
	if (record == NULL || !stand_in_genet_model(device, &genet))
		return (ERX_EINVAL);
	memory = stand_in_genet_memory(record);
	return (erx_device_genet_model_transmit(&genet, &memory, sink, context, sent));
}

int
erx_device_stand_in_receive(const erx_device_t *device, const erx_device_frame_t *frames, uint32_t count,
    uint32_t *taken)
{
	const queue_record_t *const record = stand_in_genet_ring(device, GENET_QUEUE_RX);
	const erx_device_register_t *rbuf_ctrl;
	const erx_device_field_t *align, *status_block;
	erx_device_genet_model_t genet;
	erx_device_genet_memory_t memory;
	uint32_t control, pad, reach;
	bool aligned, took;

	*taken = 0;
	if (record == NULL || !stand_in_genet_model(device, &genet) ||
	    (rbuf_ctrl = plain_register(device, "rbuf_ctrl")) == NULL ||
	    (align = stand_in_field(device, rbuf_ctrl, "align_2b")) == NULL ||
	    (status_block = stand_in_field(device, rbuf_ctrl, "status_64b")) == NULL)
		return (ERX_EINVAL);
	control = erx_device_access_load32(device->windows[0], rbuf_ctrl->offset);
	/* The stand-in lays out no 64-byte status block, so it takes nothing while one is asked for. */
	if ((control & status_block->mask) != 0)
		return (ERX_EINVAL);
	/* ALIGN_2B: two bytes of padding before each frame, which the length counts. */
	aligned = (control & align->mask) != 0;
	pad = aligned ? 2u : 0u;
	/* Every frame fits its buffer, or none is taken. */
	reach = erx_device_genet_model_buffer_bytes(&genet, ERX_DEVICE_GENET_RX);
	for (uint32_t frame = 0; frame < count; frame++) {
		if (reach < pad || frames[frame].length > reach - pad)
			return (ERX_EINVAL);
	}
	memory = stand_in_genet_memory(record);
	for (; *taken < count; (*taken)++) {
		const erx_device_genet_model_frame_t frame = { .bytes = frames[*taken].bytes,
		    .written = frames[*taken].length, .length = frames[*taken].length, .aligned = aligned,
		    .flags = genet.regs[ERX_DEVICE_GENET_RX].sop | genet.regs[ERX_DEVICE_GENET_RX].eop };
		const int status = erx_device_genet_model_receive(&genet, &memory, &frame, &took);

		/* A stopped engine or a full ring is no fault: the rest wait for buffers the driver hands back. */
		if (status != ERX_OK || !took)
			return (status);
	}
	return (ERX_OK);
}
#endif
