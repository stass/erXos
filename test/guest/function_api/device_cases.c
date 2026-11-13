/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What takes a device, and so holds natively alone; hosted has none, and hosted.c holds
 * it to refusing. The device is QEMU virt's fw_cfg, which every run of the machine has,
 * and which needs no driver to prove the two things a driver depends on: its registers
 * answer through a physical object, and it writes memory at the address
 * erx_mem_dma_addr gives, which only holds if that address is really the device's.
 *
 * The list ends with handle_cases.c's cases, which take no device but have calls only
 * native offers, so hosted holds them with its own handle rows.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/vm.h"
#include "test/guest/function_api/cases.h"

extern const function_api_case_t function_api_device_cases[];
extern const size_t function_api_device_case_count;
bool	function_api_case_generations(void);
bool	function_api_case_stale_handle(void);
bool	function_api_case_dup_and_close(void);

/* QEMU's docs/specs/fw_cfg.rst and hw/arm/virt.c. Each register and field is big-endian. */
#define FW_CFG_PHYS		UINT64_C(0x9020000)
#define FW_CFG_DMA_REGISTER	UINT64_C(0x10)
#define FW_CFG_DMA_SIGNATURE	UINT64_C(0x51454d5520434647)	/* "QEMU CFG", read from the DMA register */
#define FW_CFG_CONTROL_READ	UINT32_C(0x02)
#define FW_CFG_CONTROL_SELECT	UINT32_C(0x08)
#define FW_CFG_KEY_SIGNATURE	UINT32_C(0)
#define FW_CFG_KEY_SHIFT	16u
#define FW_CFG_SIGNATURE_BYTES	4u
#define FW_CFG_SIGNATURE_WORD	UINT32_C(0x554d4551)		/* "QEMU", read as a little-endian word */

/* A RAM address on QEMU virt, which sigma0 keeps from a request for registers. */
#define RAM_PHYS		UINT64_C(0x40000000)

typedef struct fw_cfg_dma_access {
	uint32_t	control;
	uint32_t	length;
	uint64_t	address;
} fw_cfg_dma_access_t;

/* Where the first case mapped fw_cfg's registers, for the last. */
static uint64_t fw_cfg_registers;

static bool
map_object(uint64_t mem, uint64_t size, uint32_t prot, uint64_t *addr)
{
	return (erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, addr) == ERX_OK && erx_vm_map(ERX_CAP_SELF, *addr, size, mem, 0, prot) == ERX_OK);
}

static bool
case_physical_reads_registers(void)
{
	uint64_t mem;

	if (erx_mem_create_physical(0, 0, FW_CFG_PHYS, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &mem) != ERX_OK ||
	    !map_object(mem, ERX_PAGE_SIZE, ERX_PROT_RW, &fw_cfg_registers))
		return (false);
	return (__builtin_bswap64(*(volatile uint64_t *)(uintptr_t)(fw_cfg_registers + FW_CFG_DMA_REGISTER)) ==
	    FW_CFG_DMA_SIGNATURE);
}

/* RAM is no device's, registers never run, and they have no address a device would use. */
static bool
case_physical_refusals(void)
{
	uint64_t mem, addr, unused;

	if (erx_mem_create_physical(0, 0, RAM_PHYS, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &mem) != ERX_ERANGE ||
	    erx_mem_create_physical(0, 0, FW_CFG_PHYS, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &mem) != ERX_OK ||
	    erx_vm_reserve(ERX_CAP_SELF, 0, ERX_PAGE_SIZE, 0, &addr) != ERX_OK)
		return (false);
	return (erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, mem, 0, ERX_PROT_RX) == ERX_ERIGHTS &&
	    erx_vm_map(ERX_CAP_SELF, addr, ERX_PAGE_SIZE, mem, 0, ERX_PROT_RW) == ERX_OK &&
	    erx_mem_dma_addr(mem, 0, &unused) == ERX_ETYPE);
}

/*
 * A device that sees CPU address cpu + x at bus + x: its run, the first free page,
 * next, has device address next + bus, and dma_addr adds the offset to it. A range
 * whose last is below its cpu or whose bus end passes 2^64 - 1 is malformed, and one
 * that ends below the pool, or starts past its first page at pool, holds no run.
 */
static bool
contiguous_in_range(uint64_t pool, uint64_t next)
{
	const uint64_t bus = UINT64_C(1) << 40;
	const erx_mem_dma_range_t offset = { .cpu = 0, .bus = bus, .last = UINT64_MAX - bus };
	const erx_mem_dma_range_t backwards = { .cpu = UINT64_C(1) << 30, .bus = 0, .last = 0 };
	const erx_mem_dma_range_t past_top = { .cpu = 0, .bus = UINT64_MAX - ERX_PAGE_SIZE + 1, .last = ERX_PAGE_SIZE };
	const erx_mem_dma_range_t below = { .cpu = 0, .bus = 0, .last = pool - 1 };
	const erx_mem_dma_range_t above = { .cpu = pool + ERX_PAGE_SIZE, .bus = 0, .last = UINT64_MAX };
	uint64_t mem, addr, unused;

	if (erx_mem_create_contiguous_in(0, ERX_PAGE_SIZE, &offset, &mem) != ERX_OK ||
	    erx_mem_dma_addr(mem, 0, &addr) != ERX_OK || addr != next + bus ||
	    erx_mem_dma_addr(mem, 8, &addr) != ERX_OK || addr != next + bus + 8)
		return (false);
	return (erx_mem_create_contiguous_in(0, ERX_PAGE_SIZE, &backwards, &unused) == ERX_EINVAL &&
	    erx_mem_create_contiguous_in(0, ERX_PAGE_SIZE, &past_top, &unused) == ERX_EINVAL &&
	    erx_mem_create_contiguous_in(0, ERX_PAGE_SIZE, &below, &unused) == ERX_ERANGE &&
	    erx_mem_create_contiguous_in(0, ERX_PAGE_SIZE, &above, &unused) == ERX_ERANGE);
}

/*
 * Each run is aligned to a page and holds its pages alone, within the pool's. 9 MiB is
 * more than a 1920x1080 screen's image at 4 bytes a pixel, and is one object.
 */
static bool
case_contiguous_runs(void)
{
	const uint64_t pages_3 = 3 * (uint64_t)ERX_PAGE_SIZE;
	const uint64_t screen = 9 * (UINT64_C(1) << 20);
	uint64_t one, three, large, again, addr_one, addr_three, addr_large, unused;

	if (erx_mem_create_contiguous(0, 0, ERX_PAGE_SIZE, 0, &one) != ERX_OK ||
	    erx_mem_create_contiguous(0, 0, pages_3, 0, &three) != ERX_OK ||
	    erx_mem_create_contiguous(0, 0, screen, 0, &large) != ERX_OK)
		return (false);
	if (erx_mem_dma_addr(one, 0, &addr_one) != ERX_OK || erx_mem_dma_addr(three, 0, &addr_three) != ERX_OK ||
	    erx_mem_dma_addr(large, 0, &addr_large) != ERX_OK ||
	    erx_mem_dma_addr(large, screen - ERX_PAGE_SIZE, &unused) != ERX_OK || unused != addr_large + screen - ERX_PAGE_SIZE)
		return (false);
	if (addr_one % ERX_PAGE_SIZE != 0 || addr_three % ERX_PAGE_SIZE != 0 || addr_large % ERX_PAGE_SIZE != 0)
		return (false);
	if (addr_three < addr_one + ERX_PAGE_SIZE || addr_large < addr_three + pages_3)
		return (false);
	/* The pool is ERX_MEM_CONTIGUOUS_MAX and holds these runs, so nothing so large has room. */
	if (erx_mem_create_contiguous(0, 0, ERX_MEM_CONTIGUOUS_MAX, 0, &again) != ERX_ENOMEM)
		return (false);
	if (erx_mem_dma_addr(one, ERX_PAGE_SIZE, &unused) != ERX_ERANGE ||
	    erx_mem_dma_addr(three, 2 * (uint64_t)ERX_PAGE_SIZE, &unused) != ERX_OK || unused != addr_three + 2 * ERX_PAGE_SIZE)
		return (false);
	/* A limit at the pool's lowest address leaves no room, and one a page past the large run does. */
	if (!(erx_mem_create_contiguous(0, 0, ERX_PAGE_SIZE, addr_one, &again) == ERX_ERANGE &&
	    erx_mem_create_contiguous(0, 0, ERX_PAGE_SIZE, addr_large + screen + ERX_PAGE_SIZE, &again) == ERX_OK))
		return (false);
	return (contiguous_in_range(addr_one, addr_large + screen + ERX_PAGE_SIZE));
}

/* fw_cfg reads its own request from a run and writes its signature into the run's second page. */
static bool
case_contiguous_device_writes(void)
{
	uint64_t mem, addr, request_device, buffer_device;
	volatile fw_cfg_dma_access_t *request;
	volatile uint32_t *buffer;

	if (erx_mem_create_contiguous(0, 0, 2 * (uint64_t)ERX_PAGE_SIZE, 0, &mem) != ERX_OK ||
	    !map_object(mem, 2 * (uint64_t)ERX_PAGE_SIZE, ERX_PROT_RW, &addr) ||
	    erx_mem_dma_addr(mem, 0, &request_device) != ERX_OK ||
	    erx_mem_dma_addr(mem, ERX_PAGE_SIZE, &buffer_device) != ERX_OK)
		return (false);
	request = (volatile fw_cfg_dma_access_t *)(uintptr_t)addr;
	buffer = (volatile uint32_t *)(uintptr_t)(addr + ERX_PAGE_SIZE);
	if (*buffer != 0 || fw_cfg_registers == 0)
		return (false);
	request->control = __builtin_bswap32(FW_CFG_KEY_SIGNATURE << FW_CFG_KEY_SHIFT | FW_CFG_CONTROL_SELECT | FW_CFG_CONTROL_READ);
	request->length = __builtin_bswap32(FW_CFG_SIGNATURE_BYTES);
	request->address = __builtin_bswap64(buffer_device);
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
	*(volatile uint64_t *)(uintptr_t)(fw_cfg_registers + FW_CFG_DMA_REGISTER) = __builtin_bswap64(request_device);
	__atomic_thread_fence(__ATOMIC_SEQ_CST);
	return (request->control == 0 && *buffer == FW_CFG_SIGNATURE_WORD);
}

const function_api_case_t function_api_device_cases[] = {
	{ "physical_reads_registers", case_physical_reads_registers },
	{ "physical_refusals", case_physical_refusals },
	{ "contiguous_runs", case_contiguous_runs },
	{ "contiguous_device_writes", case_contiguous_device_writes },
	/* generations first: handle_cases.c says why. */
	{ "generations", function_api_case_generations },
	{ "stale_handle", function_api_case_stale_handle },
	{ "dup_and_close", function_api_case_dup_and_close },
};
const size_t function_api_device_case_count = sizeof(function_api_device_cases) / sizeof(function_api_device_cases[0]);
