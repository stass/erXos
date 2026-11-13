/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The host DMA architecture layer of arch/host/erx_dma_arch.c with its maintenance counted,
 * for test/fixtures/erx_device_dma_harness.c: the harness's device shares the CPU's caches,
 * so cleaning still does nothing, but each clean and each clean-and-invalidate adds one to
 * erx_dma_maintenance_count, so the harness can tell a queue whose plans run as for a
 * coherent device from one whose plans run as for a device that is not.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx_dma_arch.h"
#include "erx_dma_arch_counting.h"

#define HOST_GRANULE	64u
#define HOST_LINE	64u

uint64_t erx_dma_maintenance_count;

uint32_t
erx_dma_granule(void)
{
	return (HOST_GRANULE);
}

uint32_t
erx_dma_line(void)
{
	return (HOST_LINE);
}

void
erx_dma_clean(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	(void)start;
	(void)length;
	(void)step;
	erx_dma_maintenance_count++;
}

void
erx_dma_clean_inval(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	(void)start;
	(void)length;
	(void)step;
	erx_dma_maintenance_count++;
}

void
erx_dma_publish_barrier(bool completes)
{
	(void)completes;
	atomic_thread_fence(memory_order_seq_cst);
}

void
erx_dma_report_barrier(void)
{
	atomic_thread_fence(memory_order_seq_cst);
}

void
erx_dma_completion_barrier(void)
{
	atomic_thread_fence(memory_order_seq_cst);
}
