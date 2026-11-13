/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * erx_device's core and effects on the host (test/host/erx_device_test.rb), over the table
 * the generator made, with the kernel calls replaced by what can fail on request: every
 * register and field of the peripheral against each boundary value, then what the peripheral
 * itself asks for. Built with -DERX_DEVICE_FIXTURE, the peripheral is
 * test/fixtures/device_table_fixture.svd's; otherwise it is the PL011.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "liberx/backend/api.h"
#include "liberx/backend/core/device_check.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define WINDOW_BYTES	4096u
/* The PL011's register block as hw/svd/pl011/pl011.svd describes it: up to DMACR,
 * the BCM2711's spacing of its UARTs. */
#define PL011_BLOCK_BYTES	0x200u
#define KEY_BASE	100u

static const erx_device_element_t plain = { .indexed = false };

static _Alignas(8) uint8_t window_memory[ERX_DEVICE_MAX + 1][WINDOW_BYTES];
static uint32_t next_window;
static uint64_t last_physical_base, last_physical_size;
static int fail_physical, fail_reserve, fail_map, fail_irq;
static uint32_t irq_created, physical_created;
/* The lines the fake kernel has made an IRQ object for; as the kernel, it refuses a second. */
static uint64_t lines_made[ERX_DEVICE_MAX * ERX_DEVICE_LINES_MAX];

int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	(void)budget;
	(void)resource;
	/* Both backends refuse what the kernel interface refuses: anything but whole pages. */
	CHECK(erx_backend_physical_check(base, size, attr) == ERX_OK);
	if (fail_physical == ERX_OK)
		physical_created++;
	last_physical_base = base;
	last_physical_size = size;
	*mem = base;
	return (fail_physical);
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	(void)addr;
	(void)flags;
	CHECK(space == ERX_CAP_SELF && size <= WINDOW_BYTES && size % ERX_PAGE_SIZE == 0);
	*reserved = (uint64_t)(uintptr_t)window_memory[next_window];
	return (fail_reserve);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	(void)mem;
	CHECK(space == ERX_CAP_SELF && addr == (uint64_t)(uintptr_t)window_memory[next_window] && size <= WINDOW_BYTES &&
	    offset == 0 && prot == ERX_PROT_RW);
	if (fail_map != ERX_OK)
		return (fail_map);
	next_window++;
	return (ERX_OK);
}

/* Queues are test/fixtures/erx_device_dma_harness.c's; here no contiguous memory exists. */
int
erx_mem_create_contiguous(uint64_t budget, uint64_t resource, uint64_t size, uint64_t limit, uint64_t *mem)
{
	(void)budget;
	(void)resource;
	(void)size;
	(void)limit;
	(void)mem;
	return (ERX_ENOTSUP);
}

int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	(void)mem;
	(void)offset;
	(void)addr;
	return (ERX_EINVAL);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	(void)budget;
	(void)resource;
	CHECK(kind == ERX_IRQ_LINE || kind == ERX_IRQ_SOFT);
	if (fail_irq != ERX_OK)
		return (fail_irq);
	for (uint32_t at = 0; kind == ERX_IRQ_LINE && at < irq_created; at++) {
		if (lines_made[at] == selector)
			return (ERX_EBUSY);
	}
	CHECK(irq_created < ERX_DEVICE_MAX * ERX_DEVICE_LINES_MAX);
	lines_made[irq_created] = selector;
	*irq = selector + 1000u * ++irq_created;
	return (ERX_OK);
}

static const erx_device_field_t *
field_of(const erx_device_peripheral_t *peripheral, const erx_device_register_t *reg, const char *name)
{
	const uint32_t index = erx_device_field_named(peripheral, reg, name);

	CHECK(index < reg->field_count);
	return (&peripheral->fields[reg->first_field + index]);
}

static const erx_device_register_t *
register_of(const erx_device_peripheral_t *peripheral, const char *name)
{
	const uint32_t index = erx_device_register_named(peripheral, name);

	CHECK(index < peripheral->register_count);
	return (&peripheral->registers[index]);
}

static uint64_t
width_mask(const erx_device_register_t *reg)
{
	return (reg->width == 64 ? UINT64_MAX : (UINT64_C(1) << reg->width) - 1);
}

/* What holds of any field for any value. */
static void
check_field_value(const erx_device_register_t *reg, const erx_device_field_t *field, uint64_t value)
{
	const uint64_t limit = field->mask >> field->shift;
	const erx_device_field_plan_t plan = erx_device_field_plan(reg, field, value);
	const uint64_t words[] = { 0, UINT64_MAX & width_mask(reg), reg->writable };

	if (value > limit || reg->owned_by_nif || field->access == ERX_DEVICE_READ_ONLY) {
		CHECK(plan.op == ERX_DEVICE_FIELD_REFUSED);
		return;
	}
	if (field->clear) {
		CHECK(plan.op == ERX_DEVICE_FIELD_WRITE && plan.keep == 0);
	} else if (!reg->plain_update) {
		CHECK(plan.op == ERX_DEVICE_FIELD_REFUSED);
		return;
	} else {
		CHECK(plan.op == ERX_DEVICE_FIELD_UPDATE && (plan.keep & field->mask) == 0 && (plan.keep & ~reg->writable) == 0);
	}
	CHECK((plan.bits & ~field->mask) == 0);
	for (size_t index = 0; index < sizeof(words) / sizeof(words[0]); index++) {
		const uint64_t word = erx_device_field_apply(&plan, words[index]);

		CHECK(erx_device_field_get(field, word) == value);
		CHECK((word & ~reg->writable) == 0);
		CHECK(erx_device_write_allowed(reg, word) || reg->owned_by_nif);
	}
}

/* The pure read of a field out of a word: the register's own form of name, and a word its width holds. */
static void
check_field_of(const erx_device_register_t *reg, const erx_device_field_t *field)
{
	const erx_device_element_t right = { .indexed = reg->count > 1, .index = 0 };
	const erx_device_element_t wrong = { .indexed = reg->count == 1, .index = 0 };
	const erx_device_element_t beyond = { .indexed = true, .index = reg->count };
	const bool readable = erx_device_field_read_allowed(reg, field);
	uint64_t value = 0;

	CHECK(erx_device_field_of(reg, right, field, field->mask, &value) == readable);
	CHECK(!readable || value == field->mask >> field->shift);
	CHECK(!erx_device_field_of(reg, wrong, field, field->mask, &value));
	CHECK(!erx_device_field_of(reg, beyond, field, field->mask, &value));
	if (reg->width < 64)
		CHECK(!erx_device_field_of(reg, right, field, UINT64_C(1) << reg->width, &value));
}

/* Every register and every field of the table, at each boundary of its width. */
static void
check_every_entry(const erx_device_peripheral_t *peripheral)
{
	for (uint32_t index = 0; index < peripheral->register_count; index++) {
		const erx_device_register_t *const reg = &peripheral->registers[index];
		uint64_t ignored;

		CHECK(erx_device_register_named(peripheral, reg->name) == index);
		CHECK(reg->width == 32 || reg->width == 64);
		CHECK((reg->writable & ~width_mask(reg)) == 0);
		CHECK(reg->offset + (uint64_t)(reg->count - 1) * reg->stride + reg->width / 8 <= peripheral->window_size);
		CHECK(erx_device_read_allowed(reg) == (reg->access != ERX_DEVICE_WRITE_ONLY));
		CHECK(!erx_device_write_allowed(reg, reg->writable) ==
		    (reg->access == ERX_DEVICE_READ_ONLY || reg->owned_by_nif));
		if (reg->writable != UINT64_MAX)
			CHECK(!erx_device_write_allowed(reg, ~reg->writable));
		CHECK(erx_device_element_offset(reg, reg->count > 1, 0, &ignored));
		CHECK(!erx_device_element_offset(reg, reg->count == 1, 0, &ignored));
		if (reg->count > 1) {
			CHECK(!erx_device_element_offset(reg, true, reg->count, &ignored));
			CHECK(!erx_device_element_offset(reg, true, UINT64_MAX, &ignored));
		}
		for (uint32_t at = 0; at < reg->field_count; at++) {
			const erx_device_field_t *const field = &peripheral->fields[reg->first_field + at];
			const uint64_t limit = field->mask >> field->shift;
			const uint64_t values[] = { 0, 1, limit, limit == UINT64_MAX ? limit : limit + 1, UINT64_MAX };

			CHECK(erx_device_field_named(peripheral, reg, field->name) == at);
			CHECK((field->mask & ~width_mask(reg)) == 0 && field->mask != 0);
			CHECK(erx_device_field_get(field, field->mask) == limit);
			CHECK(erx_device_field_read_allowed(reg, field) ==
			    (reg->access != ERX_DEVICE_WRITE_ONLY && field->access != ERX_DEVICE_WRITE_ONLY));
			for (size_t value = 0; value < sizeof(values) / sizeof(values[0]); value++)
				check_field_value(reg, field, values[value]);
			check_field_of(reg, field);
		}
		CHECK(erx_device_register_named(peripheral, "no_such_name") == peripheral->register_count);
		CHECK(erx_device_field_named(peripheral, reg, "no_such_name") == reg->field_count);
	}
}

static void
check_keys(void)
{
	const uintptr_t keys[] = { 7, 9, 11 };

	CHECK(erx_device_key_find(keys, 3, 9) == 1);
	CHECK(erx_device_key_find(keys, 3, 8) == 3);
	CHECK(erx_device_key_find(keys, 0, 7) == 0);
}

static erx_device_spec_t
spec_of(const char *name, uint64_t base)
{
	const erx_device_spec_t spec = { .peripheral = name, .peripheral_length = strlen(name), .base = base,
	    .size = WINDOW_BYTES, .line_count = 1, .lines = { 33 } };

	return (spec);
}

/* The pages a window's mapping covers: from its first page through its last, nothing past them. */
static void
check_window_pages(void)
{
	erx_device_pages_t pages;

	CHECK(erx_device_window_pages(0x9000000, 0x1000, &pages) && pages.base == 0x9000000 && pages.size == 0x1000 &&
	    pages.offset == 0);
	CHECK(erx_device_window_pages(0xa003e00, 0x200, &pages) && pages.base == 0xa003000 && pages.size == 0x1000 &&
	    pages.offset == 0xe00);
	CHECK(erx_device_window_pages(0xa003fff, 1, &pages) && pages.base == 0xa003000 && pages.size == 0x1000 &&
	    pages.offset == 0xfff);
	CHECK(erx_device_window_pages(0xa003f00, 0x200, &pages) && pages.base == 0xa003000 && pages.size == 0x2000 &&
	    pages.offset == 0xf00);
	CHECK(erx_device_window_pages(0xa003000, 0x1001, &pages) && pages.size == 0x2000);
	CHECK(!erx_device_window_pages(0xa003000, 0, &pages));
	CHECK(!erx_device_window_pages(UINT64_MAX - 0xfff, 0x200, &pages));
	CHECK(!erx_device_window_pages(0x1000, UINT64_MAX, &pages));
	CHECK(erx_device_window_pages(UINT64_MAX - 0x1fff, 0x1000, &pages) && pages.size == 0x1000);

	const erx_device_pages_t one = { .base = 0xa003000, .size = 0x1000 }, next = { .base = 0xa004000, .size = 0x1000 },
	    both = { .base = 0xa003000, .size = 0x2000 };

	CHECK(!erx_device_pages_overlap(&one, &next) && !erx_device_pages_overlap(&next, &one));
	CHECK(erx_device_pages_overlap(&one, &both) && erx_device_pages_overlap(&both, &next));
	CHECK(erx_device_pages_overlap(&one, &one));
}

/*
 * Windows smaller than a page and inside one, as QEMU virt's virtio-mmio slots are: the
 * mapping is the page that holds them, made at the first open in the page and shared by every
 * later record there, and each record's registers are read from its own window's base inside
 * that page. A window whose pages meet the mapped page without being it is refused, and so is
 * a direct line a second record names.
 */
static uint32_t
check_slot(void)
{
	const char *const name = "virtio_mmio";
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(name, strlen(name));
	erx_device_spec_t spec = { .peripheral = name, .peripheral_length = strlen(name), .base = 0x0a003e00,
	    .size = 0x200, .line_count = 1, .lines = { 79 } };
	uint8_t *const page = window_memory[next_window];
	const uint32_t version = 2, legacy = 1;
	uint32_t device = 99, again = 99, second = 99;
	uint64_t value = 0;

	CHECK(peripheral != NULL && peripheral->window_size == 0x200);
	bcopy(&version, page + 0xe00 + register_of(peripheral, "version")->offset, sizeof(version));
	bcopy(&legacy, page + 0xc00 + register_of(peripheral, "version")->offset, sizeof(legacy));
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_OK);
	CHECK(last_physical_base == 0x0a003000 && last_physical_size == ERX_PAGE_SIZE);
	CHECK(erx_device_read(erx_device_get(device), register_of(peripheral, "version"), plain, &value) && value == 2);
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_OK && again == device);

	const uint32_t made = physical_created, mapped = next_window;

	spec.base = 0x0a003c00;
	spec.lines[0] = 80;
	CHECK(erx_device_open(&spec, NULL, NULL, &second) == ERX_OK && second == device + 1);
	CHECK(physical_created == made && next_window == mapped);
	CHECK(erx_device_read(erx_device_get(second), register_of(peripheral, "version"), plain, &value) && value == 1);
	CHECK(erx_device_read(erx_device_get(device), register_of(peripheral, "version"), plain, &value) && value == 2);
	spec.base = 0x0a003a00;
	spec.lines[0] = 79;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	spec.lines[0] = 81;
	spec.base = 0x0a003d00;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	spec.base = 0x0a002f00;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	spec.base = 0x0a005e02;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EINVAL);
	spec.base = 0x0a003e00;
	spec.size = 0x400;
	spec.lines[0] = 79;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	CHECK(physical_created == made && next_window == mapped && erx_device_get(second + 1) == NULL);
	return (second);
}

/*
 * Two records on pages of their own that name one shared line hold one IRQ object, as the
 * kernel makes only one per line. A record that calls that line direct, or a direct line of
 * another record shared, is refused before anything is made.
 */
static uint32_t
check_shared_line(const char *name)
{
	erx_device_spec_t first = spec_of(name, 0x9100000), second = spec_of(name, 0x9200000),
	    third = spec_of(name, 0x9300000);
	uint32_t a = 99, b = 99, c = 99;
	uint64_t irq_a, irq_b;

	first.lines[0] = second.lines[0] = 90;
	first.shared[0] = second.shared[0] = true;

	const uint32_t made = irq_created;

	CHECK(erx_device_open(&first, NULL, NULL, &a) == ERX_OK);
	CHECK(erx_device_open(&second, NULL, NULL, &b) == ERX_OK && b == a + 1 && irq_created == made + 1);
	CHECK(erx_device_line_irq(erx_device_get(a), 0, &irq_a) && erx_device_line_irq(erx_device_get(b), 0, &irq_b) &&
	    irq_a == irq_b);

	const uint32_t mapped = physical_created;

	third.lines[0] = 90;
	CHECK(erx_device_open(&third, NULL, NULL, &c) == ERX_EBUSY);
	third.lines[0] = 33;
	third.shared[0] = true;
	CHECK(erx_device_open(&third, NULL, NULL, &c) == ERX_EBUSY);
	third.line_count = 2;
	third.lines[0] = third.lines[1] = 91;
	third.shared[1] = true;
	CHECK(erx_device_open(&third, NULL, NULL, &c) == ERX_EINVAL);
	CHECK(physical_created == mapped && irq_created == made + 1 && erx_device_get(b + 1) == NULL);
	return (b);
}

/*
 * Which bind a line takes follows its record's mark: a driver's bind of a direct line, the
 * owner's of a shared one. A bind through the record the line is bound through moves it;
 * through any other record of the line it is busy. Records naming one line share its entry.
 */
static void
check_binds(uint32_t direct_device, uint32_t shared_device)
{
	const erx_device_t *const direct = erx_device_get(direct_device), *const shared = erx_device_get(shared_device),
	    *const sharer = erx_device_get(shared_device - 1);
	uint32_t entry, sharer_entry, direct_entry;

	CHECK(erx_device_bind_check(direct, 0, ERX_DEVICE_BINDER_DRIVER, NULL, 0) == ERX_DEVICE_BIND_OK);
	CHECK(erx_device_bind_check(direct, 0, ERX_DEVICE_BINDER_OWNER, NULL, 0) == ERX_DEVICE_BIND_DIRECT);
	CHECK(erx_device_bind_check(direct, 0, ERX_DEVICE_BINDER_DRIVER, direct, 0) == ERX_DEVICE_BIND_OK);
	CHECK(erx_device_bind_check(shared, 0, ERX_DEVICE_BINDER_DRIVER, NULL, 0) == ERX_DEVICE_BIND_SHARED);
	CHECK(erx_device_bind_check(shared, 0, ERX_DEVICE_BINDER_OWNER, NULL, 0) == ERX_DEVICE_BIND_OK);
	CHECK(erx_device_bind_check(shared, 0, ERX_DEVICE_BINDER_OWNER, shared, 0) == ERX_DEVICE_BIND_OK);
	CHECK(erx_device_bind_check(shared, 0, ERX_DEVICE_BINDER_OWNER, sharer, 0) == ERX_DEVICE_BIND_BUSY);
	CHECK(erx_device_bind_check(shared, 1, ERX_DEVICE_BINDER_OWNER, NULL, 0) == ERX_DEVICE_BIND_NO_LINE);
	CHECK(erx_device_line_entry(shared, 0, &entry) && erx_device_line_entry(sharer, 0, &sharer_entry) &&
	    erx_device_line_entry(direct, 0, &direct_entry) && !erx_device_line_entry(direct, 1, &direct_entry));
	CHECK(entry == sharer_entry && entry != direct_entry && entry < ERX_DEVICE_LINE_ENTRIES_MAX);
}

#ifndef ERX_DEVICE_FIXTURE
/*
 * Two PL011s 0x200 apart in one page, as the BCM2711's are: one physical object and one
 * mapping, and each record writes and reads back its own registers.
 */
static uint32_t
check_shared_page(void)
{
	const erx_device_peripheral_t *const uart = erx_device_peripheral_find("pl011", 5);
	const erx_device_register_t *const ibrd = register_of(uart, "ibrd");
	erx_device_spec_t first = spec_of("pl011", 0xfe201400), second = spec_of("pl011", 0xfe201600);
	const uint32_t made = physical_created, mapped = next_window;
	uint32_t a = 99, b = 99;
	uint64_t value;

	first.size = second.size = PL011_BLOCK_BYTES;
	first.lines[0] = 153;
	second.lines[0] = 154;
	CHECK(erx_device_open(&first, NULL, NULL, &a) == ERX_OK);
	CHECK(erx_device_open(&second, NULL, NULL, &b) == ERX_OK && b == a + 1);
	CHECK(physical_created == made + 1 && next_window == mapped + 1 && last_physical_base == 0xfe201000);
	CHECK(erx_device_write(erx_device_get(a), ibrd, plain, 26) && erx_device_write(erx_device_get(b), ibrd, plain, 3));
	CHECK(erx_device_read(erx_device_get(a), ibrd, plain, &value) && value == 26);
	CHECK(erx_device_read(erx_device_get(b), ibrd, plain, &value) && value == 3);
	return (b);
}
#endif

/* What open refuses makes nothing visible, and a window already open is that device again. */
static uint32_t
check_open(const char *name, uint64_t block_bytes)
{
	erx_device_spec_t spec = spec_of(name, 0x9000000);
	uint32_t device = 99, again = 99;
	uintptr_t register_keys[ERX_DEVICE_REGISTERS_MAX], field_keys[ERX_DEVICE_FIELDS_MAX];
	uint64_t irq;
	const erx_device_t *record;

	for (uint32_t index = 0; index < ERX_DEVICE_REGISTERS_MAX; index++)
		register_keys[index] = KEY_BASE + index;
	for (uint32_t index = 0; index < ERX_DEVICE_FIELDS_MAX; index++)
		field_keys[index] = KEY_BASE + index;
	CHECK(erx_device_get(0) == NULL);
	spec.peripheral_length = strlen(name) - 1;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_EINVAL);
	spec = spec_of(name, 0x9000000);
	spec.size = block_bytes - 1;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_EINVAL);
	spec = spec_of(name, 0x9000000);
	spec.line_count = ERX_DEVICE_LINES_MAX + 1;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_EINVAL);

	/* No build but a hosted runtime's has a stand-in. */
	spec = spec_of(name, 0x9000000);
	spec.form = ERX_DEVICE_FORM_STAND_IN;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_ENOTSUP);

	spec = spec_of(name, 0x9000000);
	fail_physical = ERX_ENOTSUP;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_ENOTSUP);
	fail_physical = ERX_OK;
	fail_reserve = ERX_ENOMEM;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_ENOMEM);
	fail_reserve = ERX_OK;
	fail_map = ERX_ENOMEM;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_ENOMEM);
	fail_map = ERX_OK;
	fail_irq = ERX_EBUSY;
	CHECK(erx_device_open(&spec, NULL, NULL, &device) == ERX_EBUSY);
	fail_irq = ERX_OK;
	CHECK(erx_device_get(0) == NULL);

	CHECK(erx_device_open(&spec, register_keys, field_keys, &device) == ERX_OK && device == 0);
	CHECK(last_physical_size == WINDOW_BYTES);
	record = erx_device_get(device);
	CHECK(record != NULL && erx_device_line_irq(record, 0, &irq) && !erx_device_line_irq(record, 1, &irq));
	const uint32_t made = irq_created;

	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_OK && again == device && irq_created == made);
	CHECK(erx_device_get(1) == NULL && erx_device_get(UINT64_MAX) == NULL);

	/* The same window with anything else is refused, whatever differs. */
	spec.lines[0] = 34;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	spec = spec_of(name, 0x9000000);
	spec.line_count = 0;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);
	spec = spec_of(name, 0x9000000);
	spec.size = WINDOW_BYTES * 2;
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_EBUSY);

	uint32_t next = check_slot() + 1;

	CHECK(next == 3);
#ifndef ERX_DEVICE_FIXTURE
	next = check_shared_page() + 1;
#endif
	next = check_shared_line(name) + 1;
	check_binds(device, next - 1);
	for (uint32_t base = next; base < ERX_DEVICE_MAX; base++) {
		spec = spec_of(name, 0x9000000 + UINT64_C(0x1000) * base);
		spec.lines[0] = 40 + base;
		CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_OK && again == base);
	}
	spec = spec_of(name, 0xa000000);
	CHECK(erx_device_open(&spec, NULL, NULL, &again) == ERX_ELIMIT);

	/* A key finds its own entry, and a field only within its own register. */
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral(record);

	for (uint32_t index = 0; index < peripheral->register_count; index++) {
		const erx_device_register_t *const reg = &peripheral->registers[index];

		CHECK(erx_device_register_by_key(record, KEY_BASE + index) == reg);
		for (uint32_t at = 0; at < peripheral->field_count; at++) {
			const bool own = at >= reg->first_field && at < reg->first_field + reg->field_count;

			CHECK(erx_device_field_by_key(record, reg, KEY_BASE + at) == (own ? &peripheral->fields[at] : NULL));
		}
	}
	CHECK(erx_device_register_by_key(record, KEY_BASE + peripheral->register_count) == NULL);
	return (device);
}

#ifndef ERX_DEVICE_FIXTURE
/*
 * RSR is read-write in the table, and any write to it clears all four errors, so no
 * field of it is written alone. The window holds a non-zero word that must survive.
 */
static void
check_rsr(const erx_device_peripheral_t *uart, const erx_device_t *device)
{
	const erx_device_register_t *const rsr = register_of(uart, "rsr");
	uint32_t *const word = (uint32_t *)(void *)&window_memory[0][0x4];

	*word = 0xf;
	CHECK(erx_device_read_allowed(rsr));
	for (uint32_t at = 0; at < rsr->field_count; at++) {
		const erx_device_field_t *const error = &uart->fields[rsr->first_field + at];

		CHECK(erx_device_field_plan(rsr, error, 0).op == ERX_DEVICE_FIELD_REFUSED);
		CHECK(erx_device_field_plan(rsr, error, 1).op == ERX_DEVICE_FIELD_REFUSED);
		CHECK(!erx_device_write_field(device, rsr, plain, error, 0));
		CHECK(erx_device_field_read_allowed(rsr, error));
	}
	CHECK(*word == 0xf);
	*word = 0;
}

/* The PL011's own rules, read from Arm DDI 0183G, through one window. */
static void
check_peripheral(const erx_device_peripheral_t *uart, const erx_device_t *device)
{
	const erx_device_register_t *const imsc = register_of(uart, "imsc"), *const dr = register_of(uart, "dr");
	const erx_device_register_t *const icr = register_of(uart, "icr"), *const fr = register_of(uart, "fr");
	const erx_device_field_t *const rxim = field_of(uart, imsc, "rxim"), *const rtim = field_of(uart, imsc, "rtim");
	erx_device_element_t element = plain;
	erx_device_field_plan_t plan;
	uint64_t word;

	CHECK(imsc->offset == 0x38 && dr->offset == 0 && fr->offset == 0x18 && icr->offset == 0x44);
	CHECK(erx_device_register_named(uart, "imsc") < uart->register_count);
	for (uint32_t index = 0; index < uart->register_count; index++)
		CHECK(!uart->registers[index].owned_by_nif);

	/* A field's update reads the word back and keeps its neighbours, at the register's own offset. */
	CHECK(erx_device_write_field(device, imsc, plain, rxim, 1) && erx_device_write_field(device, imsc, plain, rtim, 1));
	CHECK(erx_device_read(device, imsc, plain, &word) && word == ((1u << 4) | (1u << 6)));
	CHECK(*(uint32_t *)(void *)&window_memory[0][0x38] == ((1u << 4) | (1u << 6)));
	CHECK(erx_device_read_field(device, imsc, plain, rxim, &word) && word == 1);
	CHECK(!erx_device_write_field(device, imsc, plain, rxim, 2));
	element.indexed = true;
	CHECK(!erx_device_read(device, imsc, element, &word) && !erx_device_write(device, imsc, element, 0));
	CHECK(!erx_device_read_field(device, imsc, element, rxim, &word) && !erx_device_write_field(device, imsc, element, rxim, 0));

	/* Nothing refused touches the window. */
	CHECK(!erx_device_write(device, dr, plain, 0x100) && !erx_device_write(device, fr, plain, 0));
	CHECK(!erx_device_read(device, icr, plain, &word) && *(uint32_t *)(void *)&window_memory[0][0] == 0);

	/* DR pops a byte when it is read, so it is written whole, within its writable bits. */
	CHECK(erx_device_field_plan(dr, field_of(uart, dr, "data"), 65).op == ERX_DEVICE_FIELD_REFUSED);
	CHECK(erx_device_field_plan(dr, field_of(uart, dr, "oe"), 1).op == ERX_DEVICE_FIELD_REFUSED);
	CHECK(erx_device_write_allowed(dr, 65) && !erx_device_write_allowed(dr, 0x100));
	CHECK(erx_device_field_read_allowed(dr, field_of(uart, dr, "oe")));

	/* ICR clears what it is written, in one write; FR is only read. */
	plan = erx_device_field_plan(icr, field_of(uart, icr, "rtic"), 1);
	CHECK(plan.op == ERX_DEVICE_FIELD_WRITE && plan.bits == 0x40);
	CHECK(!erx_device_field_of(icr, plain, field_of(uart, icr, "rtic"), 0x40, &word));
	CHECK(erx_device_field_of(dr, plain, field_of(uart, dr, "oe"), 0x800, &word) && word == 1);
	CHECK(erx_device_field_of(dr, plain, field_of(uart, dr, "data"), 0x8ab, &word) && word == 0xab);
	CHECK(!erx_device_read_allowed(icr) && erx_device_write_allowed(icr, 0x7ff) && !erx_device_write_allowed(icr, 0x800));
	CHECK(erx_device_read_allowed(fr) && !erx_device_write_allowed(fr, 0));
	CHECK(erx_device_field_get(field_of(uart, fr, "rxfe"), 1u << 4) == 1);
	CHECK(erx_device_field_plan(fr, field_of(uart, fr, "rxfe"), 0).op == ERX_DEVICE_FIELD_REFUSED);
	check_rsr(uart, device);
}
#else
/* What the PL011 has none of. */
static void
check_peripheral(const erx_device_peripheral_t *fixture, const erx_device_t *device)
{
	const erx_device_register_t *const slot = register_of(fixture, "slot"), *const ring = register_of(fixture, "ring_base");
	const erx_device_register_t *const wide = register_of(fixture, "wide"), *const pop = register_of(fixture, "pop");
	const erx_device_register_t *const doorbell = register_of(fixture, "doorbell");
	const erx_device_register_t *const status = register_of(fixture, "status");
	const erx_device_field_t *const all = field_of(fixture, wide, "all");
	erx_device_element_t element = plain;
	erx_device_field_plan_t plan;
	uint64_t offset, word;

	/* An array by index, and nothing else. */
	CHECK(slot->count == 4 && slot->stride == 8);
	CHECK(erx_device_element_offset(slot, true, 3, &offset) && offset == 0x40 + 3 * 8);
	CHECK(!erx_device_element_offset(slot, true, 4, &offset) && !erx_device_element_offset(slot, false, 0, &offset));
	CHECK(!erx_device_element_offset(wide, true, 0, &offset));
	/* A read-only field stays out of what a write sets. */
	plan = erx_device_field_plan(slot, field_of(fixture, slot, "high"), 5);
	CHECK(plan.op == ERX_DEVICE_FIELD_UPDATE && plan.keep == 0xf && erx_device_field_apply(&plan, 0x3ff) == 0x5f);

	/* An element at its own offset. */
	element.indexed = true;
	element.index = 3;
	CHECK(erx_device_write(device, slot, element, 0x5f) && *(uint32_t *)(void *)&window_memory[0][0x58] == 0x5f);
	element.index = 4;
	CHECK(!erx_device_write(device, slot, element, 0x5f));

	/* A device address is readable, and no one writes it through this interface. */
	CHECK(ring->owned_by_nif && erx_device_read_allowed(ring));
	CHECK(!erx_device_write(device, ring, plain, 0x1000) && *(uint64_t *)(void *)&window_memory[0][0x80] == 0);
	CHECK(!erx_device_write_allowed(ring, 0x1000) && !erx_device_write_allowed(ring, 0));
	CHECK(erx_device_field_plan(ring, field_of(fixture, ring, "address"), 0x1000).op == ERX_DEVICE_FIELD_REFUSED);

	/* The full width has no undefined shift, and a 64-bit access is 64 bits. */
	CHECK(all->mask == UINT64_MAX && erx_device_field_get(all, UINT64_MAX) == UINT64_MAX);
	plan = erx_device_field_plan(wide, all, UINT64_MAX);
	CHECK(plan.op == ERX_DEVICE_FIELD_UPDATE && plan.keep == 0 && erx_device_write_allowed(wide, UINT64_MAX));
	CHECK(erx_device_write(device, wide, plain, UINT64_C(0x1122334455667788)));
	CHECK(erx_device_read(device, wide, plain, &word) && word == UINT64_C(0x1122334455667788));
	CHECK(*(uint64_t *)(void *)&window_memory[0][0x88] == UINT64_C(0x1122334455667788));

	/* No read of a word nothing should read: a read side effect, or a write-only register. */
	CHECK(erx_device_field_plan(pop, field_of(fixture, pop, "value"), 1).op == ERX_DEVICE_FIELD_REFUSED);
	CHECK(erx_device_field_plan(doorbell, field_of(fixture, doorbell, "queue"), 1).op == ERX_DEVICE_FIELD_REFUSED);
	CHECK(!erx_device_read_allowed(doorbell) && erx_device_write_allowed(doorbell, 0xff));

	/* A one-to-clear field beside a read-only one is one write of its own bits. */
	plan = erx_device_field_plan(status, field_of(fixture, status, "pending"), 0xf);
	CHECK(plan.op == ERX_DEVICE_FIELD_WRITE && plan.bits == 0xf);
	CHECK(erx_device_field_plan(status, field_of(fixture, status, "id"), 1).op == ERX_DEVICE_FIELD_REFUSED);
}
#endif

int
main(void)
{
#ifdef ERX_DEVICE_FIXTURE
	const char *const name = "fixture";
	const uint64_t block_bytes = WINDOW_BYTES;
#else
	const char *const name = "pl011";
	const uint64_t block_bytes = PL011_BLOCK_BYTES;
#endif
	const erx_device_peripheral_t *const peripheral = erx_device_peripheral_find(name, strlen(name));
	uint32_t device;

	CHECK(peripheral != NULL && peripheral->register_count <= ERX_DEVICE_REGISTERS_MAX &&
	    peripheral->field_count <= ERX_DEVICE_FIELDS_MAX && peripheral->window_size == block_bytes);
	CHECK(erx_device_peripheral_find(name, strlen(name) - 1) == NULL);
	CHECK(erx_device_peripheral_find("", 0) == NULL);
	CHECK(erx_device_peripheral_find("no_such_peripheral", 18) == NULL);
	check_keys();
	check_window_pages();
	check_every_entry(peripheral);
	device = check_open(name, block_bytes);
	check_peripheral(peripheral, erx_device_get(device));
	printf("erx_device %s done\n", name);
	return (0);
}
