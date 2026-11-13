/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The DMA architecture layer of host builds: hosted ERTS and the host tests of erx_device.c.
 * Their devices are code in the same process, which reads and writes memory through the same
 * caches as the CPU, so there is nothing to clean: the maintenance is empty and each barrier
 * is a full C11 fence. The granule and the line are a common CPU's 64 bytes, so the layout and
 * the check run on a granule larger than one byte. The model of a CPU whose caches the device
 * does not see is erx_dma_model.c, which the sequencer's own host tests drive.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx_dma_arch.h"

#define HOST_GRANULE	64u
#define HOST_LINE	64u

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
}

void
erx_dma_clean_inval(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	(void)start;
	(void)length;
	(void)step;
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
