/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The TRB ring form's effects on an xHCI controller the harness plays over a plain register
 * window (erx_device.c, docs/design-usb.md, "Install"): the record made by the first negotiate
 * call from the counts the capability registers give; one step a call, each answered ebusy, run
 * cleared, HCRST written only once the controller halts, nothing written while HCRST or CNR
 * stays set, then the install's registers in FreeBSD's order, each word from the table's fields
 * (an address low word then high, CRCR's cycle state, IMAN.IE with IP written 0, USBCMD's run
 * and INTE) over memory the install laid out, and ok once the controller runs; the next call
 * begins again. And the refusals before anything is written: too many scratchpad pages, a page
 * size without 4 KiB, memory past 4 GiB without AC64, and a numbered queue on the device.
 */

#include <sys/mman.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/hw/xhci.h"
#include "liberx/backend/api.h"
#include "otp/erts/emulator/nifs/erxos/erx_device.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_trb_form.h"
#include "otp/erts/emulator/nifs/erxos/erx_device_xhci.h"
#include "otp/erts/emulator/nifs/erxos/erx_dma_arch.h"

#define CHECK(condition)							\
	do {									\
		if (!(condition)) {						\
			printf("FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); \
			exit(1);						\
		}								\
	} while (0)

#define MEMORIES_MAX	24u
#define WINDOW_BYTES	0x4000u
#define DEVICE_MEMORY	(UINT64_C(1) << 20)
#define SLOT_SHIFT	28u
#define HIGH_BASE	(UINT64_C(1) << 40)
/* Where the harness's controller reports its movable clusters. */
#define OPERATIONAL	0x20u
#define RUNTIME		0x1000u
#define DOORBELLS	0x2000u
#define WRITES_MAX	64u

static uint8_t *memories[MEMORIES_MAX];
static uint64_t memory_sizes[MEMORIES_MAX];
static uint32_t memory_count;
static bool high_addresses;		/* erx_mem_dma_addr answers past 4 GiB */
static const erx_device_peripheral_t *xhci;
static uint8_t *window;
/* Every 32-bit store to the window, in order. */
static uint32_t write_offsets[WRITES_MAX], write_values[WRITES_MAX];
static uint32_t writes;
static const uint8_t *doorbell_watch;	/* the control word a doorbell must find activated */
static bool doorbell_saw_cycle;

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
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq,
    erx_msi_message_t *message)
{
	(void)message;
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


/* -------------------------------------------------------------------------------------------
 * The controller's window: plain memory, every 32-bit store logged
 */

uint8_t
erx_device_access_load8(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset < WINDOW_BYTES);
	return (at[offset]);
}

void
erx_device_access_store8(volatile uint8_t *at, uint64_t offset, uint8_t value)
{
	CHECK(at == window && offset < WINDOW_BYTES);
	at[offset] = value;
}

uint16_t
erx_device_access_load16(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 2 <= WINDOW_BYTES);
	return (*(volatile uint16_t *)(void *)(at + offset));
}

void
erx_device_access_store16(volatile uint8_t *at, uint64_t offset, uint16_t value)
{
	CHECK(at == window && offset + 2 <= WINDOW_BYTES);
	*(volatile uint16_t *)(void *)(at + offset) = value;
}

uint32_t
erx_device_access_load32(volatile uint8_t *at, uint64_t offset)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES);
	return (*(volatile uint32_t *)(void *)(at + offset));
}

void
erx_device_access_store32(volatile uint8_t *at, uint64_t offset, uint32_t value)
{
	CHECK(at == window && offset + 4 <= WINDOW_BYTES && writes < WRITES_MAX);
	*(volatile uint32_t *)(void *)(at + offset) = value;
	write_offsets[writes] = (uint32_t)offset;
	write_values[writes++] = value;
	if (doorbell_watch != NULL && offset >= DOORBELLS && offset < DOORBELLS + 1024u)
		doorbell_saw_cycle = (doorbell_watch[0] & 1u) != 0;
}

/* xHCI's registers the NIF reaches are 32 bits wide or narrower. */
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

/* The window offset of register `name`: its cluster's base, as the harness reports it, plus its own. */
static uint32_t
offset_of(const char *name)
{
	static const uint32_t bases[] = { 0, OPERATIONAL, RUNTIME, DOORBELLS };
	const uint32_t found = erx_device_register_named(xhci, name);

	CHECK(found < xhci->register_count && xhci->registers[found].base < 4);
	return (bases[xhci->registers[found].base] + xhci->registers[found].offset);
}

static uint32_t *
reg(const char *name)
{
	return ((uint32_t *)(void *)(window + offset_of(name)));
}

/* Field `field` of register `name` in the window set to `value`, by the table's field. */
static void
set_field(const char *name, const char *field, uint32_t value)
{
	const erx_device_register_t *const r = &xhci->registers[erx_device_register_named(xhci, name)];
	const uint32_t at = erx_device_field_named(xhci, r, field);
	const erx_device_field_t *f;

	CHECK(at < r->field_count);
	f = &xhci->fields[r->first_field + at];
	*reg(name) = (uint32_t)((*reg(name) & ~f->mask) | ((uint64_t)value << f->shift));
}

/* Field `field` of register `name` in the window, by the table's field. */
static uint32_t
get_field(const char *name, const char *field)
{
	const erx_device_register_t *const r = &xhci->registers[erx_device_register_named(xhci, name)];
	const uint32_t at = erx_device_field_named(xhci, r, field);
	const erx_device_field_t *f;

	CHECK(at < r->field_count);
	f = &xhci->fields[r->first_field + at];
	return ((uint32_t)((*reg(name) & f->mask) >> f->shift));
}

/* A controller left running by firmware, reporting its clusters, `scratchpads` pages, 4 KiB pages if `four_kib`, and AC64 if `ac64`. */
static void
preset(uint32_t scratchpads, bool four_kib, bool ac64)
{
	bzero(window, WINDOW_BYTES);
	window[0] = OPERATIONAL;
	set_field("hcsparams1", "maxslots", 8);
	set_field("hcsparams1", "maxports", 4);
	set_field("hcsparams1", "maxintrs", 1);
	set_field("hcsparams2", "spb_max_lo", scratchpads & 31u);
	set_field("hcsparams2", "spb_max_hi", scratchpads >> 5);
	set_field("hccparams1", "ac64", ac64);
	*reg("dboff") = DOORBELLS;
	*reg("rtsoff") = RUNTIME;
	set_field("pagesize", "four_kib", four_kib);
	set_field("usbcmd", "rs", 1);
	set_field("usbcmd", "inte", 1);
	/* An interrupt pending from before the reset, which the install's IMAN.IE must not clear. */
	set_field("iman", "ip", 1);
	/* IMOD at its reset interval, 4000 x 250 ns, and a counter still running (xHCI 1.2, 5.5.2.2). */
	set_field("imod", "imodi", 4000);
	set_field("imod", "imodc", 123);
}

/* The spec of the last open_routed, for opening its window again. */
static erx_device_spec_t routed_spec;

/* A controller as preset gives it, with the MSI-X route `msix`, and erx_device_open's answer. */
static int
open_routed(uint32_t scratchpads, bool four_kib, bool ac64, erx_device_msix_t msix, const erx_device_t **opened)
{
	const uint64_t window_object = make_memory(WINDOW_BYTES);
	const uint64_t memory = make_memory(DEVICE_MEMORY);
	const erx_device_spec_t spec = { .peripheral = "xhci", .peripheral_length = 4, .form = ERX_DEVICE_FORM_GIVEN,
	    .window = window_object, .base = 0, .size = WINDOW_BYTES, .memory = memory,
	    .memory_size = memory_sizes[memory], .msix = msix };
	uint32_t device;
	int status;

	window = memories[window_object];
	preset(scratchpads, four_kib, ac64);
	maps[0] = window_object;
	maps[1] = memory;
	maps_pushed = 2;
	maps_done = 0;
	routed_spec = spec;
	status = erx_device_open(&spec, NULL, NULL, &device, NULL);
	*opened = status == ERX_OK ? erx_device_get(device) : NULL;
	return (status);
}

/* The last open_routed's window opened again with the route `msix`, and erx_device_open's answer. */
static int
open_reused(erx_device_msix_t msix)
{
	erx_device_spec_t spec = routed_spec;
	uint32_t device;

	spec.msix = msix;
	return (erx_device_open(&spec, NULL, NULL, &device, NULL));
}

static const erx_device_t *
open_xhci(uint32_t scratchpads, bool four_kib, bool ac64)
{
	const erx_device_t *device;

	CHECK(open_routed(scratchpads, four_kib, ac64, (erx_device_msix_t){ 0 }, &device) == ERX_OK && maps_done == 2);
	return (device);
}

/* One negotiate call, beginning a negotiation or continuing one, its answer and the stores it made. */
static int
negotiate(const erx_device_t *device, bool continues, uint32_t expected_writes)
{
	uint64_t accepted = 1;
	int status;

	writes = 0;
	status = erx_device_negotiate(device, UINT64_MAX, continues, &accepted);
	CHECK(writes == expected_writes);
	CHECK(status != ERX_OK || accepted == 0);
	return (status);
}

/* The bytes of the device's memory at device address `addr`, which must lie in it. */
static uint8_t *
memory_at(uint64_t addr, uint64_t length)
{
	const uint64_t mem = (addr >> SLOT_SHIFT) - 1;

	CHECK(!high_addresses && mem < memory_count && (addr & ((UINT64_C(1) << SLOT_SHIFT) - 1)) + length <= memory_sizes[mem]);
	return (memories[mem] + (addr & ((UINT64_C(1) << SLOT_SHIFT) - 1)));
}

static uint64_t
word64(const uint8_t *at)
{
	uint64_t value;

	memcpy(&value, at, sizeof(value));
	return (value);
}

/* The install's stores, in FreeBSD's order (xhci.c:329-428), each checked by the generated accessors. */
static void
check_install(void)
{
	static const char *const order[] = { "config", "dcbaap_lo", "dcbaap_hi", "erstsz", "imod", "erdp_lo", "erdp_hi",
	    "erstba_lo", "erstba_hi", "iman", "crcr_lo", "crcr_hi", "usbcmd" };
	uint64_t dcbaa, segment_table, dequeue, ring;

	for (uint32_t at = 0; at < sizeof(order) / sizeof(order[0]); at++)
		CHECK(write_offsets[at] == offset_of(order[at]));
	CHECK(erx_xhci_config_maxslotsen_get(*reg("config")) == 8);
	CHECK(erx_xhci_erstsz_size_get(*reg("erstsz")) == 1);
	/* FreeBSD's moderation interval, 500 x 250 ns (xhci.c:369, xhcireg.h:176), its counter 0. */
	CHECK(erx_xhci_imod_imodi_get(*reg("imod")) == 500 && erx_xhci_imod_imodc_get(*reg("imod")) == 0);
	CHECK(erx_xhci_iman_ie_get(*reg("iman")) == 1 && erx_xhci_iman_ip_get(*reg("iman")) == 0);
	CHECK(erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 1 && erx_xhci_usbcmd_inte_get(*reg("usbcmd")) == 1 &&
	    erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 0);
	CHECK(get_field("erdp_lo", "ehb") == 0 && get_field("erdp_lo", "desi") == 0);
	/* Each address whole across its two registers, and what the install wrote where it points. */
	dcbaa = (uint64_t)*reg("dcbaap_hi") << 32 | *reg("dcbaap_lo");
	segment_table = (uint64_t)*reg("erstba_hi") << 32 | *reg("erstba_lo");
	dequeue = (uint64_t)*reg("erdp_hi") << 32 | *reg("erdp_lo");
	ring = (uint64_t)*reg("crcr_hi") << 32 | (uint64_t)get_field("crcr_lo", "pointer_lo") << 6;
	CHECK(dcbaa % 64 == 0 && segment_table % 64 == 0 && dequeue % 16 == 0 && ring % 64 == 0);
	CHECK(get_field("crcr_lo", "rcs") == 1 && get_field("crcr_lo", "cs") == 0 && get_field("crcr_lo", "ca") == 0);
	CHECK(word64(memory_at(segment_table, 16)) == dequeue);
	CHECK(word64(memory_at(dcbaa, 8)) != 0 && word64(memory_at(word64(memory_at(dcbaa, 8)), 8)) != 0);
	(void)memory_at(ring, 16);
}

/* The start, one step a call, over a controller that answers each step only after the harness lets it. */
static void
test_start(void)
{
	const erx_device_t *const device = open_xhci(2, true, true);
	uint32_t queue;

	CHECK(erx_device_queue_create(device, 0, 8, 4096, &queue) == ERX_ENOTSUP);
	CHECK(negotiate(device, false, 1) == ERX_EBUSY && write_offsets[0] == offset_of("usbcmd"));
	CHECK(erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0 && erx_xhci_usbcmd_inte_get(*reg("usbcmd")) == 1);
	/* Not halted yet: run cleared again, in case the controller missed the first write. */
	CHECK(negotiate(device, true, 1) == ERX_EBUSY && write_offsets[0] == offset_of("usbcmd"));
	set_field("usbsts", "hch", 1);
	CHECK(negotiate(device, true, 1) == ERX_EBUSY && erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 1);
	set_field("usbsts", "cnr", 1);
	CHECK(negotiate(device, true, 0) == ERX_EBUSY);	/* HCRST still set */
	set_field("usbcmd", "hcrst", 0);
	set_field("usbcmd", "inte", 0);			/* a reset closes INTE (5.4.1, p. 394) */
	CHECK(negotiate(device, true, 0) == ERX_EBUSY);	/* CNR still set */
	set_field("usbsts", "cnr", 0);
	CHECK(negotiate(device, true, 0) == ERX_DEVICE_RESET_DONE);
	CHECK(negotiate(device, true, 13) == ERX_EBUSY);
	check_install();
	CHECK(negotiate(device, true, 0) == ERX_EBUSY);	/* still halted */
	set_field("usbsts", "hch", 0);
	CHECK(negotiate(device, true, 0) == ERX_OK);
	/* A started controller's next negotiation begins again with run cleared. */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY && erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0);
}

/*
 * A negotiation begun over one left at each of its steps, as a restarted controller process
 * begins: it starts from the beginning, never from the step the record keeps.
 */
static void
test_restart(void)
{
	const erx_device_t *const device = open_xhci(2, true, true);

	CHECK(negotiate(device, false, 1) == ERX_EBUSY);
	set_field("usbsts", "hch", 1);
	CHECK(negotiate(device, true, 1) == ERX_EBUSY);	/* left at the reset */
	set_field("usbsts", "cnr", 1);
	CHECK(negotiate(device, false, 0) == ERX_EBUSY);	/* begun mid-reset: nothing written while HCRST is set */
	set_field("usbcmd", "hcrst", 0);
	CHECK(negotiate(device, false, 0) == ERX_EBUSY);	/* nor while CNR is */
	set_field("usbsts", "cnr", 0);
	/* Halted and ready: a begin resets again where the old negotiation would have installed. */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY && erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 1);
	set_field("usbcmd", "hcrst", 0);
	CHECK(negotiate(device, true, 0) == ERX_DEVICE_RESET_DONE);
	CHECK(negotiate(device, true, 13) == ERX_EBUSY);	/* left installed, waiting for HCH to clear */
	/* Halted with run set, as the install leaves it: run cleared before any reset. */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY && erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0 &&
	    erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 0);
	CHECK(negotiate(device, true, 1) == ERX_EBUSY && erx_xhci_usbcmd_hcrst_get(*reg("usbcmd")) == 1);
	set_field("usbcmd", "hcrst", 0);
	CHECK(negotiate(device, true, 0) == ERX_DEVICE_RESET_DONE);
	CHECK(negotiate(device, true, 13) == ERX_EBUSY);
	set_field("usbsts", "hch", 0);
	/* The controller runs, but this negotiation did not install it: run cleared, not answered started. */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY && erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0);
}

/*
 * A function's MSI-X table, written by the call that ends the reset, which answers
 * ERX_DEVICE_RESET_DONE so the driver masters its function before the install's registers
 * (docs/design-pcie.md, "Who programs what, and when"): entry 0 the route's message unmasked,
 * every other entry of the route masked; the next call installs.
 */
#define MSIX_TABLE	0x3000u
#define MSIX_ENTRIES	16u

static const erx_device_msix_t msix_route = { .address = UINT64_C(0x1080000040), .data = 0x2a, .offset = MSIX_TABLE,
    .entries = MSIX_ENTRIES };

/* The 32-bit word at byte `offset` of the window. */
static uint32_t *
table_word(uint32_t offset)
{
	return ((uint32_t *)(void *)(window + offset));
}

static void
test_msix(void)
{
	const erx_device_t *device;

	CHECK(open_routed(2, true, true, msix_route, &device) == ERX_OK);
	for (uint32_t entry = 0; entry < MSIX_ENTRIES; entry++)
		*table_word((MSIX_TABLE + 16u * entry + 12u)) = 0;	/* every entry unmasked before the reset */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY);
	set_field("usbsts", "hch", 1);
	CHECK(negotiate(device, true, 1) == ERX_EBUSY);
	set_field("usbcmd", "hcrst", 0);
	CHECK(negotiate(device, true, 4 + (MSIX_ENTRIES - 1)) == ERX_DEVICE_RESET_DONE);
	CHECK(write_offsets[0] == MSIX_TABLE && write_offsets[1] == MSIX_TABLE + 4u && write_offsets[2] == MSIX_TABLE + 8u &&
	    write_offsets[3] == MSIX_TABLE + 12u && write_offsets[4] == MSIX_TABLE + 16u + 12u);
	CHECK(*table_word(MSIX_TABLE) == 0x80000040u && *table_word(MSIX_TABLE + 4u * 1u) == 0x10u &&
	    *table_word(MSIX_TABLE + 4u * 2u) == 0x2au && *table_word(MSIX_TABLE + 4u * 3u) == 0);
	for (uint32_t entry = 1; entry < MSIX_ENTRIES; entry++)
		CHECK(*table_word((MSIX_TABLE + 16u * entry + 12u)) == 1);
	CHECK(erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 0);	/* nothing of the install before the driver masters */
	CHECK(negotiate(device, true, 13) == ERX_EBUSY);
	CHECK(write_offsets[0] == offset_of("config") && write_offsets[12] == offset_of("usbcmd") &&
	    erx_xhci_usbcmd_rs_get(*reg("usbcmd")) == 1);
	/* The same window again with another route is refused: an open answers only for the spec it made. */
	CHECK(open_reused((erx_device_msix_t){ .address = msix_route.address, .data = 0x2b, .offset = MSIX_TABLE,
	    .entries = MSIX_ENTRIES }) == ERX_EBUSY);
}

/*
 * The routes an open refuses, with no record taken: a table off the 8-byte alignment its BIR
 * leaves, more entries than the table declares, a table past the window's end, and one over the
 * controller's registers, whose words a driver may write.
 */
static void
test_msix_refusals(void)
{
	const erx_device_t *device;
	const erx_device_msix_t refused[] = {
		{ .address = msix_route.address, .data = 1, .offset = MSIX_TABLE + 4u, .entries = 1 },
		{ .address = msix_route.address, .data = 1, .offset = 0, .entries = 2049 },
		{ .address = msix_route.address, .data = 1, .offset = WINDOW_BYTES - 16u, .entries = 2 },
		{ .address = msix_route.address, .data = 1, .offset = 0, .entries = 1 },
	};

	for (uint32_t at = 0; at < sizeof(refused) / sizeof(refused[0]); at++)
		CHECK(open_routed(2, true, true, refused[at], &device) == ERX_EINVAL);
	CHECK(open_routed(2, true, true, msix_route, &device) == ERX_OK);
}

/* What a negotiation refuses before it writes anything. */
static void
test_refusals(void)
{
	CHECK(negotiate(open_xhci(ERX_DEVICE_TRB_SCRATCHPADS_MAX + 1, true, true), false, 0) == ERX_ENOTSUP);
	CHECK(negotiate(open_xhci(2, false, true), false, 0) == ERX_ENOTSUP);
	high_addresses = true;
	CHECK(negotiate(open_xhci(2, true, false), false, 0) == ERX_ERANGE);
	high_addresses = false;
}

/* -------------------------------------------------------------------------------------------
 * Posts, completions and queue states on a started controller
 */

static erx_device_trb_layout_t layout;		/* the record's, derived again from what the controller reports */
static uint32_t event_index;			/* the next event the harness's controller writes */

/* A controller started by negotiate's steps, its record's layout, and the event ring at its first entry. */
static const erx_device_t *
started(void)
{
	const erx_device_t *const device = open_xhci(2, true, true);
	const uint64_t memory = memory_count - 1;
	const erx_device_trb_controller_t controller = { .slots = 8, .ports = 4, .scratchpads = 2,
	    .context_size = ERX_XHCI_SLOT_CONTEXT_SIZE, .doorbells = DOORBELLS };
	erx_device_trb_verdict_t verdict;
	const erx_trb_command_t enable = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	uint64_t base;

	CHECK(erx_device_trb_command(device, &enable, 1, &verdict) == ERX_EINVAL);	/* no record yet */
	CHECK(negotiate(device, false, 1) == ERX_EBUSY);
	CHECK(erx_device_trb_command(device, &enable, 1, &verdict) == ERX_ECORRUPT);	/* not started */
	set_field("usbsts", "hch", 1);
	CHECK(negotiate(device, true, 1) == ERX_EBUSY);
	set_field("usbcmd", "hcrst", 0);
	CHECK(negotiate(device, true, 0) == ERX_DEVICE_RESET_DONE);
	CHECK(negotiate(device, true, 13) == ERX_EBUSY);
	set_field("usbsts", "hch", 0);
	CHECK(negotiate(device, true, 0) == ERX_OK);
	CHECK(erx_mem_dma_addr(memory, 0, &base) == ERX_OK &&
	    erx_device_trb_layout(&layout, &erx_device_trb_shape, &controller, base, erx_dma_granule(), DEVICE_MEMORY));
	event_index = 0;
	return (device);
}

/* The device address of TRB `index` of region `region`. */
static uint64_t
trb_at(uint16_t region, uint32_t index)
{
	return (layout.device_base + layout.regions[region].offset + 16u * (uint64_t)index);
}

/* Whether TRB `index` of region `region` carries the first lap's cycle bit, bit 0 of its control word. */
static bool
trb_cycle(uint16_t region, uint32_t index)
{
	uint32_t control;

	memcpy(&control, memory_at(trb_at(region, index) + 12u, 4), 4);
	return ((control & 1u) != 0);
}

/*
 * The controller writing its next event, of `type`, with the first lap's cycle bit: a transfer
 * or command event's TRB pointer, code, residue, slot and endpoint, or a port event's port.
 */
static void
put_event(uint32_t type, uint64_t pointer, uint32_t code, uint32_t residue, uint32_t slot, uint32_t dci)
{
	erx_report_record_t event;
	erx_xhci_trb_transfer_event_t *const record = &event.xhci_trb_transfer_event;

	bzero(&event, sizeof(event));
	record->pointer = pointer;
	CHECK(erx_xhci_trb_transfer_event_status_code_set(&record->status, code) &&
	    erx_xhci_trb_transfer_event_status_residue_set(&record->status, residue) &&
	    erx_xhci_trb_transfer_event_control_type_set(&record->control, type) &&
	    erx_xhci_trb_transfer_event_control_slot_set(&record->control, slot) &&
	    erx_xhci_trb_transfer_event_control_endpoint_set(&record->control, dci) &&
	    erx_xhci_trb_transfer_event_control_cycle_set(&record->control, 1));
	memcpy(memory_at(trb_at(layout.event_ring, event_index++), sizeof(event)), &event, sizeof(event));
}

static void
put_port_event(uint32_t port)
{
	erx_report_record_t event;

	bzero(&event, sizeof(event));
	CHECK(erx_xhci_trb_port_event_parameter_port_set(&event.xhci_trb_port_event.parameter, port) &&
	    erx_xhci_trb_port_event_status_code_set(&event.xhci_trb_port_event.status, ERX_XHCI_COMPLETION_SUCCESS) &&
	    erx_xhci_trb_port_event_control_type_set(&event.xhci_trb_port_event.control,
	    ERX_XHCI_TRB_TYPE_PORT_STATUS_CHANGE_EVENT) &&
	    erx_xhci_trb_port_event_control_cycle_set(&event.xhci_trb_port_event.control, 1));
	memcpy(memory_at(trb_at(layout.event_ring, event_index++), sizeof(event)), &event, sizeof(event));
}

/* What a completion gave its sink, in order, each transfer's bytes copied whole. */
#define ANSWERS_MAX	8u
static erx_trb_answer_t answers[ANSWERS_MAX];
static uint8_t answer_bytes[ANSWERS_MAX][64];
static uint32_t answer_count;

static uint8_t *
sink(void *context, const erx_trb_answer_t *answer)
{
	CHECK(context == &answer_count && answer_count < ANSWERS_MAX && answer->data.length <= sizeof(answer_bytes[0]));
	answers[answer_count] = *answer;
	return (answer_bytes[answer_count++]);
}

/*
 * One completion, `expected` answers, and its stores: ERDP alone, low word then high, at the event
 * ring's entry past every event written but the last `unconsumed`, its busy bit written 1, which
 * clears it.
 */
static int
complete(const erx_device_t *device, uint32_t expected, uint32_t unconsumed)
{
	uint32_t answered = UINT32_MAX;
	uint64_t dequeue;
	int status;

	writes = 0;
	answer_count = 0;
	status = erx_device_trb_complete(device, sink, &answer_count, &answered);
	CHECK(answered == answer_count && answer_count == expected);
	CHECK(writes == 2 && write_offsets[0] == offset_of("erdp_lo") && write_offsets[1] == offset_of("erdp_hi"));
	CHECK(get_field("erdp_lo", "ehb") == 1 && get_field("erdp_lo", "desi") == 0);
	dequeue = (uint64_t)*reg("erdp_hi") << 32 | (*reg("erdp_lo") & ~UINT32_C(15));
	CHECK(dequeue == trb_at(layout.event_ring, event_index - unconsumed));
	return (status);
}

/* The TRB the next post activates, whose cycle bit must be written before its doorbell. */
static void
watch_doorbell(uint16_t region, uint32_t index)
{
	doorbell_watch = memory_at(trb_at(region, index) + 12u, 4);
	doorbell_saw_cycle = false;
}

/* A post's verdict and its stores: none on a refusal; one doorbell, `doorbell` with `target`, after its activation. */
static void
check_rung(erx_device_trb_verdict_t verdict, uint32_t doorbell, uint32_t target)
{
	if (verdict != ERX_DEVICE_TRB_ACCEPTED) {
		CHECK(writes == 0);
		return;
	}
	CHECK(writes == 1 && write_offsets[0] == DOORBELLS + 4u * doorbell && write_values[0] == target);
	CHECK(doorbell_saw_cycle);
}

static erx_device_trb_verdict_t
command(const erx_device_t *device, erx_trb_command_t command, uint64_t tag, uint32_t position)
{
	erx_device_trb_verdict_t verdict = ERX_DEVICE_TRB_REFUSE_BADARG;

	writes = 0;
	watch_doorbell(layout.command_ring, position);
	CHECK(erx_device_trb_command(device, &command, tag, &verdict) == ERX_OK);
	check_rung(verdict, 0, 0);
	return (verdict);
}

/* A control transfer on EP0 of slot 1, block 0, its setup stage at ring position `position`. */
static erx_device_trb_verdict_t
control(const erx_device_t *device, const erx_device_trb_request_t *request, uint64_t tag, uint32_t position)
{
	erx_device_trb_verdict_t verdict = ERX_DEVICE_TRB_REFUSE_BADARG;

	writes = 0;
	watch_doorbell(layout.block_ring[0], position);
	CHECK(erx_device_trb_post(device, 1, 1, tag, request, &verdict) == ERX_OK);
	check_rung(verdict, 1, 1);
	return (verdict);
}

/* GET_DESCRIPTOR reading 8 bytes into the block's one buffer: a setup, a data and a status stage. */
static erx_device_trb_verdict_t
read_descriptor(const erx_device_t *device, uint64_t tag, uint32_t position)
{
	const erx_device_trb_request_t request = { .control = true, .data = true, .device_writes = true, .length = 8,
	    .setup = { 0x80, 6, 0, 1, 0, 0, 8, 0 } };

	return (control(device, &request, tag, position));
}

/* SET_CONFIGURATION 1, which names no buffer: a setup and a status stage. */
static erx_device_trb_verdict_t
set_configuration(const erx_device_t *device, uint64_t tag, uint32_t position)
{
	const erx_device_trb_request_t request = { .control = true, .setup = { 0x00, 9, 1, 0, 0, 0, 0, 0 } };

	return (control(device, &request, tag, position));
}

static erx_trb_queue_state_t
queue_state(const erx_device_t *device, uint32_t slot, uint32_t dci)
{
	erx_trb_queue_state_t state = ERX_TRB_QUEUE_NONE;

	CHECK(erx_device_trb_queue_state(device, slot, dci, &state) == ERX_OK);
	return (state);
}

/* The command completion of command ring position `position`, with `code`. */
static void
put_command_event(uint32_t position, uint32_t code, uint32_t slot)
{
	put_event(ERX_XHCI_TRB_TYPE_COMMAND_COMPLETION_EVENT, trb_at(layout.command_ring, position), code, 0, slot, 0);
}

static bool
answered(uint32_t at, erx_trb_answer_kind_t kind, uint64_t tag, uint32_t code, uint64_t length)
{
	return (answers[at].kind == kind && answers[at].tag == tag && answers[at].code == code &&
	    answers[at].data.length == length);
}

/*
 * Commands and transfers through their effects: a doorbell per post, after its activation, slot
 * 1's with target 1 for EP0 and doorbell 0 with target 0 for a command; nothing stored on a
 * refusal; each completion's answers in the core's order, a transfer's bytes copied from its
 * buffer, a restarted ring's `stopped` answer before its command's, and ERDP after; each queue's
 * state from the record; and a broken form refusing every later call.
 */
static void
test_runs(void)
{
	const erx_device_t *const device = started();
	const erx_trb_command_t enable = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	const erx_trb_command_t address = { .kind = ERX_TRB_COMMAND_ADDRESS_DEVICE, .slot = 1, .add_count = 1,
	    .slot_context = { .route_speed = ERX_XHCI_SPEED_HIGH, .ports_root_port = 1 },
	    .adds = { { .dci = 1, .block = UINT32_MAX, .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL,
	    .config_max_packet = 64 } } } };
	const erx_trb_command_t stop = { .kind = ERX_TRB_COMMAND_STOP_ENDPOINT, .slot = 1, .dci = 1 };
	const erx_trb_command_t restart = { .kind = ERX_TRB_COMMAND_SET_TR_DEQUEUE, .slot = 1, .dci = 1 };
	static const uint8_t descriptor[8] = { 18, 1, 0, 2, 0, 0, 0, 64 };
	uint8_t *slot_context;

	/* Enable Slot, then Address Device binding EP0 to the first control block, block 0, whatever block it names; one command at a time. */
	CHECK(command(device, enable, 5, 0) == ERX_DEVICE_TRB_ACCEPTED && trb_cycle(layout.command_ring, 0));
	CHECK(command(device, enable, 6, 1) == ERX_DEVICE_TRB_REFUSE_FULL);
	CHECK(read_descriptor(device, 7, 0) == ERX_DEVICE_TRB_REFUSE_BADARG);	/* no ring bound */
	put_command_event(0, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_COMMAND, 5, ERX_XHCI_COMPLETION_SUCCESS, 0) &&
	    answers[0].slot == 1);
	CHECK(complete(device, 0, 0) == ERX_OK);	/* nothing new: ERDP stays */
	CHECK(command(device, address, 8, 1) == ERX_DEVICE_TRB_ACCEPTED);
	/*
	 * Its success carries the slot's output slot context, where the controller wrote the address it
	 * assigned: the context DCBAA entry 1 names (4.3.3, 6.1), which must name slot 1's by then.
	 */
	slot_context = memory_at(word64(memory_at(layout.device_base + layout.regions[layout.dcbaa].offset + 8u, 8)),
	    ERX_XHCI_SLOT_CONTEXT_SIZE);
	CHECK(slot_context == memory_at(layout.device_base + layout.regions[layout.device_context[1]].offset,
	    ERX_XHCI_SLOT_CONTEXT_SIZE));
	memset(slot_context, 0, ERX_XHCI_SLOT_CONTEXT_SIZE);
	slot_context[ERX_XHCI_SLOT_CONTEXT_OFF_STATE] = 5;
	put_command_event(1, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK &&
	    answered(0, ERX_TRB_ANSWER_COMMAND, 8, ERX_XHCI_COMPLETION_SUCCESS, ERX_XHCI_SLOT_CONTEXT_SIZE) &&
	    memcmp(answer_bytes[0], slot_context, ERX_XHCI_SLOT_CONTEXT_SIZE) == 0);
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_IDLE && queue_state(device, 1, 2) == ERX_TRB_QUEUE_NONE &&
	    queue_state(device, 0, 1) == ERX_TRB_QUEUE_NONE);

	/* A control read: setup, data and status stages at 0..2, its status stage's event completing it with the buffer's bytes. */
	CHECK(read_descriptor(device, 9, 0) == ERX_DEVICE_TRB_ACCEPTED && queue_state(device, 1, 1) == ERX_TRB_QUEUE_BUSY);
	memcpy(memory_at(layout.device_base + layout.regions[layout.buffer[0][0]].offset, 8), descriptor, 8);
	put_event(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, trb_at(layout.block_ring[0], 2), ERX_XHCI_COMPLETION_SUCCESS, 0, 1, 1);
	put_port_event(2);
	CHECK(complete(device, 2, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_TRANSFER, 9, ERX_XHCI_COMPLETION_SUCCESS, 8) &&
	    memcmp(answer_bytes[0], descriptor, 8) == 0 && answers[1].kind == ERX_TRB_ANSWER_PORT && answers[1].port == 2);
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_IDLE);

	/* Stop Endpoint over a posted transfer, then Set TR Dequeue: the transfer answers stopped before the command. */
	CHECK(read_descriptor(device, 10, 3) == ERX_DEVICE_TRB_ACCEPTED);
	CHECK(command(device, stop, 11, 2) == ERX_DEVICE_TRB_ACCEPTED);
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_BUSY);	/* running until the stop completes */
	CHECK(read_descriptor(device, 12, 6) == ERX_DEVICE_TRB_REFUSE_FULL);	/* its one buffer is taken, judged first */
	put_command_event(2, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_COMMAND, 11, ERX_XHCI_COMPLETION_SUCCESS, 0));
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_STOPPED);
	CHECK(command(device, restart, 13, 3) == ERX_DEVICE_TRB_ACCEPTED);
	put_command_event(3, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 2, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_TRANSFER, 10, ERX_XHCI_COMPLETION_STOPPED, 0) &&
	    answered(1, ERX_TRB_ANSWER_COMMAND, 13, ERX_XHCI_COMPLETION_SUCCESS, 0));
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_IDLE);

	/* A stop with nothing posted: the queue refuses posts as halted while the stop runs and once it has stopped. */
	CHECK(command(device, stop, 14, 4) == ERX_DEVICE_TRB_ACCEPTED && queue_state(device, 1, 1) == ERX_TRB_QUEUE_IDLE);
	CHECK(set_configuration(device, 15, 6) == ERX_DEVICE_TRB_REFUSE_HALTED);
	put_command_event(4, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK && queue_state(device, 1, 1) == ERX_TRB_QUEUE_STOPPED &&
	    set_configuration(device, 15, 6) == ERX_DEVICE_TRB_REFUSE_HALTED);
	CHECK(command(device, restart, 16, 5) == ERX_DEVICE_TRB_ACCEPTED);
	put_command_event(5, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_COMMAND, 16, ERX_XHCI_COMPLETION_SUCCESS, 0));

	/* A stall halts the queue; its transfer keeps the buffer until a restart, so the next read is full. */
	CHECK(read_descriptor(device, 17, 6) == ERX_DEVICE_TRB_ACCEPTED);
	put_event(ERX_XHCI_TRB_TYPE_TRANSFER_EVENT, trb_at(layout.block_ring[0], 8), ERX_XHCI_COMPLETION_STALL, 0, 1, 1);
	CHECK(complete(device, 1, 0) == ERX_OK && answered(0, ERX_TRB_ANSWER_TRANSFER, 17, ERX_XHCI_COMPLETION_STALL, 0));
	CHECK(queue_state(device, 1, 1) == ERX_TRB_QUEUE_HALTED && read_descriptor(device, 18, 9) == ERX_DEVICE_TRB_REFUSE_FULL &&
	    set_configuration(device, 18, 9) == ERX_DEVICE_TRB_REFUSE_FULL);

	/*
	 * A command completion naming no command breaks the form: the port event before it is answered,
	 * ERDP moves to it, and every later call refuses.
	 */
	put_port_event(3);
	put_command_event(6, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 1) == ERX_OK && answers[0].kind == ERX_TRB_ANSWER_PORT && answers[0].port == 3);
	writes = 0;
	{
		erx_device_trb_verdict_t verdict;
		erx_trb_queue_state_t state;
		uint32_t count;

		CHECK(erx_device_trb_command(device, &enable, 19, &verdict) == ERX_ECORRUPT);
		CHECK(erx_device_trb_queue_state(device, 1, 1, &state) == ERX_ECORRUPT);
		CHECK(erx_device_trb_complete(device, sink, &answer_count, &count) == ERX_ECORRUPT && count == 0);
		CHECK(writes == 0);
	}
}

/* DCBAA entry `slot` as the controller reads it. */
static uint64_t
slot_entry(uint32_t slot)
{
	return (word64(memory_at(layout.device_base + layout.regions[layout.dcbaa].offset + 8u * (uint64_t)slot, 8)));
}

/*
 * A slot reused by another device: DCBAA entry 1 is 0 until the slot's first Address Device, which
 * names its device context, zeroed (xHCI 1.2, 4.3.3 step 6, p. 89; 6.2.1, p. 443), and stays while
 * Disable Slot runs; its success clears the entry (6.1, p. 441; 4.6.4, p. 110), and the next
 * device's Address Device finds none of what the controller wrote for the first. Two rounds, at
 * command ring positions 0 to 5.
 */
static void
reuse_slot(const erx_device_t *device)
{
	const erx_trb_command_t enable = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	const erx_trb_command_t address = { .kind = ERX_TRB_COMMAND_ADDRESS_DEVICE, .slot = 1, .add_count = 1,
	    .slot_context = { .route_speed = ERX_XHCI_SPEED_HIGH, .ports_root_port = 1 },
	    .adds = { { .dci = 1, .block = 0, .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL,
	    .config_max_packet = 64 } } } };
	const erx_trb_command_t disable = { .kind = ERX_TRB_COMMAND_DISABLE_SLOT, .slot = 1 };
	const uint64_t context = layout.device_base + layout.regions[layout.device_context[1]].offset;
	const uint64_t length = layout.regions[layout.device_context[1]].length;
	static const uint8_t zeros[ERX_XHCI_DEVICE_CONTEXTS * 64];

	CHECK(length <= sizeof(zeros));
	for (uint32_t round = 0; round < 2; round++) {
		const uint32_t at = 3u * round;

		CHECK(command(device, enable, 1, at) == ERX_DEVICE_TRB_ACCEPTED);
		put_command_event(at, ERX_XHCI_COMPLETION_SUCCESS, 1);
		CHECK(complete(device, 1, 0) == ERX_OK && slot_entry(1) == 0);
		/* What the controller wrote for the slot's former device, or what a former driver left. */
		memset(memory_at(context, length), 0xa5, length);
		CHECK(command(device, address, 2, at + 1u) == ERX_DEVICE_TRB_ACCEPTED);
		CHECK(slot_entry(1) == context && memcmp(memory_at(context, length), zeros, length) == 0);
		put_command_event(at + 1u, ERX_XHCI_COMPLETION_SUCCESS, 1);
		CHECK(complete(device, 1, 0) == ERX_OK && slot_entry(1) == context);
		memset(memory_at(context, length), 0x5a, length);
		CHECK(command(device, disable, 3, at + 2u) == ERX_DEVICE_TRB_ACCEPTED && slot_entry(1) == context);
		put_command_event(at + 2u, ERX_XHCI_COMPLETION_SUCCESS, 1);
		CHECK(complete(device, 1, 0) == ERX_OK && slot_entry(1) == 0);
	}
}

/*
 * An out transfer's bytes in its buffer before its doorbell rings, a slot past the doorbells
 * refused with nothing written, and ERDP written after a lone event that breaks the form, on a slot
 * reused first.
 */
static void
test_out_transfer(void)
{
	const erx_device_t *const device = started();
	const erx_trb_command_t enable = { .kind = ERX_TRB_COMMAND_ENABLE_SLOT };
	const erx_trb_command_t address = { .kind = ERX_TRB_COMMAND_ADDRESS_DEVICE, .slot = 1, .add_count = 1,
	    .slot_context = { .route_speed = ERX_XHCI_SPEED_HIGH, .ports_root_port = 1 },
	    .adds = { { .dci = 1, .block = 0, .context = { .config_endpoint_type = ERX_XHCI_ENDPOINT_TYPE_CONTROL,
	    .config_max_packet = 64 } } } };
	static const uint8_t descriptor[8] = { 9, 2, 32, 0, 1, 1, 0, 0x80 };
	const erx_device_trb_request_t write = { .control = true, .data = true, .length = 8, .bytes = descriptor,
	    .setup = { 0x00, 7, 0, 2, 0, 0, 8, 0 } };
	erx_device_trb_verdict_t verdict = ERX_DEVICE_TRB_ACCEPTED;

	reuse_slot(device);
	CHECK(command(device, enable, 1, 6) == ERX_DEVICE_TRB_ACCEPTED);
	put_command_event(6, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK);
	CHECK(command(device, address, 2, 7) == ERX_DEVICE_TRB_ACCEPTED);
	put_command_event(7, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 1, 0) == ERX_OK);
	writes = 0;
	CHECK(erx_device_trb_post(device, 1u << 16, 1, 3, &write, &verdict) == ERX_OK &&
	    verdict == ERX_DEVICE_TRB_REFUSE_BADARG && writes == 0);
	CHECK(control(device, &write, 3, 0) == ERX_DEVICE_TRB_ACCEPTED);
	CHECK(memcmp(memory_at(layout.device_base + layout.regions[layout.buffer[0][0]].offset, 8), descriptor, 8) == 0);
	/* A lone event that breaks the form answers nothing, and ERDP still moves to it. */
	put_command_event(8, ERX_XHCI_COMPLETION_SUCCESS, 1);
	CHECK(complete(device, 0, 1) == ERX_ECORRUPT);
}

/*
 * The cases, or with `msix` the MSI-X cases, a run of their own, since each open takes one of the
 * NIF's few records for the run.
 */
int
main(int argc, char **argv)
{
	xhci = erx_device_peripheral_find("xhci", 4);
	CHECK(xhci != NULL);
	if (argc > 1 && strcmp(argv[1], "msix") == 0) {
		test_msix_refusals();
		test_msix();
		printf("erx_device_xhci msix done\n");
		return (0);
	}
	test_refusals();
	test_start();
	test_runs();
	test_out_transfer();
	test_restart();
	printf("erx_device_xhci done\n");
	return (0);
}
